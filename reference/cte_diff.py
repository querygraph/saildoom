"""Compare one renderer stage between CedarDB (the original) and Sail (the port).

Both renderers are one WITH query whose CTEs carry the same names. For a stage
name this runs `WITH ... SELECT * FROM <stage>` on each engine at the same pose
and compares the two results as multisets of rows, on the columns they share,
with floats rounded to --digits significant digits. It prints the row counts and
the first rows found on only one side.

  cte_diff.py --stage columns --stage plane_pixels ...
  cte_diff.py --all            every stage, in order, until the first difference
"""

import argparse
import collections
import json
import math
import re
import sys
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402
from saildoom.sqlmacro import expand, strip_comments  # noqa: E402


def stage_names(sql):
    return re.findall(r"(?:^|\),|WITH)\s*([a-z_0-9]+)\s+AS\s+\(", sql, re.M)


def cut(sql, stage):
    """The WITH query up to and including `stage`, selecting it."""
    sql = strip_comments(sql)
    m = re.search(r"(?:\),|WITH)\s*" + stage + r"\s+AS\s+\(", sql)
    if not m:
        raise KeyError(stage)
    depth, i = 1, m.end()
    while depth:
        if sql[i] == "(":
            depth += 1
        elif sql[i] == ")":
            depth -= 1
        i += 1
    return sql[:i] + f"\nSELECT * FROM {stage}"


def norm(v, digits):
    if isinstance(v, float):
        if math.isnan(v) or v == 0.0:
            return 0.0
        return float(f"{v:.{digits}g}")
    if isinstance(v, (bytes, memoryview)):
        return bytes(v).hex()
    if hasattr(v, "is_integer") and not isinstance(v, int):  # Decimal
        return norm(float(v), digits)
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--sqldoom", required=True, type=Path)
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--pose", required=True, help="poses.json entry: map:tic")
    ap.add_argument("--poses", type=Path,
                    default=ROOT / "reference/cedar-e1m1/poses.json")
    ap.add_argument("--stage", action="append", default=[])
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--digits", type=int, default=6)
    ap.add_argument("--show", type=int, default=8)
    args = ap.parse_args()

    meta = json.loads((args.poses.parent / "timings.json").read_text())
    map_name, tic = args.pose.split(":")
    pose = next(p["pose"] for p in json.loads(args.poses.read_text())
                if p["map"] == map_name and p["tic"] == int(tic))
    x, y, z, angle = pose
    params = dict(map_id=meta["map_id"], player=meta["player_thing_id"],
                  skill=meta["skill"], x=x, y=y, z=z, angle=angle)

    original = (args.sqldoom / "sql/renderer.sql").read_text()
    for i, name in enumerate(("map_id", "player", "skill", "x", "y", "z", "angle")):
        original = original.replace(f"${i + 1}", repr(params[name]))
    original = re.sub(r"(\d+(?:\.\d+)?(?:e-?\d+)?)::float8", r"\1::float8", original)
    port = (ROOT / "sql/renderer_v1.sql").read_text()

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    spark = engine.connect()
    engine.load_map(spark, args.data, meta["map_id"])

    stages = stage_names(strip_comments(port)) if args.all else args.stage
    for stage in stages:
        try:
            pg_sql = cut(original, stage)
        except KeyError:
            print(f"{stage}: port-only stage, skipped")
            continue
        cur.execute(pg_sql)
        pg_cols = [d.name for d in cur.description]
        pg_rows = cur.fetchall()
        sail_df = spark.sql(expand(cut(port, stage), params))
        sail_cols = sail_df.columns
        sail_rows = [tuple(r) for r in sail_df.collect()]
        shared = [c for c in pg_cols if c in sail_cols]
        pi = [pg_cols.index(c) for c in shared]
        si = [sail_cols.index(c) for c in shared]
        a = collections.Counter(tuple(norm(r[i], args.digits) for i in pi) for r in pg_rows)
        b = collections.Counter(tuple(norm(r[i], args.digits) for i in si) for r in sail_rows)
        only_pg, only_sail = a - b, b - a
        status = "same" if not only_pg and not only_sail else "DIFFERENT"
        dropped = sorted(set(pg_cols) ^ set(sail_cols))
        print(f"{stage}: cedar {len(pg_rows)} rows, sail {len(sail_rows)} rows,"
              f" {status} on {len(shared)} columns"
              + (f" (not compared: {dropped})" if dropped else ""))
        if status != "same":
            print("  columns:", shared)
            for row in list(only_pg.elements())[:args.show]:
                print("  cedar only:", row)
            for row in list(only_sail.elements())[:args.show]:
                print("  sail only: ", row)
            if args.all:
                break


if __name__ == "__main__":
    main()
