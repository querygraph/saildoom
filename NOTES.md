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

- Filed: [apache/datafusion#26058](https://github.com/apache/datafusion/issues/26058),
  wrong results on Sail main too: an inner join whose `ON` pairs an equi-key
  with an equality spanning two cross-joined relations loses the second
  (`extract_equijoin_predicate` with `eliminate_cross_join`). The game's
  respawn fog hit it; `tic_monsters.sql` writes one branch per fog instead.

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

## The game on Sail

The tic runs on the recursive-CTE fork as one `WITH RECURSIVE` query whose
rows are the world: a relation of 20 kinds (player, sectors, movers, line
events and activations, switches, sidedefs, render segs, Things, their health,
monster AI, render Things, effects, weapons, owned weapons, picked-up items,
secrets, automap lines, projectiles, monster deaths), one struct column per
kind (`saildoom/world.py`). SQLDoom's stages are CTE chains over it, in tic
order: `tic_doors.sql`, `tic_step.sql`, `tic_combat.sql`,
`tic_projectiles.sql`, `tic_monsters.sql`, `tic_out.sql`. SQLDoom's
CedarScript `if`s and plan bits become per-tic gates (a CTE of the tics on
which a stage runs), `INSERT ... ON CONFLICT` and `UPDATE` become joins that
produce the next version of a kind.

- 1,200 tics: 202 s as one recursive query (168 ms a tic, single client), or
  18 s with every tic computed from CedarDB's recorded state in one query (the
  check `reference/check_tic.py --mode step` runs). Doom runs at 35 tics a
  second; the recursive form is about 6 tics a second.
- CedarDB arithmetic that the port has to reproduce, found by probing it:
  `real` with an integer or a decimal literal stays `real`; `POWER` and
  `SQRT` of a `real` are `real` (single precision throughout); casts to an
  integer truncate; `ROUND` of a double rounds half away from zero. Postgres
  differs on the first two. `saildoom/sqlmacro.py` has `FHYPOT` for the
  single-precision distance.
- The bot's float commands reach CedarDB as decimal text, which rounds to
  `real` directly; rounding them through a double first is one ulp off now
  and then. The port reads the commands back from `game_tic_commands`.
- SQLDoom's camera interpolates `real - real` in single precision
  (`sql/client/camera_pose.sql`); `scripts/simulate_run.py` does the same, and
  then every pose matches.

## SQLDoom's API on Sail

`saildoom/backend.py` answers the statements SQLDoom's client prepares
(`doom_sql.py`), and the raw SQL it sends, from Parquet tables on Sail:
`install(doom_sql, backend)` swaps them in. A game tic runs the same tic SQL
as the recursive query, for one tic, plus `tic_staging.sql` for the staging
tables SQLDoom keeps. The rest is `saildoom/api/`: menus, level flow, save and
load, intermission, finale, demos, cheats, the automap and its renderer.

`reference/trace_api.py` records a scenario on CedarDB: every call, the rows it
returned, and every table it changed. `reference/check_api.py` replays it on
Sail and compares call by call.

- `menus`: 509 calls, all match.
- `campaign`: 4,314 calls, all match. E1M1 with cheats, weapon slots and the
  automap; the exit and intermission; E1M2 carried over, saved and loaded; the
  secret exit; E1M8 and the finale; a demo recorded and played back by the
  attract loop. Seven calls return doubles a few ulps apart (libm). The
  trace's one automap frame predates frame recording.
- `automap`: 526 calls, all match; its ten frames (grid, pan, zoom, fit, both
  IDDT levels) are byte-identical to CedarDB's.
- `sound_events.event_id` is compared as a set per tic: both engines use the
  same sequence values in a tic, but CedarDB's order among one tic's inserts
  follows its plan.

## Not done yet

- Deathmatch and the multiplayer API (`39_mp.sql`, `42_api.sql`), item
  respawn, and a trace for them; the menu screen renderer
  (`client/render_screen.sql`) and level stats.
- Loading a WAD without CedarDB: the map and game tables come from CedarDB's
  export today.
- One renderer frame of the 1,200-tic run (tic 730) draws the floor under the
  player with the wrong flat (17,443 pixels); it does so from CedarDB's own
  recorded state too, so it is the renderer, not the game. The other 49
  differing frames are libm last bits as before.
- Interactive play. At 168 ms a tic in the recursive form and 0.7 s for a
  single frame, Sail is not interactive; throughput comes from batches,
  which suits rendering a recorded or simulated run. SQLDoom's own client has
  not yet been run against the API backend.

## Sail fork additions (querygraph/sail `work/recursive-cte`)

Commits on Sail main `d29516a7`: recursive CTEs (`WITH RECURSIVE`), a
recursive term that refers to its CTE more than once, and computing a CTE that
is referenced more than once only once (it was inlined at every reference).
Then three fixes the game found: CTEs that read the work table were treated as
self-references and inlined, which grew the tic's plan exponentially; a shared
CTE defined outside an inner recursive query was reset from inside it and its
consumed plan run again (a `RepartitionExec` panic); and DataFusion's
`AggregateExec` keeps its MIN/MAX dynamic filter through `reset_state`, so a
recursive term's later iterations scanned with the first one's bound (a
barrel's blast found no blast radius). The last is a DataFusion bug
([apache/datafusion#26054](https://github.com/apache/datafusion/issues/26054)); the fork
turns that pushdown off in plans with a recursive query.
Measured against main, both built with Sail's release profile (fat LTO), same
machine, default settings:

| Workload | Sail main | Fork | |
|---|---|---|---|
| SQLDoom renderer as ported stage by stage (`renderer_v1.sql`) | 10,183 ms | 4,118 ms | 2.5x faster, same pixels |
| Hand-restructured renderer (`renderer.sql`) | 698 ms | 733 ms | 5% slower |
| Batch renderer, 105 frames a query | 45.4 ms/frame | 39.3 ms/frame | 13% faster |
| Game tic, 525 tics as one recursive query (player only) | not supported | 33.0 s (63 ms/tic) | new |
| The whole game, 1,200 tics as one recursive query | not supported | 202 s (168 ms/tic) | new |
| TPC-DS SF1, the 22 queries that reuse a CTE | 2,794 ms | 2,870 ms | neutral (1.03x, noise) |
| TPC-DS SF1, 4 control queries | 118 ms | 123 ms | neutral |

TPC-DS results are identical on both for all 26 queries. TPC-DS at SF1 is too
small for reuse to pay off: an inlined copy runs in parallel and streams, a
shared result is collected first and replayed as one partition.
`scripts/bench_tpcds_cte.py` runs the comparison.
