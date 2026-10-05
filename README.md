# SailDoom

[SQLDoom](https://github.com/cedardb/sqldoom) renders Doom with one SQL query
on CedarDB ([Ars Technica](https://arstechnica.com/gaming/2026/10/can-it-run-doom-sql-database-edition/),
[CedarDB's write-up](https://cedardb.com/blog/sqldoom)). SailDoom runs that
renderer on [Sail](https://github.com/lakehq/sail), unmodified `main`, as
Spark SQL over Spark Connect.

## Status

| | |
|---|---|
| Renderer | Ported: SQLDoom's 89-CTE query in Spark SQL ([`sql/renderer.sql`](sql/renderer.sql)), and a batch form that renders many frames per query ([`sql/renderer_batch.sql`](sql/renderer_batch.sql)). |
| Exactness | On a 526-tic recorded run of Freedoom E1M1: 521 frames identical to CedarDB's in all 64,000 pixels; 5 differ by 1 to 8 pixels. In each of the 5, Sail's single-frame and batch renderers agree, and the difference traces to the last bit of a libm function (`cos`, `tan`) where Apple's libm (Sail on macOS) and glibc (CedarDB in Linux) disagree. |
| Speed | One frame per query: 0.7 s, almost all of it Sail planning the query. Many frames per query: 43 ms a frame (about 23 frames a second) on an M1 Max with 10 cores. CedarDB renders a frame in 32 ms (Docker on the same Mac). |
| Game logic | **Not ported yet.** SQLDoom's tic (5,900 lines of CedarScript that update about 40 tables in place) still runs on CedarDB; the video below is Sail rendering every frame of a run whose world state was recorded tic by tic from SQLDoom on CedarDB. |

Video: [`video/saildoom-e1m1.mp4`](video/) (every frame rendered by Sail) and
[`video/saildoom-vs-cedardb-e1m1.mp4`](video/) (Sail, CedarDB, and their
difference in red), attached to the release.

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
```

No WAD is included. [Freedoom](https://freedoom.github.io/) (BSD) works; the
shareware `doom1.wad` stays under id Software's terms.

## License

GPL-2.0-or-later, as SQLDoom ([LICENSE](LICENSE)). SQLDoom is Copyright (C)
2026 CedarDB GmbH; this port keeps its renderer's structure and arithmetic.
