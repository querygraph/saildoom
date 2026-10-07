# What SailDoom found in Sail

SailDoom runs SQLDoom, CedarDB's port of Doom to SQL, on Sail. The
renderer is one query per frame, and the game logic is one query per tic:
710 KB of Spark SQL with 312 CTEs. Through SQLDoom's own client, the game
plays at about 32 tics and 10 frames a second; Doom runs at 35. Every row of
every tic, and every pixel, is checked against CedarDB. That makes Sail's
behaviour easy to observe exactly, under a workload unlike TPC-DS: very wide
plans, small data, and the same query run thousands of times.

The work ran on a fork, `querygraph/sail` `work/recursive-cte`, based on Sail
main `d29516a74`. This report sorts what it found into three groups,
following the rule that Sail adopts only what would run on Spark in
principle:

- **A.** Changes with no new API and no change in semantics. They would
  apply to any query as it is written for Spark.
- **B.** Bugs and gaps, with what Spark does in each case.
- **C.** The fork's Sail-specific conventions. For each: whether Spark has an
  equivalent, how the need might be met in a Spark-compatible way, and what
  has no Spark counterpart and would stay a fork experiment.

Every number comes from SailDoom's measurements on an M1 Max; `NOTES.md` and
`DDD.md` in the SailDoom repository have them in context. Where this report
describes Spark behaviour I am not sure of, it says so.

## A. Changes with no new API

These change no query semantics. The fork's function feature tests pass with
all of them (5,375 to 5,378, depending on the commit).

### A1. Recursive CTEs (`WITH RECURSIVE`)

Sail main resolves `WITH RECURSIVE` with a todo in `recursion.rs`. The fork
adds them (`150345a83`), including a recursive term that refers to its CTE
more than once (`e0c9e9fd7`, by sharing the work table between references).
The whole game runs as one recursive query: 1,200 tics in 202 s, or 168 ms a
tic.

Spark compatibility: my understanding is that recursive CTEs arrive in Spark
in the 4.x line (SPARK-24497), but I have not checked which release, its
syntax, or its limits. That includes an iteration cap and whether a
recursive term may refer to the CTE more than once. Sail would want to match
those.

### A2. A CTE referenced more than once is computed once

Sail resolves a CTE into a plan subtree and copies it at every reference. It
also resolves every CTE in a `WITH`, used or not. SQLDoom's renderer, inlined
that way, was 8.4 MB of EXPLAIN text and took seconds to optimize. The fork
computes a CTE referenced more than once only once (`d7d7e7cf8`; shared
results in `sail-physical-plan/src/shared_cte.rs`).

Two fixes the game found:
- CTEs that read a recursive CTE's work table were treated as references to
  it and inlined, which grew the tic's plan exponentially (`10fe27c9d`).
- A shared CTE defined outside an inner recursive query was reset from
  inside it, so its consumed plan ran again (a `RepartitionExec` panic). The
  owner now resets it (`f0c5e7567`).

On TPC-DS SF1 (the 22 queries that reuse a CTE, plus 4 controls) it is
neutral, with identical results. At that scale an inlined copy runs in
parallel and streams, while a shared result is collected first and replayed
as one partition.

Spark compatibility: Spark has no SQL to say whether a CTE is shared; this is
an execution strategy, invisible to queries. I am not certain which
strategy Spark itself uses for multiply referenced CTEs.

### A3. Fewer operators over in-memory leaves (`38c8f0e47`)

Sail reads a CTE through a projection at every reference, giving the columns
the reference's own ids. DataFusion's `EnsureCooperative` also puts a
`CooperativeExec` over every leaf that doesn't say it is cooperative. In the
tic plan's 5,227 operators:
- 820 were column-only projections over a CTE reference or a slot scan;
- 856 were `CooperativeExec`s over those same leaves.

In the fork, the leaves make their streams cooperative themselves and say
so. A physical optimizer rule (`FoldLeafProjections`) folds a projection
that only picks and renames columns into the leaf below it. The plan drops
to 3,551 operators, and a run from 33 ms to 28 ms.

### A4. Merging free projection pairs (`e4e57c144`)

`MergeProjections` merges a projection into the one below it when one side
only picks, renames or casts columns. It leaves alone any projection with
lambda variables: an early version broke `map_filter` by merging into one,
and the feature tests caught it. Only 7 of the tic's 147
projection-over-projection pairs qualified. In the rest both sides compute,
DataFusion's common-subexpression projections among them.

### A5. Don't format plans nothing reads (`72fe62be7`)

`resolve_and_execute_plan` formats the initial logical, final logical and
final physical plans as strings on every request. For the 710 KB tic that
was about 15% of planning. The fork adds `resolve_and_plan_physical`, which
skips them, for callers that discard them.

### A6. DataFusion inefficiencies the fork vendors fixes for

These are DataFusion's, not Sail's, and are reported upstream:
- **Struct literal equality in planning:** `ScalarValue` compares struct
  literals through `ArrayData` (apache/datafusion#26065, PR #26066). The
  tic's planning went from 6.5 s to 4.7 s.
- **The output-bytes metric:** every operator measured every batch for it
  (apache/datafusion#26071).
- **Hash join memory accounting:** each build side's memory was counted
  through `ArrayData`.

Until DataFusion releases fixes, Sail could take the same changes by
vendoring, as the fork does. The fork vendors `datafusion-common` and
`datafusion-physical-expr-common` 55.1.0.

### A7. Row counts for in-memory leaves

Without statistics, a join can build its hash table on the larger input: 45
of the tic's joins did. The fork's slot scans report their current row count
as inexact (`e4e57c144`). The same idea applies to any in-memory relation
Sail holds, such as a local relation or a cached DataFrame. Nothing new is
visible to queries.

## B. Bugs and gaps

| What | Spark | Notes |
|---|---|---|
| [lakehq/sail#2742](https://github.com/lakehq/sail/issues/2742): a `CASE` over arrays of structs panics when only a later branch has a NULL item | Spark evaluates it | Filed. A maintainer says lakehq/sail#2643 addresses it. SailDoom makes every branch's items nullable. |
| A `CASE` over arrays of structs fails when every row of a batch takes a branch with non-null items: it returns `List(non-null Struct)` under its declared `List(Struct)` (the other half of #2742; one-line repro in DDD.md) | Spark evaluates it | Filed: [lakehq/sail#2747](https://github.com/lakehq/sail/issues/2747). Data-dependent: the renderer lost 1 or 2 frames a run to it. |
| A deeply nested or very long arithmetic expression overflows a tokio worker's stack ("thread 'tokio-rt-worker' has overflowed its stack") and aborts the whole server | Spark analyzes such expressions; I have not checked its own depth limits | Not filed. A query should fail, not take the server down with it. |
| `df.persist()` / `cache()` is a no-op ("Persist operation is not yet supported"), and `CACHE TABLE` is not implemented | Spark keeps the data | Not filed. Also the root of C1. |
| PySpark 4.2's `createDataFrame` reads eleven `spark.sql.session.localRelation*` and related settings that Sail doesn't define, so the client fails until they are set | Spark defines them | Not filed. SailDoom sets Spark's defaults (`saildoom/engine.py`). |
| `localCheckpoint()` needs `execution.checkpoint.path`; with `memory:///` it works, but checkpoints live until the session ends, because the `RemoveCachedRemoteRelationCommand` handler is a no-op | Spark releases a cached remote relation when the client drops it (my understanding) | Not filed. |
| `df.write.parquet` of an empty result writes no files, not even one with the schema, so reading the directory back fails | Spark writes a file with the schema (my understanding; not checked on every version) | Not filed. |
| `spark.sql.shuffle.partitions` set on a session doesn't change how many partitions Sail plans for; `execution.default_parallelism` is server-wide, with 0 meaning one per core | Spark honours `spark.sql.shuffle.partitions` per session for shuffles | Not filed. This mattered: the tic ran in 680 ms at 10 partitions and 48 ms at 1. Honouring the Spark setting would meet most of C3. |
| Once, with two clients replaying against one server at the same time: `internal error: task context not found for operation` | n/a | Not reproduced since; not filed. |
| A cross join emits one batch per row of its left input, so `big CROSS JOIN one_row` produced 164,700 one-row batches | Spark doesn't batch that way | Not filed. Putting the one-row input first works around it. |
| Deep filter chains optimize superlinearly: 10 levels 26 ms, 50 levels 1.2 s, 100 levels 26 s | Not compared | Not filed. Plain projection or filter chains stay linear. |
| Planning dominates small queries: a frame was 0.7 s, about a third parsing (the chumsky parser) and a third physical planning, at about 58 µs per simple expression | Not compared | Context for C2. |
| The local job runner wraps every operator in a `TracingExec` on every execution. For a plan of hundreds of small operators run often, that costs more than the work. | n/a | The fork runs cached plans without it. Making it cheap or optional would help any repeated small query. |
| `spark.sql()` is a round trip in which the server parses the SQL as a command (0.5 s for the 710 KB tic); every DataFrame then gets a new `plan_id` | This is how PySpark Connect works with any server | Not a Sail bug. It matters for C2: a cache keyed by the relation must leave out the `plan_id`, and clients should reuse DataFrames. |
| PySpark's `toArrow()` first asks the server for the schema (an analyze request: for a DataFrame the client hasn't run, the query is parsed and resolved again, 1 s for the tic), then casts the whole result to it | Client behaviour | Not Sail's to fix. A cheaper analyze path for repeated relations would help. |
| Two sessions running small plans slow each other: the tic takes 55 ms alone and about 60 ms while another session renders, wherever the renderer's client runs and whatever its partition count | n/a | Observed only; not investigated further. |
| Inside a plan, columns carry Sail's internal ids (`#19468`), not the query's names; only the final projection renames them | Internal | Relevant to anything that reads intermediate results, such as C4. |

## C. The fork's Sail-specific conventions

The fork changes no standard Spark behaviour unless a client opts in through
these. Each was added to make SailDoom interactive.

### C1. Slot views: `spark.sail.slotViews`

**What it does.** Creating or replacing a temporary view named in this
setting runs its query once and keeps the rows in memory on the server. A
plan reading the view sees the rows held when it runs. SailDoom keeps the
world's tables, the map's static tables and the tic's inputs this way. One
measured effect: a view over a Parquet file is read again on every run; the
tic's 25 definition tables read through plain views cost it about 4 ms a run
(34 ms to 30 ms once they became slots).

**Spark's equivalents:** `CACHE TABLE` and `df.persist()` (B: no-ops in
Sail), and Spark Connect's cached relations (`localCheckpoint`, with the
lifetime issue in B).

**A Spark-compatible path.** If Sail implemented `CACHE TABLE` / `persist`
as in-memory relations, the "read once, then from memory" part would need no
convention. What `CACHE TABLE` doesn't give is a cached plan reading new rows
when the table is replaced; that depends on C2.

### C2. The plan cache: `spark.sail.planCache`

**What it does.** With `true`, Sail keeps each query's physical plan, keyed
by a hash of the relation as received, without the client's `plan_id`. A
repeated query isn't parsed or planned again: its operator state is reset
and the plan runs. The contract is that inputs other than slots don't change
while it's on. Planning the tic took 4.7–6.5 s; a cached run takes about
23 ms.

**Spark's equivalent:** none that I know of. Spark plans each query.

**A Spark-compatible path.** The cache could be made invisible: keyed on the
relation plus the versions of every table and view it reads, invalidated
when any changes, and on by default. Queries would see no difference, only
speed. This is the change with the most effect on repeated small queries.
It needs care with operator state (DataFusion's `reset_plan_states`
recomputes every node's properties; the fork resets keeping them) and with
dynamic filters (apache/datafusion#26054).

### C3. `spark.sail.targetPartitions`

**What it does.** Sets the number of partitions cached plans are planned
for: 1 for the tic, 4 for frames.

**Spark's equivalent:** `spark.sql.shuffle.partitions` (B). Honouring it per
session would meet this need without a Sail-specific name.

### C4. Result slots: `/* sail.result_slot=NAME[:CTE] */`

**What it does.** A leading comment that sends a query's result, or the rows
it computed for one of its shared CTEs, into a slot on the server. SailDoom
keeps its world there between tics instead of the client sending it back:
about 8 fills a tic became 3.

**Spark's equivalent:** none. The nearest is `CREATE OR REPLACE TEMP VIEW …
AS` plus caching, which would mean two queries and planning each time.
Keeping a CTE's rows as a side effect of a query has no counterpart.

**Path:** stays a fork experiment.

### C5. Slot inputs as query arguments: `__slot_NAME`

**What it does.** Named arguments whose value is an Arrow IPC stream (a
binary literal) fill slot NAME before a cached plan runs, and are left out
of the cache key. A tic sends its inputs with the request that runs it, one
round trip instead of two: 27 ms instead of 32.

**Spark's equivalent:** parameterized queries (`spark.sql(query, args=...)`)
carry values, but they are literals bound into the plan, not rows filling a
table.

**A Spark-compatible path.** Parameterized queries plus the transparent
cache in C2, with argument values bound at execution, would serve scalar
inputs. Rows as arguments have no counterpart and would stay an experiment.

### C6. `SAIL_EXECUTION_METRICS=off`

**What it does.** A server environment switch: operators register no
execution metrics and don't time their polls. In the vendored
`datafusion-physical-expr-common`, a cached tic went from 26.2 ms to 22.8 ms.
`EXPLAIN ANALYZE` then shows no metrics (three of the fork's explain feature
tests fail with it off).

**Spark's equivalent:** none that I know of; Spark collects SQL metrics
always.

**Path:** a server-level switch with no query-visible API. The better fix is
upstream, making metrics cheap, which #26071 starts.

## The fork's commits

On `querygraph/sail` `work/recursive-cte`, newest first:

| Commit | Change |
|---|---|
| `06146a94b` | feat: slot inputs as query arguments |
| `ec65599ca` | chore: lockfile for sail-spark-connect's sail-physical-plan dependency; keep the vendored crate's Cargo.lock |
| `e4e57c144` | perf: cheaper hash join builds, join sides from slot sizes, merged projections |
| `e3acc4bc6` | perf: an opt-in switch for execution metrics |
| `38c8f0e47` | perf: fewer operators over shared CTE references and slot scans |
| `e8734a3c7` | feat: result slots |
| `1910cf780` | perf: vendor datafusion-physical-expr-common with a cheap output bytes metric |
| `5fa7b24c0` | perf: key the plan cache by a hash of the relation's encoding |
| `860f38773` | perf: run cached plans without parsing, tracing or recomputed properties |
| `72fe62be7` | feat: plan reuse over slot views |
| `ce780f0d2` | perf: vendor datafusion-common with cheap equality for nested scalars |
| `9c41ac027` | docs: link the DataFusion issue for the aggregate dynamic filter workaround |
| `2285f2330` | fix: no aggregate dynamic filters in plans with a recursive query |
| `f0c5e7567` | fix: let the owner, not a reference, reset a shared CTE's result |
| `10fe27c9d` | fix: share CTEs that read a recursive CTE's work table |
| `d7d7e7cf8` | feat: compute a CTE referenced more than once only once |
| `e0c9e9fd7` | feat: let a recursive CTE's recursive term refer to the CTE more than once |
| `150345a83` | feat: support recursive CTEs (WITH RECURSIVE) |

Upstream contributions would follow the usual path: small reviewed pull
requests distilled from this branch, starting with group A.
