"""Replay a trace recorded on CedarDB (reference/trace_api.py) against the Sail
backend (saildoom/backend.py), and compare call by call: the rows each
statement returns, and every table that changed on either side.

  check_api.py --trace reference/trace-menus

Stops at the first call that differs (--keep-going to list them all).
"""

import argparse
import json
import re
import sys
from decimal import Decimal
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402
from saildoom.backend import Backend, fresh_store  # noqa: E402


def norm(v):
    """One value as both engines return it: a Decimal is the number it is."""
    if isinstance(v, str):
        m = re.fullmatch(r"Decimal\('([^']*)'\)", v)
        if m:
            return repr(float(Decimal(m.group(1))))
        return v
    if isinstance(v, Decimal):
        return repr(float(v))
    if isinstance(v, float) and v == int(v) and abs(v) < 2**53:
        return repr(float(v))
    return repr(v)


# Wall-clock columns: when a demo was recorded, a save made, a player last seen.
CLOCK_COLUMNS = {"recorded_at", "saved_at", "claimed_at", "last_seen", "created_at", "updated_at"}


def rows_of(table, maps=None, keyed=False):
    table = table.drop_columns([c for c in table.column_names if c in CLOCK_COLUMNS])
    if keyed:
        table = table.filter(pc.is_in(table["map_id"], pa.array(maps or [-1], pa.int32())))
    return sorted(tuple(norm(v) for v in r.values()) for r in table.to_pylist())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", type=Path, required=True)
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    ap.add_argument("--store", type=Path, default=ROOT / "data/api-store")
    ap.add_argument("--keep-going", action="store_true")
    args = ap.parse_args()

    calls = json.loads((args.trace / "calls.json").read_text())
    meta = json.loads((args.trace / "trace.json").read_text()) if (args.trace / "trace.json").exists() else {}
    maps = meta.get("maps", [])
    initial = args.store.parent / (args.store.name + "-initial")
    initial.mkdir(parents=True, exist_ok=True)
    for p in initial.glob("*.parquet"):
        p.unlink()
    for p in args.data.glob("*.parquet"):
        (initial / p.name).symlink_to(p.resolve())
    for p in (args.trace / "initial").glob("*.parquet"):
        (initial / p.name).unlink(missing_ok=True)
        (initial / p.name).symlink_to(p.resolve())

    spark = engine.connect()
    store = fresh_store(spark, args.store, initial)
    backend = Backend(spark, store)
    keyed = {t for t in store.tables() if "map_id" in store.arrow_schema(t).names}
    snapshots = {}
    for p in sorted((args.trace / "initial").glob("*.parquet")):
        snapshots[p.stem] = rows_of(pq.read_table(p), maps, p.stem in keyed)

    bad = 0
    for c in calls:
        params = [eval(p) for p in c["params"]]  # noqa: S307 -- our own trace
        before = dict(store.paths)
        if c["name"].startswith("SQL "):
            got_rows = backend.call_raw(c["name"][4:], params)
        else:
            got_rows = backend.call(c["name"], params)
        got = [tuple(norm(v) for v in r) for r in got_rows]
        want = [tuple(norm(eval(v)) for v in r) for r in c["rows"]]  # noqa: S307
        problems = []
        if got != want:
            problems.append(f"rows: sail {got[:3]} cedar {want[:3]}")
        written = {t for t in store.paths if store.paths[t] != before.get(t)}
        for t in sorted(set(c["changed"]) | written):
            if t in c["changed"]:
                snapshots[t] = rows_of(pq.read_table(args.trace / f"{c['n']:05d}-{t}.parquet"), maps, t in keyed)
            mine = rows_of(store.arrow(t), maps, t in keyed)
            if mine != snapshots.get(t):
                extra = [r for r in mine if r not in snapshots.get(t, [])][:2]
                missing = [r for r in snapshots.get(t, []) if r not in mine][:2]
                problems.append(f"{t}: sail has {extra}, cedar has {missing}")
        if problems:
            bad += 1
            print(f"call {c['n']} {c['name']}{tuple(params)}:")
            for p in problems:
                print("   ", p[:600])
            if not args.keep_going:
                break
    print(f"{len(calls)} calls, {bad} differ" if args.keep_going or not bad else "stopped at the first difference")


if __name__ == "__main__":
    main()
