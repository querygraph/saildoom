"""Render SQLDoom's full-screen pages on CedarDB and on Sail from the same
screen_state, and compare the frames byte for byte.

  check_screens.py --dsn ... [--sqldoom ../saildoom-ref/sqldoom]

CedarDB's screen_state row is put back afterwards.
"""

import argparse
import hashlib
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from saildoom import engine  # noqa: E402
from saildoom.backend import Backend, fresh_store, literal  # noqa: E402
from saildoom.api import screen_render  # noqa: E402

CASES = [
    dict(screen="intermission", inter_episode=4, inter_level=1, inter_next=2),
    dict(screen="title"),
    *[dict(screen="main", cursor_index=i) for i in range(6)],
    dict(screen="episode", cursor_index=2), dict(screen="skill", cursor_index=4),
    dict(screen="load", cursor_index=0), dict(screen="save", cursor_index=3),
    dict(screen="help1"), dict(screen="help2"),
    dict(screen="intermission", inter_episode=1, inter_level=3, inter_next=4, kills_pct=57,
         items_pct=100, secrets_pct=0, time_secs=83, par_secs=90),
    dict(screen="intermission", inter_episode=2, inter_level=9, inter_next=1, kills_pct=3,
         items_pct=12, secrets_pct=133, time_secs=3725, par_secs=0),
    dict(screen="intermission", inter_episode=4, inter_level=1, inter_next=2),
    *[dict(screen="finale", finale_episode=e, finale_stage=0, finale_count=c)
      for e in (1, 2, 4) for c in (5, 400, 2000)],
    *[dict(screen="finale", finale_episode=e, finale_stage=1, finale_count=0) for e in (1, 2, 4)],
    *[dict(screen="finale", finale_episode=3, finale_stage=1, finale_count=c)
      for c in (0, 500, 1135, 1200, 1300)],
]
TICS = (0, 8)


def main():
    import psycopg2
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--sqldoom", type=Path, default=ROOT.parent / "saildoom-ref/sqldoom")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    args = ap.parse_args()
    body = (args.sqldoom / "sql/client/render_screen.sql").read_text()
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT * FROM screen_state WHERE id = 0")
    columns = [d[0] for d in cur.description]
    original = dict(zip(columns, cur.fetchone()))
    cur.execute("SELECT * FROM save_slots")
    slots = cur.fetchall()
    cur.execute("PREPARE screen_check(int) AS " + body)

    spark = engine.connect()
    store = fresh_store(spark, ROOT / "data/screens-store", args.data)
    b = Backend(spark, store)
    screen_render.register(b)
    if slots:
        import pyarrow as pa
        schema = store.arrow_schema("save_slots")
        cur.execute("SELECT * FROM save_slots LIMIT 0")
        names = [d[0] for d in cur.description]
        store.write_arrow("save_slots", pa.Table.from_pylist(
            [{n: v for n, v in zip(names, r) if n in schema.names} for r in slots], schema))
    bad = 0
    try:
        for case in CASES:
            row = dict(original, **case)
            keys = [k for k in columns if k != "id"]
            cur.execute(f"UPDATE screen_state SET {', '.join(f'{k} = %s' for k in keys)} WHERE id = 0",
                        [row[k] for k in keys])
            b.update("screen_state", {k: literal(v) for k, v in row.items() if k != "id"}, "t.id = 0")
            for t in TICS:
                cur.execute("EXECUTE screen_check(%s)", (t,))
                want = bytes(cur.fetchone()[0])
                got = b.call("doom_render_screen", (t,))[0][0]
                same = got == want
                if not same:
                    bad += 1
                    a = np.frombuffer(got, np.uint8).reshape(200, 320, 3)
                    w = np.frombuffer(want, np.uint8).reshape(200, 320, 3)
                    ys, xs = np.nonzero((a != w).any(axis=2))
                    print(f"{case} tics={t}: {len(xs)} pixels differ, first "
                          f"{[(int(x), int(y), a[y, x].tolist(), w[y, x].tolist()) for x, y in zip(xs[:3], ys[:3])]}")
                else:
                    print(f"{case} tics={t}: same ({hashlib.sha256(want).hexdigest()[:12]})")
    finally:
        sets = ", ".join(f"{k} = %s" for k in columns if k != "id")
        cur.execute(f"UPDATE screen_state SET {sets} WHERE id = 0", [original[k] for k in columns if k != "id"])
    print(f"{len(CASES) * len(TICS)} frames, {bad} differ")


if __name__ == "__main__":
    main()
