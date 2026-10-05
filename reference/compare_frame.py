"""Render a reference pose on Sail and compare it with CedarDB's frame.

  compare_frame.py --data data/freedoom1 --pose E1M1:350 [--png out.png] [--repeat N]
"""

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--ref", type=Path, default=ROOT / "reference/cedar-e1m1")
    ap.add_argument("--pose", required=True)
    ap.add_argument("--png", type=Path)
    ap.add_argument("--repeat", type=int, default=1)
    args = ap.parse_args()

    meta = json.loads((args.ref / "timings.json").read_text())
    map_name, tic = args.pose.split(":")
    pose = next(p["pose"] for p in json.loads((args.ref / "poses.json").read_text())
                if p["map"] == map_name and p["tic"] == int(tic))
    spark = engine.connect()
    t = time.perf_counter()
    engine.load_map(spark, args.data, meta["map_id"])
    print(f"map loaded in {(time.perf_counter() - t) * 1000:.0f} ms")
    sql = engine.renderer_sql()
    times = []
    for _ in range(args.repeat):
        t = time.perf_counter()
        frame = engine.render(spark, sql, meta["map_id"], meta["player_thing_id"],
                              meta["skill"], pose)
        times.append((time.perf_counter() - t) * 1000)
    print("render ms:", ", ".join(f"{v:.0f}" for v in times[:10]),
          f"| median {statistics.median(times):.1f}")
    ref = (args.ref / "frames" / f"{map_name}_{int(tic):04d}.rgb").read_bytes()
    a = np.frombuffer(frame, np.uint8).reshape(200, 320, 3)
    b = np.frombuffer(ref, np.uint8).reshape(200, 320, 3)
    diff = np.any(a != b, axis=2)
    print(f"pixels differing from CedarDB: {int(diff.sum())} of 64000")
    if diff.any():
        ys, xs = np.nonzero(diff)
        print("  first:", list(zip(xs[:10].tolist(), ys[:10].tolist())))
        print("  rows with differences:", sorted(set(ys.tolist()))[:40])
    if args.png:
        import pygame
        side = np.concatenate([a, b, (diff[..., None] * 255).repeat(3, 2).astype(np.uint8)], axis=1)
        surf = pygame.image.frombuffer(side.tobytes(), (960, 200), "RGB")
        pygame.image.save(pygame.transform.scale(surf, (1920, 400)), str(args.png))


if __name__ == "__main__":
    main()
