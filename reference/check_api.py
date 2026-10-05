"""Replay a trace recorded on CedarDB (reference/trace_api.py) against the Sail
backend (saildoom/backend.py), and compare call by call: the rows each
statement returns, and every table that changed on either side.

  check_api.py --trace reference/trace-menus

Stops at the first call that differs (--keep-going to list them all).
"""

import argparse
import hashlib
import json
import re
import sys
from decimal import Decimal
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine  # noqa: E402
from saildoom.backend import Backend, fresh_store  # noqa: E402


def norm(v):
    """One value as both engines return it: a Decimal is the number it is, a
    bytea its digest (as reference/trace_api.py records it)."""
    if isinstance(v, (bytes, bytearray, memoryview)):
        v = bytes(v)
        return f"sha256:{hashlib.sha256(v).hexdigest()}:{len(v)}"
    if isinstance(v, str):
        m = re.fullmatch(r"Decimal\('([^']*)'\)", v)
        if m:
            return repr(float(Decimal(m.group(1))))
        return v
    if isinstance(v, Decimal):
        return repr(float(v))
    if isinstance(v, float):
        if v == v and abs(v) < 2**53 and v == int(v):
            return repr(float(v))
        # A real value: CedarDB sends its shortest text, Sail its exact float32
        # value as a double; both are that float32.
        v32 = np.float32(v)
        short = str(v32)
        if float(v32) == v or (np.isfinite(v32) and float(short) == v):
            return short
    return repr(v)


# Wall-clock columns: when a demo was recorded, a save made, a player last seen.
CLOCK_COLUMNS = {"recorded_at", "saved_at", "claimed_at", "last_seen", "created_at", "updated_at"}


def close_rows(a, b):
    """Rows equal but for doubles within 1e-12: the last bits of a libm
    function (pow, atan2, sin), where Apple's libm and glibc differ, and what
    a subtraction after one makes of them."""
    if len(a) != len(b):
        return False
    for ra, rb in zip(a, b):
        if len(ra) != len(rb):
            return False
        for x, y in zip(ra, rb):
            x = float(x) if isinstance(x, Decimal) else x
            y = float(y) if isinstance(y, Decimal) else y
            if isinstance(x, float) and isinstance(y, float):
                if x != y and abs(x - y) > 1e-12 * max(1.0, abs(x), abs(y)):
                    return False
            elif norm(x) != norm(y):
                return False
    return True


def same_events(a, b):
    """sound_events alike but for event_id. The sequence gives a tic as many
    values on both engines, but which attempted row takes which follows each
    engine's plan, and a row ON CONFLICT drops takes one too."""
    return sorted(r[1:] for r in a) == sorted(r[1:] for r in b)


# The events newer than a client's cursor: the cursor is a CedarDB event_id,
# so the rows are not comparable (see same_events); the events themselves are
# compared in the sound_events table.
EVENT_ID_ROWS = set()
UNCOMPARED_ROWS = {"doom_sound_events"}


def frame_diff(trace, n, got_rows):
    """Where a 320x200 RGB frame differs from the one the trace stored."""
    out = []
    for f in sorted((trace / "bytes").glob(f"{n:05d}-*.bin")):
        want = np.frombuffer(f.read_bytes(), np.uint8)
        for r in got_rows:
            for v in r:
                if isinstance(v, (bytes, bytearray)) and len(v) == len(want) == 320 * 200 * 3:
                    a = np.frombuffer(bytes(v), np.uint8).reshape(200, 320, 3)
                    b = want.reshape(200, 320, 3)
                    ys, xs = np.nonzero((a != b).any(axis=2))
                    out.append(f"frame: {len(xs)} pixels differ, first "
                               f"{[(int(x), int(y), a[y, x].tolist(), b[y, x].tolist()) for x, y in zip(xs[:4], ys[:4])]}")
    return out


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

    bad = libm = unrecorded = 0
    for c in calls:
        params = [eval(p) for p in c["params"]]  # noqa: S307 -- our own trace
        before = dict(store.paths)
        if c["name"].startswith("SQL "):
            got_rows = backend.call_raw(c["name"][4:], params)
        else:
            got_rows = backend.call(c["name"], params)
        got = [tuple(norm(v) for v in r) for r in got_rows]
        if any(v.startswith("<memory at") for r in c["rows"] for v in r):
            # An older trace recorded a bytea as the memoryview's repr.
            unrecorded += 1
            c = {**c, "rows": [[repr(norm(v)) for v in r] for r in got_rows]}
        want = [tuple(norm(eval(v)) for v in r) for r in c["rows"]]  # noqa: S307
        problems = []
        if c["name"] in EVENT_ID_ROWS:
            got = [r[1:] for r in got]
            want = [r[1:] for r in want]
            got_rows = [tuple(r)[1:] for r in got_rows]
        if c["name"] in UNCOMPARED_ROWS:
            got = want
        if got != want:
            cedar_rows = [[eval(v) for v in r] for r in c["rows"]]  # noqa: S307
            if c["name"] in EVENT_ID_ROWS:
                cedar_rows = [r[1:] for r in cedar_rows]
            if close_rows(got_rows, cedar_rows):
                libm += 1
            else:
                problems.append(f"rows: sail {got[:3]} cedar {want[:3]}")
                problems += frame_diff(args.trace, c["n"], got_rows)
        written = {t for t in store.paths if store.paths[t] != before.get(t) and not t.startswith("_")}
        for t in sorted(set(c["changed"]) | written):
            if t in c["changed"]:
                snapshots[t] = rows_of(pq.read_table(args.trace / f"{c['n']:05d}-{t}.parquet"), maps, t in keyed)
            mine = rows_of(store.arrow(t), maps, t in keyed)
            if t == "sound_events" and same_events(mine, snapshots.get(t, [])):
                continue
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
    if unrecorded:
        print(f"{unrecorded} calls returned a bytea the trace did not record")
    print(f"{len(calls)} calls, {bad} differ; {libm} returned doubles a few ulps apart (libm)"
          if args.keep_going or not bad else "stopped at the first difference")


if __name__ == "__main__":
    main()
