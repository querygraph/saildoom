"""Saving and loading a game: 32_save_load.sql's doom_save_game and
doom_load_game, with the loader's doom_materialize_render_segs and
doom_materialize_render_things that a load rebuilds the render caches with."""

from ..backend import literal

SAVED = ("player_state", "player_weapons", "player_weapon_owned", "things", "thing_health", "monster_ai",
         "monster_projectiles", "world_effects", "sectors", "sidedefs", "sector_movers", "line_buttons",
         "line_activations", "picked_up_items", "level_secret_discoveries", "level_stats")
CLEARED_ON_LOAD = ("game_tic_commands", "line_special_events", "line_use_results", "pickup_touches",
                   "pickup_grants", "sound_events", "hitscan_hits", "projectile_damage", "projectile_impacts",
                   "monster_attack_damage")


def register(b):
    s = b.store

    def columns(table):
        return [f.name for f in s.arrow_schema(table)]

    @b.handler("doom_save_game_call")
    def save_game(slot, m, p, skill, name):
        b.replace_rows("save_slots", f"slot = {slot}", f"""
            SELECT {slot} AS slot, current_timestamp() AS saved_at, {literal(name)} AS name, {m} AS map_id,
                   {p} AS player_thing_id, (SELECT name FROM maps WHERE map_id = {m}) AS map_name,
                   COALESCE((SELECT skill_bit FROM level_stats WHERE map_id = {m} AND player_thing_id = {p}), {skill}) AS skill""")
        for table in SAVED:
            cols = ", ".join(columns(table))
            b.replace_rows("save_" + table, f"slot = {slot}",
                           f"SELECT {slot} AS slot, {cols} FROM {table} WHERE map_id = {m}")
        return [(slot,)]

    @b.handler("doom_load_game_call")
    def load_game(slot):
        row = s.query(f"SELECT COALESCE(MIN(map_id), -1) AS m FROM save_slots WHERE slot = {slot}")[0]
        target = row["m"]
        if target < 0:
            return [(target,)]
        for table in SAVED:
            cols = ", ".join(columns(table))
            b.replace_rows(table, f"map_id = {target}", f"SELECT {cols} FROM save_{table} WHERE slot = {slot}")
        for table in CLEARED_ON_LOAD:
            b.replace_rows(table, f"map_id = {target}", f"SELECT * FROM {table} WHERE FALSE")
        materialize_render_segs(target)
        materialize_render_things(target)
        b.replace_rows("sector_light_fx", f"map_id = {target}", f"""
            SELECT s.map_id, s.id AS sector_id, s.special,
                   COALESCE(s.spawn_light_level, s.light_level) AS base_light,
                   LEAST(COALESCE(s.spawn_light_level, s.light_level), COALESCE(MIN(other.light_level), 0)) AS dark_light
            FROM sectors s
            LEFT JOIN linedefs edge ON edge.map_id = s.map_id
            LEFT JOIN sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id
            LEFT JOIN sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id
            LEFT JOIN sectors other ON other.map_id = s.map_id
              AND other.id = CASE WHEN r.sector_id = s.id THEN l.sector_id
                                  WHEN l.sector_id = s.id THEN r.sector_id END
            WHERE s.map_id = {target} AND s.special IN (1, 2, 3, 8, 12, 13, 17)
            GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level""")
        return [(target,)]

    def materialize_render_segs(m):
        # The sidedef ids are columns before the join on them: a join key
        # spanning two relations is apache/datafusion#26058.
        b.replace_rows("render_segs", f"map_id = {m}", f"""
            SELECT q.map_id, q.seg_id, q.ssector_id, q.direction, q.linedef_id,
              q.x1, q.y1, q.x2, q.y2,
              CASE WHEN q.direction = 0 THEN CAST(q.offs AS DOUBLE) ELSE q.offs + q.len END AS seg_u1,
              CASE WHEN q.direction = 0 THEN q.offs + q.len ELSE CAST(q.offs AS DOUBLE) END AS seg_u2,
              fs.id AS fsec, bs.id AS bsec, front.x_offset, front.y_offset,
              front.upper_tex, front.mid_tex, front.lower_tex, q.flags,
              fs.floor_height AS f_floor, fs.ceil_height AS f_ceil, fs.ceil_tex AS f_ceil_tex, fs.light_level AS f_light,
              bs.floor_height AS b_floor, bs.ceil_height AS b_ceil, bs.ceil_tex AS b_ceil_tex, bs.light_level AS b_light,
              CASE WHEN q.y1 = q.y2 THEN -1 WHEN q.x1 = q.x2 THEN 1 ELSE 0 END AS light_bias
            FROM (
              SELECT sg.map_id, sg.id AS seg_id, ss.id AS ssector_id, sg.direction, sg.linedef_id, sg.offs,
                     v1.x AS x1, v1.y AS y1, v2.x AS x2, v2.y AS y2, ld.flags,
                     CAST(SQRT(POWER(v2.x - v1.x, 2) + POWER(v2.y - v1.y, 2)) AS DOUBLE) AS len,
                     CASE WHEN sg.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END AS front_sd,
                     CASE WHEN sg.direction = 0 THEN ld.left_sd_id ELSE ld.right_sd_id END AS back_sd
              FROM segs sg
              JOIN ssectors ss ON ss.map_id = sg.map_id AND sg.id >= ss.first_seg_id AND sg.id < ss.first_seg_id + ss.seg_count
              JOIN vertexes v1 ON v1.map_id = sg.map_id AND v1.id = sg.v1_id
              JOIN vertexes v2 ON v2.map_id = sg.map_id AND v2.id = sg.v2_id
              JOIN linedefs ld ON ld.map_id = sg.map_id AND ld.id = sg.linedef_id
              WHERE sg.map_id = {m}
            ) q
            JOIN sidedefs front ON front.map_id = q.map_id AND front.id = q.front_sd
            LEFT JOIN sidedefs back ON back.map_id = q.map_id AND back.id = q.back_sd
            JOIN sectors fs ON fs.map_id = q.map_id AND fs.id = front.sector_id
            LEFT JOIN sectors bs ON bs.map_id = q.map_id AND bs.id = back.sector_id""")

    def materialize_render_things(m):
        # The BSP descent as node_path_steps: the subsector whose path the
        # point follows. (tx - n.x) is real - integer, single precision.
        b.replace_rows("render_things", f"map_id = {m}", f"""
            SELECT l.map_id, l.thing_id, l.sector_id, l.sector_id AS spawn_sector_id,
                   d.sprite, d.frame, d.fullbright, d.spawn_ceiling, d.thing_height
            FROM (
              SELECT x.map_id, x.thing_id, min_by(rs.fsec, rs.seg_id) AS sector_id
              FROM (
                SELECT t.map_id, t.id AS thing_id, st.ssector_id
                FROM things t
                JOIN thing_sprite_defs d0 ON d0.thing_type = t.type
                JOIN node_path_steps st ON st.map_id = t.map_id
                JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
                WHERE t.map_id = {m}
                GROUP BY t.map_id, t.id, t.x, t.y, st.ssector_id
                HAVING bool_and(st.side = CASE
                  WHEN CAST(t.x - n.x AS DOUBLE) * CAST(n.dy AS DOUBLE)
                     - CAST(t.y - n.y AS DOUBLE) * CAST(n.dx AS DOUBLE) > 0 THEN 'R' ELSE 'L' END)
              ) x
              JOIN render_segs rs ON rs.map_id = x.map_id AND rs.ssector_id = x.ssector_id
              GROUP BY x.map_id, x.thing_id
            ) l
            JOIN things t ON t.map_id = l.map_id AND t.id = l.thing_id
            JOIN thing_sprite_defs d ON d.thing_type = t.type""")
