# TPC-DOOM, version 0.1 (draft)

How fast does your SQL database run Doom?

TPC-DOOM is a benchmark that Andy Grove, Apache DataFusion's original author,
proposed as a joke after SQLDoom appeared. It takes the joke at its word: the
workload is [SQLDoom](https://github.com/cedardb/sqldoom), CedarDB's port of
Doom to SQL, in which every game tic and every frame is a query, and the
question is how close a database gets to playing Doom the way Doom plays,
35 tics a second with a frame for each.

TPC-DOOM is not a benchmark of the Transaction Processing Performance Council
and has no connection with it. "TPC" is the Council's trademark; here it is
the joke's. All the credit for Doom in SQL is SQLDoom's.

## 1. The workload

| | |
|---|---|
| Game | SQLDoom, [`cedardb/sqldoom`](https://github.com/cedardb/sqldoom) at commit `95753a2`: its client's database API (`doom_sql.py`) and the statements behind it |
| Data | Freedoom 0.13.0 `freedoom1.wad`, loaded into SQLDoom's tables by SQLDoom's loader (`wad_loader.py`) |
| Level | E1M1, skill 2 |
| Input | The recorded run [`tpc-doom/inputs/run-e1m1-b-commands.json`](inputs/run-e1m1-b-commands.json), 1,200 tic commands, SHA-256 `593c517b…f7ed94`: a bot's run with god mode and every weapon (cheats typed before tic 1), firing chaingun, shotgun and rockets, imps throwing fireballs, barrels chaining, doors, a lift, pickups and a secret |
| Driver | [`tpc-doom/driver.py`](driver.py) |

The system under test (SUT) is everything between the driver's call into
`doom_sql.py` and the result coming back: the database, its server, and any
layer that turns SQLDoom's statements into what the database runs. On a
PostgreSQL-protocol database that can run SQLDoom's statements as shipped,
the SUT is the database. A database that cannot may answer them another way:
a different dialect or a translating layer. That layer is part of the SUT,
its time is measured, and its source must be disclosed.

## 2. The tests

Each timed test starts the level, as SQLDoom's client starts a new game
(`set_screen`, `enter_level`, then the cheats `IDDQD` and `IDKFA`), then plays
the 1,200 tics. Its first 120 tics are the **warm-up**, and the other 1,080
are the **measurement interval**. Metrics are taken over the measurement
interval. The warm-up is reported, including its slowest tic, because that is
where a level's queries get planned or compiled.

**Test T, tics.** Every tic of the run, back to back, as SQLDoom's client runs
one (`run_game_tic`): `execute_game_tic`, then `fetch_sound_events` if the tic
made sounds, then `finish_game_tic`.

**Test R, real time.** The level starts again. The renderer is prepared for
it (`prepare_renderer`), and that first frame is timed on its own. Then every
tic is followed by a frame, as Doom draws one per tic: the tic as in test T,
then `camera_pose` at the tic just run and `render_frame` from that pose, a
320 × 200 RGB image.

**Test E, exactness (required).** The driver keeps every tic's snapshot (what
`finish_game_tic` returns) from test T, and a digest of every frame from
test R. Each is compared with the reference run on CedarDB:

- snapshots must be equal, with doubles equal to 1 part in 10⁹, which allows
  for the last bits of `sin`, `atan2` and `pow`, where libm implementations
  differ;
- frames must be byte-identical, except where a difference is traced to the
  last bit of a libm function moving a value across an integer. The report
  counts those frames and their pixels. Any other difference makes the run
  inexact.

A run that is not exact has no TPC-DOOM result. It may be published as
"inexact", with its differences.

**Test P, play (informative).** SQLDoom's own client, in real time, over the
SUT: its steady-state tics and frames per second. The client runs tics on a
35 Hz clock, up to four per pass of its loop, and renders on a second
connection when the last frame is done. The result depends on the client's
scheduling and is not comparable across systems; it is what a player sees.

**Test S, one query (optional).** The 1,200 tics as a single query, for a
system that can express the game loop that way (for example
`WITH RECURSIVE`). Report the elapsed time and how the final state was
checked.

## 3. Metrics

| Metric | Definition |
|---|---|
| **tpsD** (primary) | Test R: tic-and-frame pairs per second over the measurement interval |
| **RTF**, real-time factor | tpsD / 35. A system with RTF ≥ 1 runs Doom. |
| tps (tics only) | Test T: tics per second over the measurement interval |
| Tic latency | Test T: mean, p50, p95 and max |
| Frame latency | Test R: mean, p50, p95 and max of `camera_pose` plus `render_frame` |
| Level start | `set_screen`, `enter_level` and the cheats |
| Warm-up | Each test's first 120 tics: elapsed time, first tic, and the slowest tic with its number |
| First frame | `prepare_renderer` and the level's first frame |

## 4. Rules

1. **Online input.** The driver sends tic *n*'s command only after tic *n − 1*
   has returned. Nothing in the SUT may depend on a command it has not yet
   received. Test S is the only exception.
2. **One connection, one call at a time** in tests T and R.
3. **Compute every answer.** Each snapshot and frame is computed from the
   game's state at that tic. Answers may not be kept from an earlier run.
   Query plans, compiled code and prepared statements may be kept, and the
   warm-up and level start show what they cost.
4. **Default settings, or disclosed ones.** Any non-default setting,
   extension, fork or patch of the SUT is disclosed with its source.
5. **Three runs.** Each SUT is run three times after a server start. The
   report gives the run with the median tpsD and the results of all three.
6. **Loading is not timed.** The data are loaded before the run, and how they
   were loaded is disclosed.
7. **Durability is not required** in version 0.1. The report states what the
   SUT does with the game's state (in memory, written back, when).

## 5. Disclosure

A TPC-DOOM report states:

- the hardware, operating system, and any virtual machine or container with
  its CPU and memory limits;
- the SUT: the database and its version or commit, the translating layer (if
  any) and its commit, settings, and any extensions or patches;
- the client: Python, the database driver, and the driver's commit;
- the metrics of section 3 for the median run, and tpsD for all three;
- the outcome of test E, with every difference explained;
- the result files the driver wrote.

Version 0.1 has no price/performance metric.
