"""The game tic and the statements the client runs around it: 40_run_game_tic's
doom_run_game_tic (08_cs_begin, demo playback and recording, the tic) and the
client queries sound_events.sql, sound_loops.sql, game_tick_finish.sql,
camera_pose.sql, spawn_pose.sql and stage_music.sql.

The tic is the world step of sql/tic_*.sql, run once over the map's current
tables: the tables are packed into world rows at tic 0, stepped to tic 1 with
sql/tic_staging.sql's outputs added, and every table's next version is the
other maps' rows plus this tic's."""

from pathlib import Path

from .. import game
from ..backend import literal, pg
from ..sqlmacro import strip_comments
from ..world import KINDS, TRANSIENT_KINDS, World

ROOT = Path(__file__).resolve().parents[2]
CLIENT = Path("/Users/alexy/src/saildoom-ref/sqldoom/sql/client")
STATIC_BY_MAP = ("linedef_geom", "node_path_steps", "nodes", "linedefs", "sector_adjacency",
                 "vertexes", "maps", "node_children", "segs", "ssectors")
ALL_KINDS = dict(KINDS, **TRANSIENT_KINDS)


def client_sql(name):
    return strip_comments((CLIENT / name).read_text())


def register(b):
    s = b.store

    def world():
        return World(schemas={t: s.arrow_schema(t) for _, t in ALL_KINDS.values()}, kinds=ALL_KINDS)

    def focus(map_id):
        for name in STATIC_BY_MAP:
            b.spark.sql(f"SELECT * FROM parquet.`{s.path(name)}` WHERE map_id = {map_id}"
                        ).createOrReplaceTempView(name)

    def unfocus():
        for name in STATIC_BY_MAP:
            s._register(name)

    def run_tic(map_id, player, skill):
        w = world()
        for _, table in ALL_KINDS.values():
            b.spark.sql(f"SELECT 0 AS tic, * FROM {table}").createOrReplaceTempView("rec_" + table)
        b.spark.sql(f"""SELECT 1 AS tic, skill, skill_bit, move_fwd, move_strafe, running, turn_degrees,
                               attack_held, weapon_switch_to, use_requested
                        FROM game_tic_commands WHERE map_id = {map_id} AND player_thing_id = {player}"""
                    ).createOrReplaceTempView("cmd")
        focus(map_id)
        try:
            prev = "\n  UNION ALL\n  ".join(w.recorded_rows(k, "tic = 0") for k in w.kinds)
            step = game._step_sql(w, game.TIC_FILES[:-1] + ("tic_out.sql", "tic_staging.sql"))
            params = dict(game.CONSTANTS, map_id=map_id, player=player, skill=skill,
                          se_next=b.sequence("sound_events") + 1)
            s.write("_tic_out", f"WITH RECURSIVE prev AS (\n  {prev}\n),\n{step}\nSELECT * FROM step", params)
        finally:
            unfocus()
        for kind, (col, table) in w.kinds.items():
            names = [n for n, _ in w.fields[kind] if n not in ("t_x", "t_y", "t_z", "t_angle", "last_mode")]
            keep = (f"NOT (map_id = {map_id} AND player_thing_id = {player})" if kind == "P"
                    else f"map_id <> {map_id}")
            cols = ", ".join(names)
            fields = ", ".join(f"{col}.{n} AS {n}" for n in names)
            s.write(table, f"""SELECT {cols} FROM {table} WHERE {keep}
                               UNION ALL
                               SELECT {fields} FROM _tic_out WHERE kind = '{kind}'""")
        top = s.query(f"SELECT MAX(event_id) AS m FROM sound_events")[0]["m"]
        if top is not None and top > b.sequence("sound_events"):
            b.set_sequence("sound_events", top)
        row = s.query(f"SELECT stages FROM tic_trace WHERE map_id = {map_id} AND player_thing_id = {player}")
        return bool(row and row[0]["stages"] & 65536)

    @b.handler("doom_game_tic")
    def game_tic(map_id, player, skill, fwd, strafe, running, turn, attack, switch, use):
        bit = 1 if skill <= 1 else 2 if skill == 2 else 4
        f = lambda v: f"CAST({literal(str(v))} AS FLOAT)"
        exists = bool(s.query(f"SELECT 1 FROM game_tic_commands WHERE map_id = {map_id} AND player_thing_id = {player}"))
        new = f"""SELECT {map_id} AS map_id, {player} AS player_thing_id, {{serial}} AS command_serial,
                 {skill} AS skill, {bit} AS skill_bit, {f(fwd)} AS move_fwd, {f(strafe)} AS move_strafe,
                 {literal(bool(running))} AS running, {f(turn)} AS turn_degrees, {literal(bool(attack))} AS attack_held,
                 {literal(switch)} AS weapon_switch_to, {literal(bool(use))} AS use_requested, 'idle' AS movement_mode"""
        if exists:
            row = new.format(serial="g.command_serial + 1") + " FROM game_tic_commands g WHERE g.map_id = {m} AND g.player_thing_id = {p}".format(m=map_id, p=player)
        else:
            row = new.format(serial="CAST(1 AS BIGINT)")
        b.replace_rows("game_tic_commands", f"map_id = {map_id} AND player_thing_id = {player}", row)
        demo(map_id, player)
        due = run_tic(map_id, player, skill)
        return [(due,)]

    def demo(map_id, player):
        st = s.query("SELECT demo_playing, demo_recording, demo_tic, attract_step FROM screen_state WHERE id = 0")[0]
        playing, recording, dtic = st["demo_playing"], st["demo_recording"], st["demo_tic"]
        if playing is not None:
            have = bool(s.query(f"SELECT 1 FROM demo_tics WHERE demo_id = {playing} AND tic = {dtic}"))
            if have:
                b.update("game_tic_commands", {c: f"d.{c}" for c in (
                    "move_fwd", "move_strafe", "running", "turn_degrees", "attack_held",
                    "weapon_switch_to", "use_requested")},
                    f"t.map_id = {map_id} AND t.player_thing_id = {player}",
                    joins=f"LEFT JOIN (SELECT * FROM demo_tics WHERE demo_id = {playing} AND tic = {dtic}) d ON TRUE")
                b.update("screen_state", {"demo_tic": "t.demo_tic + 1"}, "t.id = 0")
            else:
                b.update("screen_state", {"demo_playing": "NULL", "demo_tic": "0",
                                          "screen": "CASE WHEN t.attract_step >= 0 THEN 'title' ELSE t.screen END",
                                          "attract_pagetic": "0"}, "t.id = 0")
        if recording is not None:
            cols = "move_fwd, move_strafe, running, turn_degrees, attack_held, weapon_switch_to, use_requested"
            b.replace_rows("demo_tics", f"demo_id = {recording} AND tic = {dtic}",
                           f"""SELECT {recording} AS demo_id, {dtic} AS tic, {cols} FROM game_tic_commands
                               WHERE map_id = {map_id} AND player_thing_id = {player}""")
            b.update("demos", {"tic_count": f"GREATEST(t.tic_count, {dtic + 1})"}, f"t.demo_id = {recording}")
            b.update("screen_state", {"demo_tic": "t.demo_tic + 1"}, "t.id = 0")

    @b.handler("doom_sound_events")
    def sound_events(map_id, player, map_id2, after):
        return [tuple(r) for r in s.query(pg(client_sql("sound_events.sql"), (map_id, player, map_id2, after)))]

    @b.handler("doom_sound_loops")
    def sound_loops(map_id, player):
        return [tuple(r) for r in s.query(pg(client_sql("sound_loops.sql"), (map_id, player)))]

    @b.handler("doom_game_tick_finish")
    def tick_finish(map_id, player):
        return [tuple(r) for r in s.query(pg(client_sql("game_tick_finish.sql"), (map_id, player)))]

    @b.handler("doom_camera_pose")
    def camera(map_id, player, alpha):
        a = max(0.0, min(1.0, float(alpha)))
        rows = s.query(f"""SELECT ps.previous_x + (ps.position_x - ps.previous_x) * {a!r}D AS x,
            ps.previous_y + (ps.position_y - ps.previous_y) * {a!r}D AS y,
            ps.previous_view_z + (ps.view_z - ps.previous_view_z) * {a!r}D AS z,
            w.a0 + t.turn * {a!r}D - 360.0D * FLOOR((w.a0 + t.turn * {a!r}D) / 360.0D) AS angle
          FROM player_state ps
          CROSS JOIN (SELECT CAST(ps2.previous_view_angle AS DOUBLE) AS a0,
                             CAST(ps2.view_angle AS DOUBLE) - CAST(ps2.previous_view_angle AS DOUBLE) + 180.0D AS d
                      FROM player_state ps2 WHERE ps2.map_id = {map_id} AND ps2.player_thing_id = {player}) w
          CROSS JOIN (SELECT (w2.d - 360.0D * FLOOR(w2.d / 360.0D)) - 180.0D AS turn
                      FROM (SELECT CAST(view_angle AS DOUBLE) - CAST(previous_view_angle AS DOUBLE) + 180.0D AS d
                            FROM player_state WHERE map_id = {map_id} AND player_thing_id = {player}) w2) t
          WHERE ps.map_id = {map_id} AND ps.player_thing_id = {player}""")
        return [tuple(r) for r in rows]

    @b.handler("doom_spawn_pose")
    def spawn_pose(map_id, player):
        return [tuple(r) for r in s.query(pg(client_sql("spawn_pose.sql"), (map_id, player)))]

    @b.handler("doom_stage_music")
    def music(map_id):
        return [tuple(r) for r in s.query(pg(client_sql("stage_music.sql"), (map_id,)))]

    @b.raw(client_sql("stages.sql"))
    def stages():
        return [tuple(r) for r in s.query(client_sql("stages.sql"))]
