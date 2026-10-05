"""Play a run on Sail: the whole game as one recursive query, saved as a run.

  simulate_run.py --run reference/run-e1m1-b --out data/sim-e1m1 --tics 1200

Only tic 0 and the player's commands come from the recorded run; every tic
after that is computed by Sail (saildoom/game.py, sql/tic_*.sql). The result
is written the way reference/record_run.py writes a CedarDB run -- per-tic
state tables, poses.json, run.json -- so reference/compare_batch.py renders it
on Sail and compares every frame with CedarDB's (`frames` links to the
recorded run's). sector_light_fx and mp_players are map data on a
single-player E1M1 (the snapshot never changes) and are copied.
"""

import argparse
import json
import math
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import game  # noqa: E402
from saildoom.world import KINDS  # noqa: E402

STATIC = ("sector_light_fx", "mp_players")


def camera_pose(ps, alpha=1.0):
    """sql/client/camera_pose.sql: the pose a client draws at `alpha` into the
    tic. The position deltas are real - real, so single precision; the rest
    is double."""
    f32 = lambda v: float(np.float32(v))
    sub = lambda a, b: float(np.float32(np.float32(a) - np.float32(b)))
    x = f32(ps["previous_x"]) + sub(ps["position_x"], ps["previous_x"]) * alpha
    y = f32(ps["previous_y"]) + sub(ps["position_y"], ps["previous_y"]) * alpha
    z = f32(ps["previous_view_z"]) + sub(ps["view_z"], ps["previous_view_z"]) * alpha
    a0 = f32(ps["previous_view_angle"])
    d = f32(ps["view_angle"]) - a0 + 180.0
    turn = (d - 360.0 * math.floor(d / 360.0)) - 180.0
    angle = a0 + turn * alpha - 360.0 * math.floor((a0 + turn * alpha) / 360.0)
    return [x, y, z, angle]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=Path, default=ROOT / "reference/run-e1m1-b")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    ap.add_argument("--out", type=Path, default=ROOT / "data/sim-e1m1")
    ap.add_argument("--tics", type=int, default=1200)
    args = ap.parse_args()

    spark = game.connect()
    run = game.load_run_for_tics(spark, args.data, args.run)
    t0 = time.perf_counter()
    world = game.simulate(spark, run, args.tics, args.run)
    print(f"simulated {args.tics} tics on Sail in {time.perf_counter() - t0:.1f} s", flush=True)

    out = args.out
    shutil.rmtree(out, ignore_errors=True)
    (out / "state").mkdir(parents=True)
    for kind, (_, table) in KINDS.items():
        recorded = pq.read_schema(args.run / "state" / f"{table}.parquet")
        rows = sorted(world[kind], key=lambda r: r["tic"])
        arrays = [pa.array([r.get(f.name) for r in rows], f.type) for f in recorded]
        pq.write_table(pa.Table.from_arrays(arrays, schema=recorded), out / "state" / f"{table}.parquet")
    for table in STATIC:
        t = pq.read_table(args.run / "state" / f"{table}.parquet")
        first = t.filter(pc.equal(t["tic"], 0))
        parts = [first.set_column(0, "tic", pa.array([tic] * first.num_rows, pa.int32()))
                 for tic in range(args.tics + 1)]
        pq.write_table(pa.concat_tables(parts) if parts else t, out / "state" / f"{table}.parquet")

    poses = [{"tic": p["tic"], "pose": camera_pose(p)} for p in sorted(world["P"], key=lambda r: r["tic"])]
    (out / "poses.json").write_text(json.dumps(poses))
    meta = json.loads((args.run / "run.json").read_text())
    meta.update(tics=args.tics, simulated_on="sail", recorded_from=str(args.run))
    (out / "run.json").write_text(json.dumps(meta))
    (out / "frames").symlink_to((args.run / "frames").resolve())
    print(f"wrote {out}: {len(poses)} poses")


if __name__ == "__main__":
    main()
