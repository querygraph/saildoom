"""Check the tic port against a recorded run.

  check_tic.py --mode step       every recorded tic t -> t + 1 in one query,
                                 compared with the recording's tic t + 1
  check_tic.py --mode recursive  the whole run as one WITH RECURSIVE query
                                 from tic 0, compared tic by tic

Needs a Sail with recursive CTEs (querygraph/sail work/recursive-cte):
SAIL_REMOTE=sc://localhost:50052.
"""

import argparse
import json
import math
import sys
import time
from pathlib import Path

import pyarrow as pa

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import game  # noqa: E402

FIELDS = ("position_x", "position_y", "base_z", "view_z", "view_angle",
          "momentum_x", "momentum_y", "momentum_z", "bob_strength",
          "previous_x", "previous_y", "previous_view_z", "previous_view_angle",
          "sector_id", "level_tics", "t_x", "t_y", "t_z", "t_angle")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=Path, default=ROOT / "reference/run-e1m1")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    ap.add_argument("--mode", choices=("step", "recursive"), default="step")
    ap.add_argument("--tics", type=int, default=525)
    ap.add_argument("--show", type=int, default=6)
    args = ap.parse_args()

    spark = game.connect()
    run = game.load_run_for_tics(spark, args.data, args.run)
    t0 = time.perf_counter()
    if args.mode == "step":
        got = game.step_all(spark, run, args.tics)
    else:
        got = game.simulate(spark, run, args.tics)
    print(f"{args.mode}: {got.num_rows} rows in {(time.perf_counter() - t0) * 1000:.0f} ms")
    want = game.recorded_players(spark, run, args.tics)

    got = {r["tic"]: r for r in got.to_pylist()}
    want = {r["tic"]: r for r in want.to_pylist()}
    tics = sorted(t for t in got if t in want and t > 0)
    bad = {f: [] for f in FIELDS}
    for t in tics:
        for f in FIELDS:
            a, b = got[t][f], want[t][f]
            same = (a == b) or (isinstance(a, float) and isinstance(b, float)
                                and math.isnan(a) and math.isnan(b))
            if not same:
                bad[f].append(t)
    print(f"{len(tics)} tics compared")
    for f in FIELDS:
        if bad[f]:
            t = bad[f][0]
            print(f"  {f:20s} differs on {len(bad[f]):4d} tics; first tic {t} "
                  f"(mode {got[t].get('last_mode')}): sail {got[t][f]!r} cedar {want[t][f]!r}")
        else:
            print(f"  {f:20s} identical")


if __name__ == "__main__":
    main()
