# SailDoom

[SQLDoom](https://github.com/cedardb/sqldoom) renders Doom with one SQL query
on CedarDB ([Ars Technica](https://arstechnica.com/gaming/2026/10/can-it-run-doom-sql-database-edition/),
[CedarDB's write-up](https://cedardb.com/blog/sqldoom)). SailDoom runs that
renderer on [Sail](https://github.com/lakehq/sail), unmodified `main`, as
Spark SQL over Spark Connect -- and the game itself, every tic, as one
`WITH RECURSIVE` query on a Sail fork that adds recursive CTEs
([`querygraph/sail` `work/recursive-cte`](https://github.com/querygraph/sail/tree/work/recursive-cte)).

## Status

| | |
|---|---|
| Renderer | Ported: SQLDoom's 89-CTE query in Spark SQL ([`sql/renderer.sql`](sql/renderer.sql)), and a batch form that renders many frames per query ([`sql/renderer_batch.sql`](sql/renderer_batch.sql)). |
| Exactness | On a 526-tic recorded run of Freedoom E1M1: 521 frames identical to CedarDB's in all 64,000 pixels; 5 differ by 1 to 8 pixels. In each of the 5, Sail's single-frame and batch renderers agree, and the difference traces to the last bit of a libm function (`cos`, `tan`) where Apple's libm (Sail on macOS) and glibc (CedarDB in Linux) disagree. |
| Speed | One frame per query: 0.7 s, almost all of it Sail planning the query. Many frames per query (105): 41 ms a frame from one client; with four clients rendering concurrently, **38.8 frames a second**, above Doom's 35, on an M1 Max with 10 cores. CedarDB renders one frame in 32 ms (Docker on the same Mac). |
| Game logic | **Ported.** SQLDoom's tic (5,900 lines of CedarScript over about 40 tables) is Spark SQL over a world held as one relation ([`sql/tic_*.sql`](sql/), [`saildoom/world.py`](saildoom/world.py)): movement, doors, lifts and switches, pickups, weapons and hitscan, projectiles, the monsters (sight, chase, attacks, barrels, blasts), sector effects and Thing physics. A whole run is one recursive query: tic 0 and the player's commands go in, every later tic is computed by Sail. Not ported: what Freedoom E1M1 never reaches (teleports, crushers, stairs, light and donut specials, Nightmare respawns, E1M8's boss floor, deathmatch). |
| Game exactness | On a 1,200-tic run of E1M1 (45 shots with chaingun, shotgun and rockets, 14 kills, imps throwing fireballs, barrels chaining, doors, a lift, pickups, a secret), every row of all 20 world tables matches CedarDB at every tic -- computing each tic from CedarDB's state, and computing the whole run on Sail alone (202 s). The Sail-played run renders to the same frames, byte for byte, as Sail rendering CedarDB's recorded state. |
| Interactive play | SQLDoom's own client, unchanged, plays on Sail ([`scripts/play.py`](scripts/play.py)) at **32 tics a second** with about 9.7 frames a second on screen in steady play; Doom runs at 35. The tic and the renderer each run on a plan kept for the level (the fork's slot views and plan cache): 0.027 s a tic and 0.09 s a frame, run alone; the world stays on the server between tics. The menus, automap and campaign traces of SQLDoom's API replay exactly against CedarDB. See [NOTES.md](NOTES.md) and, for what Doom found in Sail, DataFusion and Arrow, [DDD.md](DDD.md). |

Video: [`video/saildoom-e1m1-played-on-sail.mp4`](video/) (release
`v0.2-game`): the 1,200-tic run, every tic computed and every frame rendered
by Sail. Release `v0.1-renderer` has the renderer-only videos
(`saildoom-e1m1.mp4`, and `saildoom-vs-cedardb-e1m1.mp4` with the difference
in red).

## How it is built

- **Same SQL, different dialect.** Postgres divides integers as integers and
  rounds half to even when it casts a float to an integer; Spark does
  neither, so those are explicit (`DIV`, `bround`). `generate_series` becomes
  a guarded `explode(sequence(...))`, `GET_BYTE` on texture blobs becomes a
  join on a texel table, `LATERAL ... LIMIT 1` becomes a window and a join.
  [`sql/renderer_v1.sql`](sql/renderer_v1.sql) is that port stage by stage;
  it is pixel-exact and takes 9.8 s a frame.
- **One stream.** Sail inlines a CTE at every reference, and SQLDoom reads
  its heavy stages many times. The renderer computes the same pixels with
  every stage read once: seed rows instead of joins back, `explode(array(...))`
  instead of `UNION ALL` of filters, windows instead of self-joins, one texel
  table and one join for every texture.
- **Batches.** Planning dominates a frame, so the batch renderer plans once
  for many frames: every stage is keyed by frame, state tables are read at
  each frame's tic, and the plan does not grow with the number of frames.
- **Exactness first.** Every change is checked against CedarDB pixel by
  pixel ([`reference/`](reference/)): a CTE differ, a frame comparer, a run
  recorder that snapshots the world each tic.

[`NOTES.md`](NOTES.md) has the measurements and what was learned about Sail.

## Running it

```sh
# CedarDB for the reference (Linux only, so Docker on a Mac)
docker run -d --name saildoom-cedar -p 55432:5432 -e CEDAR_PASSWORD='...' cedardb/cedardb
python ../sqldoom/wad_loader.py freedoom1.wad --dsn postgresql://postgres:...@localhost:55432/postgres
python reference/export_cedar.py --dsn ... --out data/freedoom1
python reference/record_run.py --sqldoom ../sqldoom --dsn ... --out reference/run-e1m1 --tics 525

# Sail main, then render the run and compare it with CedarDB
SAILDOOM_SAIL=/path/to/sail scripts/sail-server.sh &
python reference/compare_batch.py --count 526 --batch 105 --save data/sail-frames

# The game on the recursive-CTE fork: check every tic, then play the run on Sail
python reference/record_run.py --sqldoom ../sqldoom --dsn ... --out reference/run-e1m1-b --tics 1200
SAIL_REMOTE=sc://localhost:50053 python reference/check_tic.py --mode step       # each tic from CedarDB's state
SAIL_REMOTE=sc://localhost:50053 python reference/check_tic.py --mode recursive  # the whole run on Sail
SAIL_REMOTE=sc://localhost:50053 python scripts/simulate_run.py --out data/sim-e1m1
python reference/compare_batch.py --run data/sim-e1m1 --count 1201 --batch 35 --save data/sim-frames
```

No WAD is included. [Freedoom](https://freedoom.github.io/) (BSD) works; the
shareware `doom1.wad` stays under id Software's terms.

## License

GPL-2.0-or-later, as SQLDoom ([LICENSE](LICENSE)). SQLDoom is Copyright (C)
2026 CedarDB GmbH; this port keeps its renderer's structure and arithmetic.
