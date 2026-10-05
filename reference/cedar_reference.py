"""Record reference frames and tics from SQLDoom running on CedarDB.

CedarDB is the oracle: the port to Sail must produce the same framebuffer for
the same pose, and the same world after the same inputs. This script drives
the unmodified SQLDoom (a checkout given by --sqldoom) exactly as its client
does, and writes what it saw under --out:

  frames/<map>_<n>.rgb   320x200x3 raw framebuffers, with poses.json
  tics.jsonl             one player snapshot per tic of a scripted run
  timings.json           warm render and tic latencies on CedarDB
"""

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import psycopg2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sqldoom", required=True, type=Path)
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--tics", type=int, default=350)
    ap.add_argument("--renders", type=int, default=30)
    args = ap.parse_args()

    sys.path.insert(0, str(args.sqldoom))
    import doom_sql as sql  # noqa: E402  (the checkout's own module)

    out = args.out
    (out / "frames").mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)

    stages = {s["label"]: s for s in sql.load_stages(cur)}
    stage = stages[args.map]
    map_id, player = stage["map_id"], stage["player_thing_id"]
    x, y, angle, z = sql.enter_level(cur, map_id, player, args.skill)
    sql.prepare_renderer(cur, map_id, player, args.skill)

    def render(pose):
        px, py, pz, pa = pose
        sql.execute_prepared(cur, sql.RENDER_FOLDED_STATEMENT, (px, py, pz, pa))
        return bytes(cur.fetchone()[0])

    poses = []
    timings = {"map": args.map, "map_id": map_id, "player_thing_id": player,
               "skill": args.skill}

    spawn = (x, y, z, angle)
    for _ in range(3):
        render(spawn)
    samples = []
    for _ in range(args.renders):
        t0 = time.perf_counter()
        frame = render(spawn)
        samples.append((time.perf_counter() - t0) * 1000)
    timings["render_ms"] = summary(samples)
    save(out, args.map, 0, frame, spawn, poses)

    # A scripted run: walk forward, turn, strafe, fire, use. Every tic's
    # snapshot is recorded; a frame every 35 tics.
    tic_ms = []
    with open(out / "tics.jsonl", "w") as log:
        for n in range(1, args.tics + 1):
            command = scripted_command(n, args.skill)
            t0 = time.perf_counter()
            sql.execute_game_tic(cur, map_id, player, command)
            snap = sql.finish_game_tic(cur, map_id, player)
            tic_ms.append((time.perf_counter() - t0) * 1000)
            log.write(json.dumps({"tic": n, "command": command, **snap}) + "\n")
            if n % 35 == 0:
                pose = sql.camera_pose(cur, map_id, player, 1.0)
                save(out, args.map, n, render(pose), pose, poses)
    timings["tic_ms"] = summary(tic_ms)
    (out / "poses.json").write_text(json.dumps(poses, indent=1))
    (out / "timings.json").write_text(json.dumps(timings, indent=1))
    print(json.dumps(timings, indent=1))


def scripted_command(n, skill):
    """(skill, fwd, strafe, run, turn, attack, weapon, use) for tic n."""
    fwd = strafe = turn = 0.0
    run = attack = use = False
    if n <= 70:
        fwd = 1.0
    elif n <= 105:
        turn = 3.0
    elif n <= 175:
        fwd, run = 1.0, True
    elif n <= 210:
        strafe = 1.0
    elif n <= 245:
        attack = True
    elif n <= 280:
        turn = -3.0
    else:
        fwd = 1.0
        use = n % 10 == 0
    return (skill, fwd, strafe, run, turn, attack, None, use)


def save(out, map_name, n, frame, pose, poses):
    (out / "frames" / f"{map_name}_{n:04d}.rgb").write_bytes(frame)
    poses.append({"map": map_name, "tic": n, "pose": list(map(float, pose))})


def summary(samples):
    s = sorted(samples)
    return {"n": len(s), "median": statistics.median(s),
            "p90": s[int(0.9 * (len(s) - 1))], "min": s[0], "max": s[-1]}


if __name__ == "__main__":
    main()
