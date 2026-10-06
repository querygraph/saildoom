# Sail plays Doom: SQLDoom's own client at 32 tics a second on Spark SQL

[Sail](https://github.com/lakehq/sail) is a Spark-compatible compute engine written in Rust on [Apache DataFusion](https://datafusion.apache.org/): PySpark and Spark SQL clients connect to it over Spark Connect, and DataFusion executes what they send. Yesterday Sail [ran Doom as a single query](https://github.com/querygraph/saildoom/tree/main/docs/blog/sail-runs-doom/post.md): a recorded run of Freedoom's first level, every tic of the game computed by one `WITH RECURSIVE` query and every frame rendered in SQL ([the video, "Sail runs Doom as a single query!", is on FunctionalTV](https://youtu.be/Li1srICeNQo)). Now you can play it. [SQLDoom](https://github.com/cedardb/sqldoom)'s own client, unchanged, talks to Sail instead of CedarDB, and every tic and every frame of the game you play is computed by Sail: about 32 tics and 10 frames a second, against Doom's 35.

SQLDoom is CedarDB's port of Doom to SQL, covered by Ars Technica as ["Can it run Doom? SQL database edition"](https://arstechnica.com/gaming/2026/10/can-it-run-doom-sql-database-edition/), and all the credit for Doom in SQL is theirs. Its client is a small Python program: it reads the keyboard, sends one statement per game tic to the database, and draws the frames the database returns. On CedarDB those statements are prepared statements and CedarScript procedures. On Sail they are answered by [SailDoom](https://github.com/querygraph/saildoom)'s API backend, which runs the same game logic as Spark SQL, and they are checked against CedarDB call by call: three recorded sessions of SQLDoom's API (menus, the automap, and a campaign from E1M1 through E1M8's finale with saves, loads, demos and the attract loop, 5,349 calls in all) replay on Sail with every returned row and every changed table identical to CedarDB's, and every frame byte for byte the same.

## From 7 seconds a tic to 27 milliseconds

The first time SQLDoom's client ran on Sail, a tic took 7 seconds. The SQL was not the problem: the same tic logic steps 1,200 tics in 18 seconds when they are planned as one query. The problem was planning. A tic is 710 KB of SQL, 312 CTEs, and Sail planned it from scratch every tic: analysis, logical optimization and physical planning of a plan with 5,227 operators, about 6.5 seconds, for a few milliseconds of work.

So the tic is now planned once per level and run every tic. A fork of Sail, [`querygraph/sail` `saildoom`](https://github.com/querygraph/sail/tree/saildoom), adds a plan cache and *slots*: temporary views whose rows live in memory on the server and are read afresh each time a cached plan runs. The world's state goes into slots, the plan stays, and each tic only the inputs change. Then it was a matter of finding where the remaining milliseconds went, one profile at a time:

| Step | A tic, run alone | What it removed |
|---|---|---|
| Planning every tic | 7 s | |
| Planned once per level (slots, plan cache) | 1.1 s | analysis, optimization, physical planning |
| Cache looked up before parsing; no per-operator tracing; a reset that keeps operator properties | about 0.17 s | parsing 710 KB of SQL each run; recomputing every operator's properties |
| One partition instead of one per core | 0.10 s | repartitioning a few thousand rows |
| Only the kinds of state that changed sent back | 0.09 s | 6.8 MB of null struct columns a tic, now 0.5 MB |
| Cheap output-bytes metric; definition tables in memory; uploads instead of read-backs; writes split by map | 0.055 s | per-batch `ArrayData` conversion; re-reading files; rewriting 141,000 rows of other maps |
| The world kept on the server between tics | 0.045 s | sending the changed state back up every tic |
| Fewer operators (5,227 to 3,551); execution metrics off | 0.041 s | column-only projections, cooperative wrappers, metrics bookkeeping |
| Cheaper hash-join builds; join sides from slot sizes | 0.031 s | 65 ms of CPU a tic building 623 mostly empty hash tables |
| The tic's inputs travel with its request | 0.027 s | a round trip of slot fills before every tic |

The renderer got the same treatment: a frame is planned once per level and runs in about 90 ms. In the client, a tic and a frame share the server, and SQLDoom's client plays at about 32 tics and 10 frames a second in steady play. A level's first tic still takes about 5 seconds, while Sail plans it.

Several of the larger steps were not in Sail at all but in DataFusion, and are general. Physical planning compared struct literals by converting Arrow arrays to `ArrayData` before checking their types ([apache/datafusion#26065](https://github.com/apache/datafusion/issues/26065), fixed in [PR #26066](https://github.com/apache/datafusion/pull/26066): a plan with 35 struct columns from 862 ms to 147 ms). Every operator measured every batch's memory for a metric the same expensive way ([apache/datafusion#26071](https://github.com/apache/datafusion/issues/26071)), and so did every hash join's build side. Along the way the game also found two bugs that return wrong results: an aggregate's dynamic filter surviving a plan reset, which made a barrel's blast find nothing in its radius in a recursive query ([apache/datafusion#26054](https://github.com/apache/datafusion/issues/26054)), and an equi-join key dropped by two optimizer rules together ([apache/datafusion#26058](https://github.com/apache/datafusion/issues/26058)).

## What is Sail and what is the fork

The game needs the fork. Recursive CTEs, and computing a CTE that is read many times only once, apply to every query and change no semantics. So do the operator reductions and the DataFusion fixes, which pass the fork's 5,378 feature tests. The rest is opt-in and Sail-specific: slot views, the plan cache, a per-session partition count, a query that keeps its result (or one of its CTEs) in a slot on the server, inputs sent as query arguments, and switching execution metrics off. These are experiments to make a game interactive, not proposals; [the report for the Sail team](https://github.com/querygraph/saildoom/blob/main/docs/reports/sail-findings.md) sorts every finding by whether it needs a new API, and for each convention names its Spark counterpart, if there is one, and a Spark-compatible way to meet the same need.

Everything the port found, in Sail, in DataFusion, in Arrow, and in the differences between Spark SQL, Postgres and CedarDB (integer division, single-precision arithmetic, how a decimal literal becomes a `real`, libm's last bits on macOS and Linux), is collected in [DDD.md](https://github.com/querygraph/saildoom/blob/main/DDD.md), for Doom-Driven Development. There are three reports: [the whole port](https://github.com/querygraph/saildoom/blob/main/docs/reports/saildoom-on-sail.md), [findings for DataFusion](https://github.com/querygraph/saildoom/blob/main/docs/reports/datafusion-findings.md), and [findings for Sail](https://github.com/querygraph/saildoom/blob/main/docs/reports/sail-findings.md).

## Play it

From a source checkout, on macOS or Linux with git, Rust and [uv](https://docs.astral.sh/uv/):

```sh
git clone https://github.com/querygraph/saildoom.git
cd saildoom
scripts/setup.sh      # about 20 to 40 minutes, mostly building Sail
scripts/play-sail.sh
```

`setup.sh` installs the Python environment, clones SQLDoom's client at the commit SailDoom is checked against, downloads Freedoom's tables as Parquet, and builds the fork. `play-sail.sh` starts Sail and opens the game: W, A, S, D or the arrow keys to move, Ctrl or the mouse to fire, Space to open doors, Tab for the automap.

## What is left

Thirty-five tics a second needs about 3 milliseconds more in the client. The largest known piece is the shape of the world itself: one relation with a struct column per kind of state, 34 of them NULL in every row, which costs an estimated 5 to 8 milliseconds a tic in packing, unpacking and shipping nulls; the plan for a narrow world is in DDD.md. Deathmatch and SQLDoom's multiplayer API are not ported yet, and the game's tables still come from CedarDB's loader rather than from the WAD.

The code is [`querygraph/saildoom`](https://github.com/querygraph/saildoom); the Sail fork is [`querygraph/sail` `saildoom`](https://github.com/querygraph/sail/tree/saildoom).
