# DDD: Doom-Driven Development

Porting SQLDoom from CedarDB to Sail is a stress test with an exact oracle:
every pixel and every row of every tic either matches CedarDB or it does not.
This file collects what the port found about Sail, DataFusion and Arrow, and
where Spark SQL, Postgres and CedarDB disagree. It is kept up to date as the
work goes on; [NOTES.md](NOTES.md) has the measurements in context.

## Filed upstream

| Where | What | Status |
|---|---|---|
| [lakehq/sail#2742](https://github.com/lakehq/sail/issues/2742) | A `CASE` over arrays of structs panics when only a later branch has a NULL item. | Issue, open. The renderer puts the nullable branch first. |
| [apache/datafusion#26054](https://github.com/apache/datafusion/issues/26054) | `AggregateExec`'s MIN/MAX dynamic filter survives `reset_state`, so a recursive term's later iterations scan with the first iteration's bound (a barrel's blast found no blast radius). | Issue, open. The fork turns that pushdown off in plans with a recursive query. |
| [apache/datafusion#26058](https://github.com/apache/datafusion/issues/26058) | Wrong rows: `eliminate_cross_join` with `extract_equijoin_predicate` drops an equi-join key whose one side spans two cross-joined relations. Reproduced on Sail main and DataFusion main 8248a57969. | Issue, open. The game writes one branch per respawn fog instead. |
| [apache/datafusion#26065](https://github.com/apache/datafusion/issues/26065) | Physical planning is slow, and grows faster than the query, with many typed NULL struct literals: `ScalarValue::eq` compares nested values through arrow's `ArrayData` conversion, and `EquivalenceGroup::add_constant` compares each new constant with every class. | Issue, open. |
| [apache/datafusion#26066](https://github.com/apache/datafusion/pull/26066) | The fix for #26065: compare lengths and data types (and pointer identity) before arrow's array equality. 35 struct columns x 20 fields: 862 ms to 147 ms. | PR, open. Vendored in the fork. |
| [apache/datafusion#26071](https://github.com/apache/datafusion/issues/26071) | Every operator's `BaselineMetrics` computes `output_bytes` for every batch with `get_record_batch_memory_size`, which converts each column and nested child to `ArrayData` and hashes every buffer: 15-22 µs a batch for 35 struct columns against 1.5 µs for summing `get_array_memory_size`; about 12% of running SailDoom's cached tic. | Issue, open. The fork vendors datafusion-physical-expr-common with the sum. |

Fork commits (querygraph/sail `work/recursive-cte`): recursive CTEs, shared
CTEs, the fixes the game found (CTE inlining of work-table readers, shared CTE
reset ownership, aggregate dynamic filters in recursive plans), the vendored
datafusion-common and datafusion-physical-expr-common, plan reuse (slot views,
plan cache, target partitions), and result slots (a query's result, or the
rows it computed for one of its shared CTEs, kept in a slot on the server).

## The fork's Sail-specific conventions

The querygraph/sail fork changes no standard Spark behaviour unless a client
opts in through these; all are experimental, and none would go upstream in
this form without a proper API design.

Session settings (`spark.conf.set`):

1. `spark.sail.slotViews`: comma-separated temporary view names. Creating or
   replacing one runs its query once and keeps the rows in memory on the
   server (a slot); a plan reading the view sees the slot's rows when it
   runs. Slot schemas are made all-nullable.
2. `spark.sail.planCache`: `true` keeps each query's physical plan, keyed by
   a hash of the relation as received (without the client's per-DataFrame
   plan id). A repeated query is not parsed or planned again: its operators'
   state is reset and it runs without the job runner's tracing. The contract:
   inputs that are not slots must not change while it is on. `false` clears
   the cache, as does a slot whose schema changes.
3. `spark.sail.targetPartitions`: the partitions cached plans are planned for.

In the SQL text:

4. `/* sail.result_slot=NAME */` as the leading comment: the query's result
   goes into slot NAME (which must exist as a slot view with the same
   columns) and the client gets no rows. `/* sail.result_slot=NAME:CTE */`:
   the client gets the rows as usual, and the rows the query computed for its
   shared CTE `CTE` go to the slot afterwards, matched by position and type.

In the server's environment:

5. `SAIL_EXECUTION_METRICS=off`: operators register no execution metrics and
   do not time their polls (read once per process); `EXPLAIN ANALYZE` then
   shows none.

In a query's named arguments:

6. Arguments named `__slot_NAME` whose value is an Arrow IPC stream (binary)
   fill slot NAME before a cached plan runs, and are left out of the plan
   cache's key: a query carries its own inputs in one request.

Changes that need no convention (they apply to every query): recursive CTEs
and CTEs computed once when referenced more than once; column-only
projections folded into CTE references and slot scans, cooperative in-memory
leaves and merged projection pairs; slots reporting row counts to the join
planner; and the vendored DataFusion changes (nested scalar equality,
#26066; the output bytes metric, #26071; memory counted from buffers).

## Sail

### Bugs and gaps, not filed yet

- A deeply nested or very long arithmetic expression overflows a tokio
  worker's stack and aborts the whole server process ("thread
  'tokio-rt-worker' has overflowed its stack").
- `df.persist()`/`cache()` is a no-op ("Persist operation is not yet
  supported"), and `CACHE TABLE` is not implemented.
- PySpark 4.2's `createDataFrame` reads eleven `spark.sql.session.localRelation*`
  and related settings that Sail does not define; the client fails until they
  are set (`saildoom/engine.py` sets Spark's defaults).
- `localCheckpoint()` needs `execution.checkpoint.path`; with `memory:///` it
  works, but checkpoints live until the session ends (the
  `RemoveCachedRemoteRelationCommand` handler is a no-op).
- Sail main has no `WITH RECURSIVE` (the fork adds it).
- Writing an empty result with `df.write.parquet` writes no files, not even
  one with the schema; reading the directory back fails
  (`saildoom/backend.py` writes an empty file itself).
- Once, with two clients replaying against one server at the same time:
  `internal error: task context not found for operation`. Not reproduced
  since; the replays now run one at a time.
- `spark.sql.shuffle.partitions` set on a session does not change how many
  partitions Sail plans for; `execution.default_parallelism` is server-wide
  (0 means one per core). The fork adds `spark.sail.targetPartitions` for
  cached plans.

### Costs

- **CTE inlining.** Sail resolves a CTE into a plan subtree and copies it at
  every reference, and resolves every CTE in the `WITH` whether or not it is
  used. SQLDoom's renderer, inlined, was 8.4 MB of EXPLAIN text. The fork
  computes a CTE referenced more than once only once.
- **Planning dominates small queries.** A frame was 0.7 s, almost all of it
  parsing (Sail's chumsky parser, about a third), physical planning (about a
  third) and logical optimization. About 58 µs per simple expression to parse
  and resolve.
- **A 710 KB query (the tic) planned in 6.5 s**: logical optimizer 46%,
  physical planning 36%, resolver 18%; a quarter of all of it comparing
  struct literals (DataFusion #26065).
- **Superlinear optimization of deep filter chains**: 10 levels 26 ms, 50
  levels 1.2 s, 100 levels 26 s.
- **Every request formats its plans as strings** (initial logical, final
  logical, final physical) whether or not anything reads them: about 15% of
  planning the tic. The fork skips them where nothing reads them.
- **`spark.sql()` is a round trip that parses the SQL** (PySpark sends it as a
  `SqlCommand` first), and every DataFrame gets a new `plan_id`. Running the
  same DataFrame again avoids both.
- **The local job runner wraps every operator in a `TracingExec`** on every
  execution; for a plan of hundreds of small operators this costs more than
  the work.
- **One partition per core** for a query over a few thousand rows: the
  repartitioning costs more than the work (the tic: 680 ms at 10 partitions,
  48 ms at 1).
- **A cross join emits one batch per row of its left input**: `big CROSS JOIN
  one_row` produced 164,700 one-row batches. Put the one-row input first.
- **A view over a file is read again by every run**, also of a cached plan:
  with `cache()` a no-op there is no way to keep a table in memory short of
  the fork's slots. The tic read 25 definition tables' Parquet files every
  tic until they became slots (34 ms to 30 ms a run).
- **Two sessions running small plans slow each other on the server**: the
  tic runs in 55 ms alone and about 60 ms while another session renders,
  whether the renderer's client is in the same Python process or not, and
  whatever the renderer's partition count.
- **A Spark Connect round trip costs about 2 to 4 ms** even for a trivial
  `createOrReplaceTempView`; independent ones can be sent concurrently.

### Behaviour worth knowing

- Temporary views are per session; two stores in one Spark session
  overwrite each other's views. Use `SparkSession.builder.remote(url).create()`
  for a separate session.
- A DataFrame from an empty Arrow table needs a schema, and
  `createDataFrame([], schema)` maps to different physical types than an Arrow
  upload of the same columns; a slot that alternates between the two is
  replaced each time (`saildoom/engine.py` uploads one row of nulls,
  filtered out).
- Arrow nullability flags reach the physical schema: a table read from a file
  and one built from a query result differ only in them.
- Inside a plan, columns carry Sail's internal ids (`#19468`), not the
  query's names: a CTE's physical rows are named that way, and only the
  final projection renames them. The fork's result slot matches a CTE's rows
  to a view's columns by position and type.
- Uploading a few thousand rows as a local relation (`createDataFrame` of an
  Arrow table) is faster than having the server read the same rows from a
  Parquet file just written: 4.5 ms against 11.8 ms for E1M1's `render_segs`.
- PySpark's `toArrow()` first asks the server for the DataFrame's schema (an
  analyze request: for a DataFrame the client has not run before, the query
  is parsed and resolved again, 1 s for the tic) and then casts the whole
  table it received to that schema. `df._to_table()[0]` returns the table as
  sent (`saildoom/engine.py` `fetch`).
- Running a PySpark Connect script with `python -c` exits early (doctest
  detection); scripts must be files or heredocs. A scratch script named after
  a stdlib module (`concurrent.py`) deadlocked the client.

## DataFusion

- **#26054, #26058, #26065** (above).
- **`reset_plan_states` recomputes every node's properties.** Each node's
  `reset_state` keeps its properties (`ChildrenPropertiesMode::Keep`), but the
  `transform_up` walk rebuilds every parent with `with_new_children`, which
  recomputes them: as costly as physical planning. The fork resets with a walk
  that keeps them. Its documentation also says it does not support plans with
  dynamic filters or recursive queries.
- **`EquivalenceGroup::add_constant` is a linear scan** over the classes for
  every new uniform constant: quadratic in the number of literals in a
  projection.
- **Re-planning a projection recomputes its equivalence properties**, and
  physical optimizer rules (`EnsureRequirements`, filter pushdown, projection
  pushdown) replace projections' children repeatedly.
- **A recursive query's work table can be read once per iteration**; the fork
  shares it between references (`SharedCteWorkTable`).
- **Every operator measures every output batch's memory** for its
  `output_bytes` metric (`BaselineMetrics::record_poll` calls
  `get_record_batch_memory_size`), which converts each column, and each child
  of a nested column, to `ArrayData` and hashes every buffer's address. For
  the tic's wide struct columns this was about 12% of running the cached plan.
  The fork vendors datafusion-physical-expr-common with the metric summed from
  `get_array_memory_size` instead
  ([apache/datafusion#26071](https://github.com/apache/datafusion/issues/26071)).
- **A constant list indexed by a column is broadcast to every row of every
  batch**: `element_at(array(<256 literals>), i)` (SQLDoom's random number
  table) expands the list with `ScalarValue::to_array_of_size` per batch, for
  the lookup and again for Sail's bounds check (`array_length`): about 5% of
  running the tic, 27 uses.
- **A plan of thousands of operators.** SailDoom's tic plans to 5,227
  physical operators: 1,884 projections, 858 `CooperativeExec`s, 830 shared
  CTE references, 630 hash joins. Sail reads a CTE through a projection at
  every reference (820 projections only pick and rename a reference's
  columns), and DataFusion's `EnsureCooperative` puts a `CooperativeExec` over
  every leaf that does not say it is cooperative (856 over in-memory leaves).
  The fork folds those projections into the leaves and makes the leaves
  cooperative: 3,551 operators, 33 ms to 28 ms a run.
- **Metrics are created on every execution**: every operator builds its
  metrics (`MetricBuilder::build` allocates and registers each in a locked
  set) and times its polls (`Instant::now`) each time it runs, and they are
  dropped with the plan copy; for a plan of thousands of operators run every
  few milliseconds this was about 15% of the run. The fork's vendored
  datafusion-physical-expr-common can switch them off for the process
  (`SAIL_EXECUTION_METRICS=off`).
- **A shared CTE's reset clears state that every copy of the plan shares**
  (the fork's `WithSharedCtesExec`), so the next run's reset cannot be
  prepared while the current run is going.
- **A hash join's build side measures its memory the expensive way.** The
  build reserves memory with `get_record_batch_memory_size`, which converts
  every column of the build batch to `ArrayData`. In SailDoom's tic, 623
  hash joins (363 with no build rows, 181 with under 10) spent 65 ms of CPU
  building and accounted 96 MB, joins of one build row reporting 1 to 11 MB
  (the whole buffers the row is sliced from). The fork's vendored
  datafusion-common reads the buffers of the common array types directly
  (still counting each once): a tic run 24.5 ms to 22.6 ms, with the next
  point.
- **Without statistics a join can build on its larger side**: 45 of the tic's
  joins did. The fork's slots report their row count (inexact) to the
  planner.
- **Most projection pairs cannot be merged for free**: of 147
  projection-over-projection pairs in the tic, 7 had a side that only picks,
  renames or casts columns; in the others both sides compute (DataFusion's
  common-subexpression projections among them). A merge must also leave alone
  projections with lambda variables, which resolve against the batch their
  own projection sees (`map_filter` broke when a first version merged them).
- **`HashJoinExec` builds its hash table again on every execution** (as it
  must after a reset); with hundreds of joins over small inputs this is a
  visible share of running a cached plan.

## Arrow (arrow-rs)

- **Array equality converts to `ArrayData` first**: `impl PartialEq for
  StructArray` (and for `dyn Array`) is `self.to_data() == other.to_data()`,
  which builds `ArrayData` for both sides and every child before comparing
  anything, even when the types differ.
- **A NULL struct still has full-length children.** The game's world is one
  relation with a struct column per kind; every row carries all 35 kinds'
  structs, NULL but for its own. The tic's 4,785 rows were 6.8 MB of Arrow,
  almost all of it null children, encoded by the server and decoded by the
  client every tic (now 0.5 MB: only changed kinds are returned).
- **Spark Connect's Arrow batches are not compressed.**

## The world as one relation

SailDoom keeps the game's whole world as one relation with a struct column
per kind of state (the player, sectors, Things, monster AI and the rest, 35
in all, `saildoom/world.py`). Each row belongs to one kind and fills only its
own column; the other 34 are NULL. That shape lets one `WITH RECURSIVE` query
carry the whole world from tic to tic, and it has costs:

- **The NULL columns are not free.** A NULL struct in Arrow still has its
  child arrays at full length, so every row carries room for every kind's
  fields. The world's 4,785 rows were 6.8 MB, almost all of it nulls, encoded
  by the server and decoded by the client every tic until the tic returned
  only the kinds that changed (0.5 MB). The same width is why each request
  pays about 4.7 ms just for the 37-column schema, and why measuring a
  batch's memory (DataFusion #26071, and the hash-join build reservation) was
  so expensive.
- **Packing makes typed NULL literals.** Each branch of the world's
  `UNION ALL` puts `CAST(NULL AS STRUCT<...>)` in 34 columns: 1,200 struct
  literals that physical planning compared pairwise (DataFusion #26065).
- **The fix would be a narrower layout**: a relation per kind, or an Arrow
  union type, which Spark SQL does not have. Either means restructuring all
  of the tic's SQL; the port works around the width instead.

### Table slots the tic no longer reads every tic

With the world kept in Sail, each world table's slot (`rec_<table>`) is no
longer refilled every tic: the tic reads the previous world from the one slot
`world`. The `rec_*` slots keep their last rows, stale, and are read only
when they are refreshed first: every tic for the commands
(`rec_game_tic_commands`), and on the fallback path, when something outside
the tic (a cheat, a menu, a load, a new level) has written the tables and
`world` is packed again from them. They cost server memory only.

### Plan: a narrow world (to return to)

Estimated saving: about 5 to 8 ms of a 33 ms tic (15 to 25%), not the
headline the nulls suggest, because most of the tic's logic (most of its
3,551 operators) already works on narrow per-kind CTEs.

| What the width costs | Per tic | Basis |
|---|---|---|
| Shipping the changed rows (0.5 MB, mostly nulls) | ~2 ms, would be ~0.2 ms | measured: the whole 6.5 MB world takes ~30 ms beyond the request, ~4.6 ms per MB |
| Request overhead of the 37-column schema | ~0 | measured: an empty wide result 4.7 ms, one narrow column 4.4 ms |
| Server work on wide rows: unpacking `prev` (67 filtered scans of the 4,785-row world), repacking `step` (35 branches building null struct children), the change hashes | an estimated 3 to 6 ms of ~17 ms of execution | not measured yet |
| Client handling | ~1 ms | measured: `write_kinds` 1.8 ms |
| Planning the 1,200 null struct literals | maybe 1 to 2 s, once a level | not part of steady play |

What a narrow design needs, since one query returns one relation and the
recursive form of a whole run (the video) needs one relation too:

- A result slot per kind instead of one `world` slot (an easy extension of
  the fork's `/* sail.result_slot=... */`).
- A narrow way to return the changed rows to the client: several result sets,
  or a serialized row per change; each has its own cost.
- Every `sql/tic_*.sql` file's unpack and pack layer redone, and every trace
  and recorded run re-verified for exactness.

First step, about 15 minutes: time the tic's unpack, repack and change-hash
layer on its own, with no game logic, as a cached query, to turn the 3 to
6 ms estimate into a measurement before deciding.

## Spark SQL against Postgres and CedarDB

### Integers, division, rounding

- Postgres divides integers as integers; Spark's `/` always returns a double.
  Use `DIV` (which truncates toward zero, as Postgres does).
- Postgres' float-to-integer cast rounds half to even (`bround` in Spark);
  Spark's truncates. CedarDB's casts to an integer truncate.
- `ROUND(double)`: half away from zero in CedarDB and in Spark (`HALF_UP`).
- `CEIL`/`FLOOR` of a double return a double in Postgres, a `BIGINT` in Spark.
- Numeric division in CedarDB truncates to a scale that depends on the
  operands: `200.0/2048.0` is `0.0976562`, `8.0*16.0/7.0` is `18.285714`
  (SQLDoom's automap arrow length).

### Single precision

- In CedarDB, `real` combined with an integer or a decimal literal stays
  `real`, and `POWER` and `SQRT` of a `real` are `real`: single precision
  throughout (Postgres widens to double). `saildoom/sqlmacro.py` has `FHYPOT`.
- `real - real` is single precision before a double multiply (the camera's
  interpolation).
- A decimal literal sent as a parameter becomes a `real` in CedarDB as
  f32(mantissa) / f32(10^k) when written plainly, nearest when written with
  an exponent: a different float a third of the time
  (`saildoom/backend.py` `cedar_real`, probed against 2,000 values).
- CedarDB returns `real` to clients as its shortest text; Sail returns the
  float32 value as a double.
- `215.18106079101562` as a double literal: CedarDB and Sail both give
  `0x406ae5cb3fffffff`, one ulp below the correctly rounded value.

### Functions and syntax

- `generate_series(a, b)` is empty when `a > b`; Spark's `sequence(a, b)`
  counts down (the `GS` macro guards it).
- `GET_BYTE` on texture blobs becomes a join on a texel table; `LATERAL ...
  LIMIT 1` becomes a window and a join; correlated scalar subqueries become
  joins.
- `ARG_MAX` ties are broken arbitrarily in CedarDB; ties made deterministic
  with a secondary key (`layer * 256 + palette_index`).
- Three-valued logic: `NOT (exists AND state = 'dead')` drops a row with no
  state; a `COALESCE` there would keep it. `COALESCE(a AND b AND c, FALSE)` is
  true only when all three are.
- Void functions return `''` to the client in CedarDB.

### Order and sequences

- A `BIGSERIAL` consumes a value for every attempted insert, including rows
  that `ON CONFLICT DO NOTHING` drops, as in Postgres.
- CedarDB's order among one statement's inserted rows follows its plan, not
  the order of the `UNION ALL`; sound event ids are compared as a set per tic.
- CedarDB returns rows in no fixed order; traces are sorted before comparing.

### Floating point across platforms

- The last bit of `cos`, `tan`, `pow`, `atan2` and `sin` differs between
  Apple's libm (Sail on macOS) and glibc (CedarDB in Linux); a flipped last
  bit can move a `FLOOR` across an integer (5 of 526 renderer frames, 1 to 8
  pixels each).
- `-0.0` and `0.0` print differently and are compared as different values.
