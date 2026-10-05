"""Render a recorded run on Sail in batches and compare every frame with CedarDB.

  compare_batch.py --run reference/run-e1m1 --start 0 --count 70 --batch 35

The static tables come from the map's cut, the state tables from the run's
per-tic snapshots; each batch is one query over frames(frame_id, tic, pose).
"""

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=Path, default=ROOT / "reference/run-e1m1")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--count", type=int, default=35)
    ap.add_argument("--batch", type=int, default=35)
    ap.add_argument("--save", type=Path, help="write Sail's frames here as .rgb")
    args = ap.parse_args()

    run = json.loads((args.run / "run.json").read_text())
    poses = {p["tic"]: p["pose"] for p in json.loads((args.run / "poses.json").read_text())}
    spark = engine.connect()
    engine.load_run(spark, args.data, run["map_id"], args.run / "state")
    meta = engine.map_meta(args.data, run["map_id"])
    sql = engine.batch_sql()
    frames_path = ROOT / "data" / "frames.parquet"
    if args.save:
        args.save.mkdir(parents=True, exist_ok=True)

    differing, times, n = 0, [], 0
    for lo in range(args.start, args.start + args.count, args.batch):
        tics = [t for t in range(lo, min(lo + args.batch, args.start + args.count)) if t in poses]
        t0 = time.perf_counter()
        frames = engine.render_batch(spark, sql, run["map_id"], run["player_thing_id"],
                                     run["skill"], [(t, poses[t]) for t in tics], meta,
                                     frames_path)
        dt = (time.perf_counter() - t0) * 1000
        times.append(dt / len(tics))
        for t in tics:
            got = np.frombuffer(frames[t], np.uint8).reshape(200, 320, 3)
            want = np.frombuffer((args.run / "frames" / f"{t:05d}.rgb").read_bytes(),
                                 np.uint8).reshape(200, 320, 3)
            d = int(np.any(got != want, axis=2).sum())
            differing += d > 0
            n += 1
            if d:
                print(f"  tic {t}: {d} pixels differ")
            if args.save:
                (args.save / f"{t:05d}.rgb").write_bytes(frames[t])
        print(f"tics {tics[0]}..{tics[-1]}: {dt:.0f} ms for {len(tics)} frames "
              f"({dt / len(tics):.1f} ms/frame)", flush=True)
    print(f"{n} frames, {differing} differ from CedarDB; "
          f"median {statistics.median(times):.1f} ms/frame")


if __name__ == "__main__":
    main()
