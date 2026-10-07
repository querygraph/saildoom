# TPC-DOOM: how fast does your SQL database run Doom?

![The Doom marine on a lava ridge facing a citadel of glowing database cylinders](https://adversari.al/images/tpc-doom-headboard.jpg)

Doom now runs in SQL: [SQLDoom](https://github.com/cedardb/sqldoom), CedarDB's port, plays it on CedarDB, and [Sail runs it as a single query](https://github.com/querygraph/saildoom/blob/main/docs/blog/sail-runs-doom/post.md). Andy Grove, the creator of [Apache DataFusion](https://datafusion.apache.org/), named what comes next: **TPC-DOOM**, a benchmark of how fast your SQL database runs Doom. He proposed it as a joke. We took it at its word.

TPC-DOOM 0.1 is now defined, with a driver, a first report on two databases and two machines, and a home at **[adversari.al/doom](https://adversari.al/doom)**. The name is Andy's; the credit for Doom in SQL is SQLDoom's. TPC-DOOM is not a benchmark of the Transaction Processing Performance Council and has no connection with it: "TPC" is the Council's trademark, and here it is the joke's.

## What it measures

In SQLDoom every game tic and every frame is a query. The client only reads the keyboard and draws pixels; the game logic, the world and the renderer live in the database. That makes the question concrete: how close does a database come to playing Doom the way Doom plays, 35 tics a second with a frame for each, and with every answer right?

The workload is Freedoom's first level, E1M1, at skill 2, played with a recorded run of 1,200 tic commands: a bot with god mode and every weapon, chaingun, shotgun and rockets, imps throwing fireballs, barrels chaining, doors, a lift, pickups and a secret. [The driver](https://github.com/querygraph/saildoom/blob/main/tpc-doom/driver.py) makes exactly the calls SQLDoom's own client makes, one at a time, and never sends a tic's command before the previous tic has returned.

- **Test T** plays the 1,200 tics back to back.
- **Test R** draws a 320 × 200 frame after every tic. Its rate, tic-and-frame pairs a second, is **tpsD**, the primary metric; **RTF**, the real-time factor, is tpsD divided by 35. A database with an RTF of 1 or more runs Doom.
- **Test E** checks every answer: every tic's snapshot and every frame are compared with CedarDB's, the reference. The game must be right: every snapshot must match. Frames may differ where the last bit of a libm function moves a pixel, and for at most 1% of frames for any other reason, each counted and explained; an inexact run has no result.

The first 120 tics of each test are a warm-up, where a level's queries get planned or compiled, and are reported rather than hidden. The [definition](https://github.com/querygraph/saildoom/blob/main/tpc-doom/SPEC.md) lists what a report must disclose.

## The first report

[Report 0001](https://github.com/querygraph/saildoom/blob/main/tpc-doom/reports/0001.md) runs CedarDB, SQLDoom's own database, and [Sail](https://github.com/lakehq/sail), the Spark-compatible engine on DataFusion that SailDoom runs the game on, three times each on two Macs: Capitola, an M1 Max laptop, and Morrobay, an 18-core Xeon iMac Pro.

| Host | CedarDB tpsD | Sail tpsD |
|---|---|---|
| Capitola (Apple M1 Max) | 6.59 | 6.97 |
| Morrobay (Intel Xeon W-2191B) | 5.64 | 3.55 |

Neither runs Doom yet: drawing a frame for every tic, both are a fifth of real time or less. They get there by different routes.

**CedarDB** runs SQLDoom as written. On its own its tics are fast, 41.2 a second on Capitola in test T, faster than Doom's 35. But it stalls: a tic now and then takes as long as the tic's first compilation, 17 to 18 seconds on Capitola and about 27 on Morrobay, three times in every test R run on both machines. Those stalls take a third of its measured time on Capitola and two fifths on Morrobay; between them CedarDB plays about 10 tic-and-frame pairs a second. Why it stalls is not established, and its log records nothing at those times.

**Sail** is steady and slower per call: on Capitola a tic takes about 41 ms and a frame about 100 ms, with no call over a second after the level's first tic, where the fork plans the tic query once. Sail cannot run SQLDoom's PostgreSQL and CedarScript as shipped; SailDoom's backend answers each call with Spark SQL, on a fork of Sail with recursive queries and opt-in plan reuse, and all of that counts as the system under test.

Sail's results are **exact**. Every snapshot matches CedarDB's, 1,200 of 1,200, on both machines. One frame of the 1,200, after tic 730, draws the floor under the player with the wrong texture, 17,443 pixels of the run's 76.8 million: a renderer bug in SailDoom, open and recorded in [DDD.md](https://github.com/querygraph/saildoom/blob/main/DDD.md). The other frames that differ do so by 1 to 273 pixels, the last bits of Apple's libm against CedarDB's glibc; Sail draws 89 frames differently on the two Macs from the same code and data, while CedarDB, the same image in a Linux VM on both, draws them identically. A benchmark that checks every pixel found its own author's bug first, which seems right. (The first version of test E let no such frame through, and marked Sail inexact for this one; the rule now allows up to 1% of frames, for every system.)

## Enter

Any SQL database can enter TPC-DOOM: answer SQLDoom's API, exactly, and disclose how. The driver talks to CedarDB through psycopg2 and to Sail through SailDoom's backend; a PostgreSQL-compatible database that runs SQLDoom's statements as shipped can use the driver's CedarDB path with its own connection string. Every result file carries each tic's snapshot and each frame's digest, so a report can be checked without rerunning it, and [adversari.al/doom](https://adversari.al/doom) is rendered from those files after checking their hashes.

```sh
git clone https://github.com/querygraph/saildoom && cd saildoom
scripts/setup.sh
uv pip install --python .venv/bin/python -r tpc-doom/requirements.txt
TPCDOOM_DSN=postgresql://... .venv/bin/python tpc-doom/driver.py --sut cedardb --out cedardb.json
```

Thanks to Andy Grove for the name, and to CedarDB for SQLDoom.
