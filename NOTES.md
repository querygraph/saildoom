# Notes: SQLDoom on Sail

Measured on an Apple M1 Max (10 cores, 64 GB), macOS 26.2, Sail `main` at
`d29516a7405b7d997cf8c673c2e12ddeebf0d415` built with its release profile
(fat LTO), PySpark 4.2.0 client. CedarDB `v2026-09-29` in Docker on the same
Mac as the reference. Freedoom 0.13.0 `freedoom1.wad`, E1M1, skill 2.

## Renderer timings

| Version | One frame | Notes |
|---|---|---|
| CedarDB, SQLDoom's own query | 32 ms | in Docker's Linux VM |
| `renderer_v1.sql`, stage-by-stage port | 9,800 ms | pixel-exact |
| `renderer.sql`, one stream | 1,570 ms | pixel-exact |
| the same, one-row side first in cross joins | 708 ms | pixel-exact |
| `renderer_batch.sql`, 35 frames a query | 58 ms a frame | 10 cores |
| `renderer_batch.sql`, 105 frames a query | 41 ms a frame | 10 cores, one client: 24.3 frames/s |
| the same, 2 clients concurrently | 29.5 ms a frame | 33.9 frames/s |
| the same, 4 clients concurrently | 25.8 ms a frame | 38.8 frames/s |

## What costs time on Sail

1. **CTE inlining.** Sail resolves a CTE into a plan subtree and copies it at
   every reference (`sail-plan/src/resolver/query/cte.rs`), and resolves
   every CTE in the `WITH` whether or not it is used. SQLDoom's renderer reads
   `heights` from seven `UNION ALL` branches and joins `panel_seq` to itself
   twice; inlined, its EXPLAIN text was 8.4 MB. Fixed in the SQL: every heavy
   stage is read once.
2. **A cross join emits one batch per row of its left input.** `big CROSS
   JOIN one_row` built the 165,000-row side and produced 164,700 one-row
   batches; every operator downstream then paid per batch. Putting the one-row
   input first took the frame from 1.6 s to 0.7 s.
3. **Planning, not execution.** A sampled profile of a symbolized build
   rendering frames in a loop: SQL parsing (Sail's chumsky parser) about a
   third of the request, physical planning about another third (DataFusion's
   physical optimizer rebuilding equivalence properties on every node it
   replaces), logical optimization and resolution most of the rest.
   Execution is a small part. Measured separately: about 58 µs per simple
   expression to parse and resolve (2,000 `x + i` columns: 117 ms), and raw
   text is cheap (30 KB of whitespace: 1.6 ms).
4. **Superlinear optimization of deep filter chains.** A chain of CTEs that
   each filter on an expression built by the previous one: 10 levels 26 ms,
   25 levels 88 ms, 50 levels 1.2 s, 100 levels 26 s. Plain projection or
   filter chains stay linear (about 0.4 ms a level).

Batching answers 3 for throughput: the plan is the same size for 1 or 105
frames. Concurrent clients overlap one batch's planning with another's
execution, which brings the 10 cores to 38.8 frames a second.

## Exactness

- Postgres' float-to-integer cast rounds half to even (`bround`), Spark's
  truncates; Postgres divides integers as integers (`DIV`).
- `generate_series(a, b)` is empty when `a > b`; Spark's `sequence(a, b)`
  counts down. The `GS` macro guards it.
- Postgres three-valued logic in `NOT (explodes AND state = 'dead')` drops a
  barrel with no AI row; a `COALESCE` there would keep it.
- Pose literals: SQLDoom's client sends the pose as a decimal literal, and
  CedarDB converts `215.18106079101562` to `0x406ae5cb3fffffff`, one ulp
  below the correctly rounded double. Sail's `CAST(215.18106079101562 AS
  DOUBLE)` gives the same bits. The batch renderer therefore takes its poses
  through the same literal cast instead of reading exact doubles.
- The remaining differences (5 of 526 frames, 1 to 8 pixels each) are libm:
  at tic 42 `cos(-radians(336.0))` is `...7f95` on macOS and `...7f96` in
  CedarDB; at tic 53 `tan` differs in the last bit. A flipped last bit moves
  a `FLOOR` across an integer. Running Sail on Linux (glibc) should close
  these; not yet checked.

## Sail issues found

- Filed: [lakehq/sail#2742](https://github.com/lakehq/sail/issues/2742), a
  `CASE` over arrays of structs panics when only a later branch has a NULL
  item (the renderer puts the nullable branch first to avoid it).
- Not filed yet:
  - A deeply nested or very long arithmetic expression overflows a tokio
    worker's stack and aborts the whole server process ("thread
    'tokio-rt-worker' has overflowed its stack").
  - `df.persist()`/`cache()` is a no-op ("Persist operation is not yet
    supported"), and `CACHE TABLE` is not implemented.
  - PySpark 4.2's `createDataFrame` reads eleven `spark.sql.session.localRelation*`
    and related settings that Sail does not define; the client fails until
    they are set (`saildoom/engine.py` sets Spark's defaults).
  - `localCheckpoint()` needs `execution.checkpoint.path`; with `memory:///`
    it works, but checkpoints live until the session ends (the server's
    `RemoveCachedRemoteRelationCommand` handler is a no-op), so they cannot
    hold per-frame intermediates.

## Not done yet

- SQLDoom's game logic on Sail. The tic is procedural (CedarScript) and
  updates about 40 tables in place; Sail has neither stored procedures nor
  `UPDATE` on in-memory tables, and `WITH RECURSIVE` is a `todo` on main
  (`sail-plan/src/resolver/query/recursion.rs`), so many tics cannot run in
  one recursive plan. On main a tic would be a sequence of queries, each
  computing a table's next version from the current ones, with SQLDoom's
  control flow (its CedarScript `if`s and stage bits) in a small driver.
- Interactive play. At 0.7 s a frame for one frame per query, Sail main is
  not interactive; throughput comes from batches, which suits rendering a
  recorded or simulated run.
