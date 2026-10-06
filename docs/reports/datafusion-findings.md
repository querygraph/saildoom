# What a game found in DataFusion

Findings for the Apache DataFusion team from running Doom on
[Sail](https://github.com/lakehq/sail): DataFusion 55.1.0, through Sail, on
a workload unlike most analytics, with an exact oracle (CedarDB's SQLDoom)
for every row and pixel. Every number below was measured on an Apple M1 Max
(10 cores), release builds. The changes we made live in the
[`querygraph/sail`](https://github.com/querygraph/sail/tree/work/recursive-cte)
fork, `work/recursive-cte`, two of them as vendored DataFusion crates; the
full log of findings is [`DDD.md`](../../DDD.md).

## The workload

[SQLDoom](https://github.com/cedardb/sqldoom) computes each 35 Hz game tic
with SQL. Ported to Spark SQL, one tic is a single query:

- **710 KB of SQL, 312 CTEs**, planned into **5,227 physical operators**
  (1,884 projections, 858 `CooperativeExec`s, 830 shared CTE references,
  630 hash joins), over a few thousand rows.
- **Wide struct columns.** The game's world is one relation with a struct
  column per kind of state, 35 kinds; each row fills one and leaves 34 NULL.
- **Planned once, run every tic.** Planning took 6.5 s, so the plan is kept
  and run again with `reset_state` (`reset_plan_states`-style), reading new
  rows from in-memory tables each tic. Interactive play needs a run in a
  few tens of milliseconds.

Planning and per-operator overhead, not data volume, dominate. The game now
plays at about 32 tics a second; the issues and changes below are most of
how it got there from 7 s a tic.

## Filed

### #26054: `AggregateExec`'s MIN/MAX dynamic filter survives `reset_state`

- **Seen:** in a recursive query, a later iteration of the recursive term
  scanned with the bound the first iteration's aggregate had set. In the game,
  a barrel's blast found no blast radius.
- **Repro:** a recursive CTE whose term aggregates MIN/MAX over a join of the
  work table; compare later iterations with the same SQL run unrolled.
- **Fix suggested:** reset (recreate) the aggregate's dynamic filter in
  `reset_state`.
- **Status:** [issue](https://github.com/apache/datafusion/issues/26054),
  open. The fork turns the aggregate dynamic filter pushdown off in plans
  that contain a recursive query.

### #26058: wrong rows from `eliminate_cross_join` with `extract_equijoin_predicate`

- **Seen:** an inner join whose `ON` has an equi-key plus a second equality
  whose one side spans two cross-joined relations loses the second equality.
  Reproduced on DataFusion 55.1.0 and `main` (8248a57969).
- **Repro (from the issue):**

  ```sql
  SELECT k.k, b.id
  FROM (SELECT 1 AS t, 17 AS x, 18 AS y) a
  CROSS JOIN (SELECT 0 AS k UNION ALL SELECT 1) k
  JOIN (SELECT 1 AS t, CAST(value AS INT) AS id FROM generate_series(0, 20)) b
    ON b.t = a.t AND b.id = CASE k.k WHEN 0 THEN a.x ELSE a.y END
  ORDER BY k.k, b.id;
  ```

  returns 42 rows (every `b.id`, once per `k`) instead of 2. Correct with
  either rule removed.
- **Fix suggested:** when `eliminate_cross_join` regroups the join graph,
  keep a key that references relations on both sides of a cross join as a
  filter (or attach it to a join where both sides are present).
- **Status:** [issue](https://github.com/apache/datafusion/issues/26058),
  open. The game writes the affected query as one branch per case.

### #26065 and PR #26066: struct literal equality in physical planning

- **Seen:** physical planning grows faster than the query when projections
  carry many typed NULL struct literals (`CAST(NULL AS STRUCT<...>)`, from a
  `UNION ALL` that packs kinds into one relation). `ProjectionExec` creation
  calls `EquivalenceProperties::project`; `EquivalenceGroup::add_constant`
  compares each new constant with every class; `ScalarValue::eq` compares
  nested values with arrow's `PartialEq`, which converts both arrays to
  `ArrayData` before comparing anything, even when the types differ. In the
  tic's profile this was about a quarter of all planning samples.
- **Repro:** `UNION ALL` of N branches, each filling one struct column and
  putting typed NULL structs in the others; time `create_physical_plan`
  (the issue has the program).
- **Fix (PR):** in `ScalarValue::eq`, for the nested variants, return early
  for the same `Arc` and compare lengths and data types before arrow's
  equality.

  | struct columns x fields | main | with the PR |
  |---|---:|---:|
  | 10 x 20 | 31 ms | 17 ms |
  | 20 x 20 | 179 ms | 47 ms |
  | 35 x 20 | 862 ms | 147 ms |
  | 35 x 40 | 1,766 ms | 253 ms |

  The tic's planning: 6.5 s to 4.7 s.
- **Status:** [issue](https://github.com/apache/datafusion/issues/26065) and
  [PR](https://github.com/apache/datafusion/pull/26066), open. Vendored in
  the fork (datafusion-common).

### #26071: `output_bytes` converts every column to `ArrayData` for every batch

- **Seen:** `BaselineMetrics::record_poll` records `output_bytes` with
  `get_record_batch_memory_size`, which converts each column and nested child
  to `ArrayData` and hashes every buffer's address. Per batch, on `main`:

  | batch | `get_record_batch_memory_size` | sum of `get_array_memory_size` |
  |---|---:|---:|
  | 35 struct columns x 20 fields, 100 rows | 21.9 µs | 1.6 µs |
  | 35 struct columns x 20 fields, 4,000 rows | 15.1 µs | 1.5 µs |
  | 5 struct columns x 5 fields, 4,000 rows | 0.58 µs | 0.05 µs |

  Paid per operator per batch: about 12% of running the cached tic.
- **Fix suggested:** compute the metric from `get_array_memory_size` (it may
  count a shared buffer twice, acceptable for a metric), or only when a
  metrics level that shows it is requested.
- **Status:** [issue](https://github.com/apache/datafusion/issues/26071),
  open. The fork vendors datafusion-physical-expr-common with the sum: a
  run 40 ms to 34 ms.

## Not filed yet, changed in the fork

### Memory counting for hash join builds

- **Seen:** a hash join's build side reserves memory with
  `get_record_batch_memory_size`, the same `ArrayData` conversion as above.
  In one tic, 623 hash joins (363 with no build rows, 181 with under 10)
  spent 65 ms of CPU building and accounted 96 MB; a join of one build row
  reported 1 to 11 MB (the whole buffers its row is sliced from).
- **Change:** the vendored datafusion-common reads the buffers of primitive,
  boolean, string, binary and struct arrays directly instead of building
  `ArrayData`, still counting each buffer once; other types keep the old
  path. The crate's memory tests pass (shared buffers, nested arrays, nulls).
  A tic run 24.5 ms to 22.6 ms, together with row counts on the fork's
  in-memory scans (below).
- **Worth upstream:** yes, it helps memory accounting everywhere, and the
  same traversal would make #26071's exact form cheap.

### An opt-in switch for execution metrics

- **Seen:** every operator builds its metrics on every execution
  (`MetricBuilder::build` allocates each and registers it in a locked set),
  times its polls (`Instant::now`), and the metrics are dropped with the plan
  copy: about 15% of a run of a plan of thousands of small operators.
- **Change:** with `SAIL_EXECUTION_METRICS=off` in the process environment,
  the vendored datafusion-physical-expr-common neither registers metrics nor
  times polls. A tic run 26.2 ms to 22.8 ms. Off, `EXPLAIN ANALYZE` shows no
  metrics (three of Sail's explain tests fail); the default is unchanged.
- **Worth upstream:** a session-level metrics level (none, summary, dev) that
  skips building metrics nobody reads, rather than a process switch.

## Observations worth attention

| What | Seen | Numbers | Suggested | Filed |
|---|---|---|---|---|
| `reset_plan_states` recomputes properties | Each node's `reset_state` keeps properties (`ChildrenPropertiesMode::Keep`), but the `transform_up` walk rebuilds every parent with `with_new_children`, recomputing them: as costly as physical planning. Its documentation also excludes plans with dynamic filters or recursive queries. | The fork's walk that keeps properties and skips unchanged subtrees was part of a run going from 680 ms to 48 ms (with one partition and no tracing). | Reset with `replace_children(..., Keep)` and leave unchanged subtrees alone. | No |
| `EquivalenceGroup::add_constant` | A linear scan over the classes for every new uniform constant: quadratic in a projection's literals. | Part of #26065. | Key uniform constants by value. | In #26065 |
| Equivalence properties recomputed | Re-planning a projection recomputes its equivalence properties, and `EnsureRequirements`, filter pushdown and projection pushdown replace projections' children repeatedly. | Part of the 36% physical-planning share. | Keep properties where the children's are unchanged (`has_same_children_properties` exists). | No |
| `EnsureCooperative` over in-memory leaves | Every leaf that does not say it is cooperative gets a `CooperativeExec`. | 856 of 5,227 operators in the tic; with 820 column-only projections folded too, 33 ms to 28 ms a run. | In-memory sources can make their streams `cooperative()` and declare `SchedulingType::Cooperative` (the fork's do). | No |
| Per-execution metrics | See the switch above. | ~15% of a run. | A metrics level. | No |
| Hash join build per execution | `HashJoinExec` builds its table again on every run (as it must after a reset); with hundreds of joins over small inputs the fixed cost shows. Without statistics, a join can build on its larger side (45 of the tic's joins did). | 623 joins, 65 ms of build CPU a tic before the memory change. | A cheaper path for tiny build sides; statistics from in-memory sources (the fork's report their row counts). | No |
| A constant list broadcast per batch | `element_at(array(<256 literals>), i)` expands the list with `ScalarValue::to_array_of_size` for every batch (Sail's bounds check, `array_length`, does it again). | About 5% of a tic run, 27 uses; at 300 rows x 27 uses: 2.9 ms, against 9.2 ms for a 256-way `CASE` and 2.7 ms for a join with a 256-row table. | Gather from the scalar list's values with the index array, without broadcasting. | No |
| A cross join emits one batch per left row | `big CROSS JOIN one_row` built the big side and produced 164,700 one-row batches; every operator downstream paid per batch. | A frame 1.6 s to 0.7 s with the one-row input first. | Coalesce, or prefer the smaller side as the collected one. | No |
| Superlinear optimization of deep filter chains | A chain of CTEs each filtering on an expression the previous one built. | 10 levels 26 ms, 25 levels 88 ms, 50 levels 1.2 s, 100 levels 26 s; plain projection or filter chains stay linear (~0.4 ms a level). | Profile the logical optimizer on such chains. | No |
| Projections that cannot merge | Of 147 projection-over-projection pairs in the tic, 7 had a side that only picks, renames or casts; the others both compute (common-subexpression projections among them). A merge must not substitute into projections with lambda variables. | 7 merged, 3,551 to 3,544 operators. | None needed; noted for anyone writing such a rule. | No |

## Arrow (arrow-rs)

- **Array equality converts to `ArrayData` first.** `impl PartialEq for
  StructArray` (and for `dyn Array`) is `self.to_data() == other.to_data()`:
  both sides and every child are built before anything is compared, even when
  the types differ. A type and length check first would have avoided most of
  #26065 for every caller.
- **A NULL struct still has full-length children.** The world's 4,785 rows
  were 6.8 MB of Arrow, almost all null children, until only changed rows
  were returned (0.5 MB). Expected Arrow behaviour, but it multiplies every
  per-column cost above for wide nullable struct layouts.

## Summary of the changes we carry

| Change | Where | Effect on the tic | Upstream |
|---|---|---|---|
| Nested `ScalarValue` equality checks type and length first | vendored datafusion-common | planning 6.5 s to 4.7 s | PR #26066 |
| `output_bytes` from `get_array_memory_size` | vendored datafusion-physical-expr-common | run 40 ms to 34 ms | issue #26071 |
| Memory counted from buffers for common types | vendored datafusion-common | with slot row counts, run 24.5 ms to 22.6 ms | not yet |
| Opt-in switch to skip execution metrics | vendored datafusion-physical-expr-common | run 26.2 ms to 22.8 ms | not yet |
| Aggregate dynamic filter off in recursive plans | Sail fork | correctness | issue #26054 |
