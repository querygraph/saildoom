"""TPC-DOOM driver: run the benchmark's tests against a system under test
through SQLDoom's own database API (doom_sql.py), and time every call.

  # CedarDB, SQLDoom's own database (the reference)
  TPCDOOM_DSN=postgresql://... driver.py --sut cedardb --out results/cedardb.json
  # Sail, through SailDoom's API backend
  SAIL_REMOTE=sc://localhost:50053 driver.py --sut sail --out results/sail.json
  # Exactness: compare two result files tic by tic and frame by frame
  driver.py compare results/cedardb.json results/sail.json

See tpc-doom/SPEC.md for what the tests are and what a report must disclose.
"""

import argparse
import hashlib
import json
import os
import platform
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "reference"))

TIC_RATE = 35  # Doom's game tics a second
SKILL = 2
SPEC_VERSION = "0.1"
COMMANDS_SHA256 = "593c517baf34ca5bc4549936fa6e6aae8ee7deaab9cb44e48c497936c6f7ed94"
WARMUP = 120  # tics of each test before the measurement interval


def connect(args):
    """A DB-API cursor on the system under test, and SQLDoom's doom_sql
    module, set up the way SQLDoom's client is."""
    sys.path.insert(0, str(args.sqldoom))
    if args.sut == "cedardb":
        import psycopg2
        dsn = os.environ.get("TPCDOOM_DSN") or os.environ.get("DB_DSN")
        if not dsn:
            sys.exit("set TPCDOOM_DSN to CedarDB's connection string")
        conn = psycopg2.connect(dsn)
        conn.autocommit = True
        import doom_sql
        return conn.cursor(), doom_sql
    from play import initial_store
    from saildoom import engine, pgshim
    from saildoom.backend import Backend, Store, install
    import shutil
    spark = engine.connect()
    store_dir = ROOT / "data/tpc-doom-store"
    shutil.rmtree(store_dir, ignore_errors=True)
    store = Store(spark, store_dir, initial_store(ROOT / "data/freedoom1", ROOT / "reference/trace-menus",
                                                  store_dir.parent / "tpc-doom-initial"))
    backend = Backend(spark, store)
    pgshim.install_module(backend)
    os.chdir(args.sqldoom)
    import doom_sql
    install(doom_sql, backend)
    import psycopg2  # the shim
    return psycopg2.connect("").cursor(), doom_sql


def digest(value):
    if isinstance(value, (bytes, bytearray, memoryview)):
        value = bytes(value)
        return f"sha256:{hashlib.sha256(value).hexdigest()}:{len(value)}"
    return value


def plain(rows):
    """A snapshot's rows as JSON values (doubles kept, compared with a
    tolerance by `compare`)."""
    from decimal import Decimal
    if rows is None:
        return None
    if not isinstance(rows, (list, tuple)):
        rows = [rows]
    out = []
    for r in rows:
        r = r if isinstance(r, (list, tuple)) else [r]
        out.append([float(v) if isinstance(v, Decimal) else digest(v) if isinstance(v, (bytes, bytearray, memoryview))
                    else v if isinstance(v, (int, float, str, bool, type(None))) else repr(v) for v in r])
    return out


class Session:
    def __init__(self, cur, sql, commands):
        self.cur, self.sql, self.commands = cur, sql, commands
        stages = {s["label"]: s for s in sql.load_stages(cur)}
        self.map_id = stages["E1M1"]["map_id"]
        self.player = stages["E1M1"]["player_thing_id"]
        self.event = 0

    def start_level(self):
        """Level start, as the client starts a new game on E1M1 at skill 2,
        then the recorded run's cheats (god mode, every weapon) before tic 1."""
        self.sql.set_screen(self.cur, "game")
        self.sql.enter_level(self.cur, self.map_id, self.player, SKILL)
        for code in ("IDDQD", "IDKFA"):
            self.sql.cheat_code(self.cur, self.map_id, self.player, code)
        self.event = 0

    def tic(self, i):
        """One game tic, as SQLDoom's client runs it (doom_client.run_game_tic):
        the tic, the sound events if it made any, the snapshot."""
        command = (SKILL, *self.commands[i % len(self.commands)][1:])
        sound_due = self.sql.execute_game_tic(self.cur, self.map_id, self.player, command)
        if sound_due:
            events, _ = self.sql.fetch_sound_events(self.cur, self.map_id, self.player, self.event)
            if events:
                self.event = max(e[0] for e in events)
        return self.sql.finish_game_tic(self.cur, self.map_id, self.player)

    def frame(self):
        """One frame, as the client asks for one between tics: the camera pose
        at the tic just run, then the frame from that pose (320x200 RGB)."""
        pose = self.sql.camera_pose(self.cur, self.map_id, self.player, 1.0)
        return self.sql.render_frame(self.cur, self.map_id, self.player, SKILL, tuple(pose), 320, 200, 1.0)


def summary(seconds):
    ms = [1000 * s for s in seconds]
    if not ms:
        return {}
    ordered = sorted(ms)
    return {"n": len(ms), "mean_ms": round(statistics.fmean(ms), 2), "p50_ms": round(ordered[len(ms) // 2], 2),
            "p95_ms": round(ordered[int(0.95 * (len(ms) - 1))], 2), "max_ms": round(ordered[-1], 2)}


def warmup(seconds):
    head = seconds[:WARMUP]
    return {"tics": len(head), "elapsed_s": round(sum(head), 3), "first_s": round(head[0], 3),
            "max_s": round(max(head), 3), "max_at_tic": 1 + head.index(max(head))}


def run(args):
    commands = [c["command"] for c in json.loads(args.commands.read_text())][:args.tics]
    if args.tics == 1200 and hashlib.sha256(args.commands.read_bytes()).hexdigest() != COMMANDS_SHA256:
        sys.exit(f"{args.commands} is not the benchmark's command stream")
    started = time.perf_counter()
    cur, sql = connect(args)
    sql.prepare_client(cur)
    session = Session(cur, sql, commands)
    result = {"spec": SPEC_VERSION, "sut": args.sut, "commands": args.commands.name, "tics": len(commands),
              "host": {"machine": platform.machine(), "system": platform.platform(),
                       "python": platform.python_version()},
              "connect_s": round(time.perf_counter() - started, 3),
              "load_average_before": [round(x, 1) for x in os.getloadavg()]}

    # Test 1: tics. The level starts, then every tic of the run back to back.
    t = time.perf_counter()
    session.start_level()
    result["level_start_s"] = round(time.perf_counter() - t, 3)
    times, snapshots = [], []
    for i in range(len(commands)):
        t = time.perf_counter()
        snapshot = session.tic(i)
        times.append(time.perf_counter() - t)
        snapshots.append(plain(snapshot))
    measured = times[WARMUP:]
    result["tic_test"] = {"warmup": warmup(times), "elapsed_s": round(sum(measured), 3),
                          "tics_per_s": round(len(measured) / sum(measured), 2), "tic": summary(measured)}
    result["tic_test"]["per_tic_ms"] = [round(1000 * t, 3) for t in times]
    result["snapshots"] = snapshots

    # Test 2: real time. The level starts again, then every tic is followed by
    # a frame, as Doom draws one per tic.
    session.start_level()
    t = time.perf_counter()
    # The level's first frame, timed on its own: the renderer prepared for the
    # level, as SQLDoom's render worker does, then a frame.
    sql.prepare_renderer(cur, session.map_id, session.player, SKILL)
    session.frame()
    result["first_frame_s"] = round(time.perf_counter() - t, 3)
    session.start_level()
    tic_times, frame_times, frames = [], [], []
    for i in range(len(commands)):
        t = time.perf_counter()
        session.tic(i)
        t1 = time.perf_counter()
        frame = session.frame()
        frame_times.append(time.perf_counter() - t1)
        tic_times.append(t1 - t)
        frames.append(digest(frame))
    pairs = [a + b for a, b in zip(tic_times, frame_times)]
    measured = pairs[WARMUP:]
    rate = len(measured) / sum(measured)
    result["realtime_test"] = {"warmup": warmup(pairs), "elapsed_s": round(sum(measured), 3),
                               "tpsD": round(rate, 2), "realtime_factor": round(rate / TIC_RATE, 3),
                               "tic": summary(tic_times[WARMUP:]), "frame": summary(frame_times[WARMUP:]),
                               "per_tic_ms": [round(1000 * t, 3) for t in tic_times],
                               "per_frame_ms": [round(1000 * t, 3) for t in frame_times]}
    result["frames"] = frames
    result["load_average_after"] = [round(x, 1) for x in os.getloadavg()]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=1))
    print(json.dumps({k: v for k, v in result.items() if k not in ("snapshots", "frames")},
                     default=str, indent=1)[:4000])


def close(a, b):
    if isinstance(a, float) or isinstance(b, float):
        try:
            return a == b or abs(float(a) - float(b)) <= 1e-9 * max(1.0, abs(float(a)), abs(float(b)))
        except (TypeError, ValueError):
            return False
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(close(x, y) for x, y in zip(a, b))
    return a == b


def compare(args):
    a, b = (json.loads(p.read_text()) for p in (args.a, args.b))
    exact = sum(x == y for x, y in zip(a["snapshots"], b["snapshots"]))
    near = sum(close(x, y) for x, y in zip(a["snapshots"], b["snapshots"]))
    frames = sum(x == y for x, y in zip(a["frames"], b["frames"]))
    n = min(len(a["snapshots"]), len(b["snapshots"]))
    print(f"tic snapshots: {exact} of {n} identical, {near} within 1e-9 (relative)")
    print(f"frames: {frames} of {min(len(a['frames']), len(b['frames']))} byte-identical")
    first = next((i for i, (x, y) in enumerate(zip(a["snapshots"], b["snapshots"])) if not close(x, y)), None)
    if first is not None:
        print(f"first differing tic: {first + 1}\n  {args.a.name}: {a['snapshots'][first]}\n"
              f"  {args.b.name}: {b['snapshots'][first]}")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "compare":
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd")
        ap.add_argument("a", type=Path)
        ap.add_argument("b", type=Path)
        compare(ap.parse_args())
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--sut", choices=("cedardb", "sail"), required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--commands", type=Path, default=ROOT / "tpc-doom/inputs/run-e1m1-b-commands.json")
    ap.add_argument("--tics", type=int, default=1200, help="fewer only for trying the driver out")
    ap.add_argument("--sqldoom", type=Path, default=Path(os.environ.get("SAILDOOM_SQLDOOM", ROOT.parent / "saildoom-ref/sqldoom")))
    args = ap.parse_args()
    args.out, args.commands, args.sqldoom = args.out.resolve(), args.commands.resolve(), args.sqldoom.resolve()
    run(args)


if __name__ == "__main__":
    main()
