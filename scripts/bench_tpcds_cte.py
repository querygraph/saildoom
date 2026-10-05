"""TPC-DS queries that reuse a CTE, on two Sail servers: times and result checks.

  bench_tpcds_cte.py --data ~/src/saildoom-ref/tpcds-sf1 \
      --queries ~/src/sail-recursive/python/pysail/data/tpcds/queries \
      --a sc://localhost:50051 --b sc://localhost:50053
"""

import argparse
import hashlib
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402

REUSING = [1, 2, 4, 11, 14, 23, 24, 30, 31, 39, 47, 57, 58, 59, 64, 74, 75, 77, 81, 83, 95, 97]
CONTROLS = [3, 7, 42, 52]  # no CTE reuse: should not change


def session(url, data):
    s = engine.connect(url)
    for p in sorted(Path(data).glob("*.parquet")):
        s.read.parquet(str(p)).createOrReplaceTempView(p.stem)
    return s


def run(s, sql, n):
    rows = s.sql(sql).collect()  # warm
    times = []
    for _ in range(n):
        t = time.perf_counter()
        rows = s.sql(sql).collect()
        times.append(time.perf_counter() - t)
    digest = hashlib.sha256("\n".join(sorted(repr(tuple(r)) for r in rows)).encode()).hexdigest()[:12]
    return statistics.median(times) * 1000, len(rows), digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, required=True)
    ap.add_argument("--queries", type=Path, required=True)
    ap.add_argument("--a", default="sc://localhost:50051")
    ap.add_argument("--b", default="sc://localhost:50053")
    ap.add_argument("--repeat", type=int, default=3)
    args = ap.parse_args()
    a, b = session(args.a, args.data), session(args.b, args.data)
    print(f"{'query':8s} {'A ms':>9s} {'B ms':>9s} {'B/A':>6s}  result")
    totals = {"reusing": [0.0, 0.0], "controls": [0.0, 0.0]}
    for group, numbers in (("reusing", REUSING), ("controls", CONTROLS)):
        for q in numbers:
            sql = (args.queries / f"q{q}.sql").read_text()
            # Some queries hold several statements; run the last one.
            sql = [part for part in sql.split(";") if part.strip()][-1]
            try:
                ta, na, da = run(a, sql, args.repeat)
                tb, nb, db = run(b, sql, args.repeat)
            except Exception as e:  # report and go on
                print(f"q{q:<7d} ERROR {str(e).splitlines()[0][:150]}")
                continue
            same = "same" if (na, da) == (nb, db) else f"DIFFERENT ({na} vs {nb} rows)"
            totals[group][0] += ta
            totals[group][1] += tb
            print(f"q{q:<7d} {ta:9.0f} {tb:9.0f} {tb / ta:6.2f}  {same}", flush=True)
    for group, (ta, tb) in totals.items():
        if ta:
            print(f"total {group}: A {ta:.0f} ms, B {tb:.0f} ms, B/A {tb / ta:.2f}")


if __name__ == "__main__":
    main()
