"""Time each renderer stage on Sail: count(*) over the query cut at that CTE.

Each cut computes the stage and everything it depends on, so the time is
cumulative along the stage's own inputs; a jump from one stage to the next
points at the expensive work.
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402
from saildoom.sqlmacro import expand, strip_comments  # noqa: E402


def stage_names(sql):
    return re.findall(r"(?:^|\),|WITH)\s*([a-z_0-9]+)\s+AS\s+\(", sql, re.M)


def cut(sql, stage):
    m = re.search(r"(?:\),|WITH)\s*" + stage + r"\s+AS\s+\(", sql)
    depth, i = 1, m.end()
    while depth:
        depth += {"(": 1, ")": -1}.get(sql[i], 0)
        i += 1
    return sql[:i] + f"\nSELECT count(*) FROM {stage}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--ref", type=Path, default=ROOT / "reference/cedar-e1m1")
    ap.add_argument("--pose", default="E1M1:350")
    ap.add_argument("--sql", type=Path, default=ROOT / "sql/renderer.sql")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--min-ms", type=float, default=0.0)
    args = ap.parse_args()
    meta = json.loads((args.ref / "timings.json").read_text())
    map_name, tic = args.pose.split(":")
    x, y, z, angle = next(p["pose"] for p in json.loads((args.ref / "poses.json").read_text())
                          if p["map"] == map_name and p["tic"] == int(tic))
    params = dict(map_id=meta["map_id"], player=meta["player_thing_id"],
                  skill=meta["skill"], x=x, y=y, z=z, angle=angle)
    spark = engine.connect()
    engine.load_map(spark, args.data, meta["map_id"])
    params = engine.frame_params(meta["map_id"], meta["player_thing_id"], meta["skill"],
                                 (x, y, z, angle), engine.map_meta(args.data, meta["map_id"]))
    sql = strip_comments(args.sql.read_text())
    for stage in args.only or stage_names(sql):
        q = expand(cut(sql, stage), params)
        try:
            spark.sql(q).collect()  # warm
        except Exception as e:
            print(f"   FAILED            {stage}: {str(e).splitlines()[0][:300]}", flush=True)
            continue
        t = time.perf_counter()
        n = spark.sql(q).collect()[0][0]
        ms = (time.perf_counter() - t) * 1000
        if ms >= args.min_ms:
            print(f"{ms:9.1f} ms  {n:8d} rows  {stage}", flush=True)


if __name__ == "__main__":
    main()
