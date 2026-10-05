"""Record a gameplay run of SQLDoom on CedarDB: per-tic world state, poses, frames.

The run is driven by a small bot so that it moves through the level: it walks
forward, turns when it stops making progress, presses use now and then (doors,
switches) and fires at intervals. After every tic it snapshots the tables the
renderer reads, with a `tic` column, and renders CedarDB's frame at the tic's
camera pose. The snapshots let Sail render exactly the frames CedarDB rendered,
and the frames are the pixel reference.

  record_run.py --sqldoom ../sqldoom --dsn ... --out reference/run-e1m1 --tics 700
"""

import argparse
import os
import json
import math
import sys
import time
from pathlib import Path

import psycopg2
import pyarrow as pa
import pyarrow.parquet as pq

STATE_TABLES = (
    "render_segs", "render_things", "sectors", "things", "player_state",
    "player_weapons", "player_weapon_owned", "monster_ai", "thing_health",
    "world_effects", "monster_projectiles", "picked_up_items",
    "sector_light_fx", "mp_players",
)

OID_TYPES = {
    16: pa.bool_(), 17: pa.binary(), 18: pa.string(), 19: pa.string(),
    20: pa.int64(), 21: pa.int32(), 23: pa.int32(), 25: pa.string(),
    700: pa.float32(), 701: pa.float64(), 1042: pa.string(),
    1043: pa.string(), 1700: pa.float64(),
    1114: pa.timestamp("us"), 1184: pa.timestamp("us", tz="UTC"),
}


class Snapshots:
    """Per-table column buffers with a leading tic column."""

    def __init__(self):
        self.schemas, self.columns = {}, {}

    def add(self, cur, table, map_id, tic):
        cur.execute(f'SELECT * FROM "{table}" WHERE map_id = %s', (map_id,))
        rows = cur.fetchall()
        if table not in self.schemas:
            fields = [pa.field("tic", pa.int32())]
            for d in cur.description:
                fields.append(pa.field(d.name, OID_TYPES.get(d.type_code, pa.string())))
            self.schemas[table] = pa.schema(fields)
            self.columns[table] = [[] for _ in fields]
        cols = self.columns[table]
        types = [f.type for f in self.schemas[table]]
        for r in rows:
            cols[0].append(tic)
            for i, v in enumerate(r, start=1):
                if v is not None and types[i] == pa.string():
                    v = str(v)
                elif v is not None and types[i] == pa.float64() and not isinstance(v, float):
                    v = float(v)
                elif v is not None and types[i] == pa.binary():
                    v = bytes(v)
                cols[i].append(v)

    def write(self, out):
        for table, schema in self.schemas.items():
            arrays = [pa.array(c, type=f.type) for c, f in zip(self.columns[table], schema)]
            pq.write_table(pa.Table.from_arrays(arrays, schema=schema),
                           out / f"{table}.parquet")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sqldoom", required=True, type=Path)
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--tics", type=int, default=700)
    ap.add_argument("--data", type=Path, default=Path(__file__).resolve().parents[1] / "data/freedoom1")
    args = ap.parse_args()
    sys.path.insert(0, str(args.sqldoom))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import doom_sql as sql  # noqa: E402

    out = args.out
    (out / "frames").mkdir(parents=True, exist_ok=True)
    (out / "state").mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    stage = {s["label"]: s for s in sql.load_stages(cur)}[args.map]
    map_id, player = stage["map_id"], stage["player_thing_id"]
    sql.enter_level(cur, map_id, player, args.skill)
    sql.prepare_renderer(cur, map_id, player, args.skill)
    # The bot plays with god mode and every weapon (shotgun selected below);
    # it still walks with clipping on.
    for code in ("IDDQD", "IDKFA"):
        sql.cheat_code(cur, map_id, player, code)

    from bot import Bot
    snaps = Snapshots()
    poses = []
    bot = Bot(args.data, map_id)
    started = time.perf_counter()
    for tic in range(0, args.tics + 1):
        if tic > 0:
            cur.execute(
                "SELECT t.x, t.y FROM things t JOIN thing_health h"
                " ON h.map_id = t.map_id AND h.thing_id = t.id"
                " WHERE t.map_id = %s AND h.alive AND t.id <> %s", (map_id, player))
            monsters = cur.fetchall()
            cur.execute("SELECT sector_id FROM player_state WHERE map_id = %s AND player_thing_id = %s",
                        (map_id, player))
            command = list(bot.command(tic, args.skill, monsters, cur.fetchone()[0]))
            if tic == 2:
                command[6] = 3   # the shotgun
            command = tuple(command)
            sql.execute_game_tic(cur, map_id, player, command)
            snap = sql.finish_game_tic(cur, map_id, player)
            bot.observe(snap)
        else:
            bot.observe({"x": pose_x(cur, map_id, player)[0], "y": pose_x(cur, map_id, player)[1],
                         "angle": pose_x(cur, map_id, player)[2]})
        pose = sql.camera_pose(cur, map_id, player, 1.0)
        for table in STATE_TABLES:
            snaps.add(cur, table, map_id, tic)
        sql.execute_prepared(cur, sql.RENDER_FOLDED_STATEMENT, pose)
        (out / "frames" / f"{tic:05d}.rgb").write_bytes(bytes(cur.fetchone()[0]))
        poses.append({"tic": tic, "pose": [float(v) for v in pose]})
        if tic % 50 == 0:
            print(f"tic {tic} pose {tuple(round(v, 1) for v in pose)} "
                  f"{time.perf_counter() - started:.0f} s", flush=True)
    snaps.write(out / "state")
    (out / "poses.json").write_text(json.dumps(poses))
    (out / "run.json").write_text(json.dumps({
        "map": args.map, "map_id": map_id, "player_thing_id": player,
        "skill": args.skill, "tics": args.tics}))


def pose_x(cur, map_id, player):
    cur.execute("SELECT x, y, angle FROM things WHERE map_id = %s AND id = %s", (map_id, player))
    return tuple(float(v) for v in cur.fetchone())


if __name__ == "__main__":
    main()
