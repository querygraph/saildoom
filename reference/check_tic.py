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


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import game  # noqa: E402

FIELDS = ("position_x", "position_y", "base_z", "view_z", "view_angle",
          "momentum_x", "momentum_y", "momentum_z", "bob_strength",
          "previous_x", "previous_y", "previous_view_z", "previous_view_angle",
          "sector_id", "level_tics", "t_x", "t_y", "t_z", "t_angle")

# kind -> the columns that identify a row within a tic
KEYS = {"S": ("id",), "M": ("sector_id",), "E": ("player_thing_id", "line_id", "trigger_type"),
        "A": ("line_id",), "B": ("line_id", "sidedef_id", "texture_part"), "D": ("id",),
        "R": ("seg_id",), "T": ("id",), "H": ("thing_id",), "I": ("thing_id",),
        "N": ("thing_id",), "X": ("effect_id",), "W": ("player_thing_id",),
        "O": ("player_thing_id", "weapon_id"), "U": ("thing_id",),
        "L": ("player_thing_id", "sector_id"), "Y": ("line_id",)}


def same(a, b):
    return (a == b) or (isinstance(a, float) and isinstance(b, float)
                        and math.isnan(a) and math.isnan(b))


def check_player(got, want, tics):
    got = {r["tic"]: r for r in got}
    want = {r["tic"]: r for r in want}
    bad = {f: [] for f in FIELDS}
    for t in tics:
        if t not in got:
            bad["position_x"].append(t)
            continue
        for f in FIELDS:
            if not same(got[t][f], want[t][f]):
                bad[f].append(t)
    for f in FIELDS:
        if bad[f]:
            t = bad[f][0]
            g = got.get(t, {})
            print(f"  P {f:20s} differs on {len(bad[f]):4d} tics; first tic {t} "
                  f"(mode {g.get('last_mode')}): sail {g.get(f)!r} cedar {want[t][f]!r}")
        else:
            print(f"  P {f:20s} identical")


def check_table(kind, key, got, want, tics):
    def index(rows):
        out = {}
        for r in rows:
            out.setdefault(r["tic"], {})[tuple(r[k] for k in key)] = r
        return out
    got, want = index(got), index(want)
    bad = []
    for t in tics:
        g, w = got.get(t, {}), want.get(t, {})
        diffs = []
        for k in sorted(set(g) | set(w), key=repr):
            if k not in g or k not in w:
                diffs.append((k, "only sail" if k in g else "only cedar"))
                continue
            cols = [c for c in w[k] if not same(g[k].get(c), w[k][c])]
            if cols:
                diffs.append((k, {c: (g[k][c], w[k][c]) for c in cols}))
        if diffs:
            bad.append((t, diffs))
    rows = sum(len(want.get(t, {})) for t in tics)
    if not bad:
        print(f"  {kind} identical ({rows} rows)")
        return
    t, diffs = bad[0]
    print(f"  {kind} differs on {len(bad)} tics ({rows} rows); first tic {t}: "
          f"{len(diffs)} rows, e.g. {diffs[:3]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=Path, default=ROOT / "reference/run-e1m1-b")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    ap.add_argument("--mode", choices=("step", "recursive"), default="step")
    ap.add_argument("--tics", type=int, default=1200)
    args = ap.parse_args()

    spark = game.connect()
    run = game.load_run_for_tics(spark, args.data, args.run)
    t0 = time.perf_counter()
    if args.mode == "step":
        got = game.step_all(spark, run, args.tics, args.run)
    else:
        got = game.simulate(spark, run, args.tics, args.run)
    rows = sum(len(v) for v in got.values())
    print(f"{args.mode}: {rows} rows in {(time.perf_counter() - t0) * 1000:.0f} ms")
    want = game.recorded(spark, run, args.tics, args.run)
    tics = sorted({r["tic"] for r in want["P"]} - {0})
    tics = [t for t in tics if t <= args.tics]
    print(f"{len(tics)} tics compared")
    check_player(got["P"], want["P"], tics)
    for kind, key in KEYS.items():
        check_table(kind, key, got[kind], want[kind], tics)


if __name__ == "__main__":
    main()
