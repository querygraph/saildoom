"""Check the level start on Sail (sql/level_start.sql) against a recorded run's tic 0.

  check_start.py --run reference/run-e1m1-b
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "reference"))
from saildoom import game  # noqa: E402
import check_tic as ct  # noqa: E402

FIELDS = tuple(f for f in ct.FIELDS if f != "level_tics") + (
    "health", "armor", "ammo_bullets", "ammo_shells", "ammo_rockets", "ammo_cells",
    "god_mode", "noclip", "key_red", "key_blue", "key_yellow")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=Path, default=ROOT / "reference/run-e1m1-b")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    args = ap.parse_args()
    spark = game.connect()
    run = game.load_run_for_tics(spark, args.data, args.run)
    got = game.level_start(spark, args.data, run, args.run)
    want = game.recorded(spark, run, 0, args.run)
    ct.FIELDS = FIELDS
    ct.check_player(got["P"], want["P"], [0])
    for kind, key in ct.KEYS.items():
        ct.check_table(kind, key, got[kind], want[kind], [0])


if __name__ == "__main__":
    main()
