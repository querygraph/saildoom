"""Entering a level: 41_flow.sql's doom_enter_level -- 04_reset_stage,
05_spawn_player, 17_cs_secret, 30_carry_player -- as the statements
doom_enter_level_call, doom_reset_stage_call, doom_spawn_player,
doom_level_secret and doom_carry_player_call."""

VOID = [("",)]

# Tables 04_reset_stage empties for the map.
CLEARED = ("sector_movers", "line_buttons", "line_activations", "line_special_events",
           "line_use_results", "pickup_grants", "sound_events", "mapped_lines", "monster_deaths",
           "monster_steps", "automap_view", "monster_attack_damage", "monster_teleports",
           "world_effects", "monster_projectiles", "projectile_impacts", "projectile_damage",
           "hitscan_hits", "picked_up_items", "item_respawns", "pickup_touches", "game_tic_commands",
           "level_secret_discoveries")

DROPPED_BASE = 100000


def register(b):
    s = b.store

    def delete(table, where):
        b.replace_rows(table, where, f"SELECT * FROM {table} WHERE FALSE")

    def reset_stage(m, skill):
        bit = 1 if skill <= 1 else 2 if skill == 2 else 4
        b.update("sectors", {"floor_height": "t.spawn_floor_height", "ceil_height": "t.spawn_ceil_height",
                             "floor_tex": "t.spawn_floor_tex",
                             "light_level": "COALESCE(t.spawn_light_level, t.light_level)"}, f"t.map_id = {m}")
        b.replace_rows("sector_light_fx", f"map_id = {m}", f"""
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
            WHERE s.map_id = {m} AND s.special IN (1, 2, 3, 8, 12, 13, 17)
            GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level""")
        for side, sec in (("f", "fsec"), ("b", "bsec")):
            b.update("render_segs", {f"{side}_floor": "s.floor_height", f"{side}_ceil": "s.ceil_height",
                                     f"{side}_ceil_tex": "s.ceil_tex", f"{side}_light": "s.light_level"},
                     f"t.map_id = {m} AND s.id IS NOT NULL",
                     joins=f"LEFT JOIN sectors s ON s.map_id = t.map_id AND s.id = t.{sec}")
        delete("sector_movers", f"map_id = {m}")
        b.update("sidedefs", {"upper_tex": "COALESCE(u.original_tex, t.upper_tex)",
                              "mid_tex": "COALESCE(mi.original_tex, t.mid_tex)",
                              "lower_tex": "COALESCE(l.original_tex, t.lower_tex)"},
                 f"t.map_id = {m} AND o.sidedef_id IS NOT NULL",
                 joins=f"""LEFT JOIN (SELECT DISTINCT map_id, sidedef_id FROM line_buttons WHERE map_id = {m}) o
                             ON o.map_id = t.map_id AND o.sidedef_id = t.id
                           LEFT JOIN line_buttons u ON u.map_id = t.map_id AND u.sidedef_id = t.id AND u.texture_part = 'upper'
                           LEFT JOIN line_buttons mi ON mi.map_id = t.map_id AND mi.sidedef_id = t.id AND mi.texture_part = 'middle'
                           LEFT JOIN line_buttons l ON l.map_id = t.map_id AND l.sidedef_id = t.id AND l.texture_part = 'lower'""")
        b.update("render_segs", {"upper_tex": "sd.upper_tex", "mid_tex": "sd.mid_tex", "lower_tex": "sd.lower_tex",
                                 "x_offset": "sd.x_offset", "y_offset": "sd.y_offset"},
                 f"t.map_id = {m} AND sd.id IS NOT NULL",
                 joins="""LEFT JOIN linedefs ld ON ld.map_id = t.map_id AND ld.id = t.linedef_id
                          LEFT JOIN sidedefs sd ON sd.map_id = ld.map_id
                            AND sd.id = CASE WHEN t.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END""")
        for table in CLEARED:
            if table not in ("sector_movers",):
                delete(table, f"map_id = {m}")
        delete("render_things", f"map_id = {m} AND thing_id >= {DROPPED_BASE}")
        delete("things", f"map_id = {m} AND id >= {DROPPED_BASE}")
        b.update("things", {"x": "t.spawn_x", "y": "t.spawn_y", "angle": "t.spawn_angle",
                            "mom_x": "0", "mom_y": "0"}, f"t.map_id = {m}")
        b.update("render_things", {"sector_id": "t.spawn_sector_id"},
                 f"t.map_id = {m} AND t.spawn_sector_id IS NOT NULL AND t.sector_id <> t.spawn_sector_id")
        b.update("things", {"z": "s.floor_height"}, f"t.map_id = {m} AND s.id IS NOT NULL",
                 joins="""LEFT JOIN thing_combat_defs d ON d.thing_type = t.type AND d.floats
                          LEFT JOIN render_things rt ON d.thing_type IS NOT NULL AND rt.map_id = t.map_id AND rt.thing_id = t.id
                          LEFT JOIN sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id""")
        b.replace_rows("thing_health", f"map_id = {m}", f"""
            SELECT t.map_id, t.id AS thing_id, d.spawn_health AS health, d.spawn_health AS max_health, TRUE AS alive
            FROM things t JOIN thing_combat_defs d ON d.thing_type = t.type
            WHERE t.map_id = {m} AND (t.flags & {bit}) <> 0 AND (t.flags & 16) = 0""")
        b.replace_rows("monster_ai", f"map_id = {m}", f"""
            SELECT map_id, thing_id, 'stand' AS state, -1 AS state_tics, 0 AS seq_index, CAST(NULL AS INT) AS sector_id,
                   0 AS attack_cooldown, FALSE AS fired_this_tick, CAST(NULL AS INT) AS target_thing_id,
                   0 AS charge_tics, 0 AS movedir, 0 AS movecount
            FROM thing_health WHERE map_id = {m}""")
        start = f"""FROM things t JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
                    WHERE t.map_id = {m}"""
        b.replace_rows("player_weapons", f"map_id = {m}", f"""
            SELECT t.map_id, t.id AS player_thing_id, 2 AS current_weapon, CAST(NULL AS INT) AS pending_weapon,
                   'up' AS state, 0 AS seq_index, 1 AS tics, CAST(NULL AS INT) AS flash_seq_index, 0 AS flash_tics,
                   CAST(1 AS FLOAT) AS sx, CAST(128 AS FLOAT) AS sy, CAST(0 AS BIGINT) AS shot_serial,
                   FALSE AS fired_this_tick {start}""")
        b.replace_rows("player_weapon_owned", f"map_id = {m}", f"""
            SELECT t.map_id, t.id AS player_thing_id, w.weapon_id {start.replace('FROM things t', 'FROM things t CROSS JOIN (SELECT 1 AS weapon_id UNION ALL SELECT 2) w')}""")
        b.replace_rows("player_state", f"map_id = {m}", f"""
            SELECT t.map_id, t.id AS player_thing_id, 100 AS health, TRUE AS alive, CAST(0 AS BIGINT) AS level_tics,
              t.x AS previous_x, t.y AS previous_y, t.x AS position_x, t.y AS position_y, t.z AS base_z,
              t.z AS view_z, t.angle AS view_angle, CAST(0 AS FLOAT) AS momentum_x, CAST(0 AS FLOAT) AS momentum_y,
              CAST(0 AS FLOAT) AS bob_strength, CAST(41 AS FLOAT) AS previous_view_z,
              CAST(0 AS FLOAT) AS previous_view_angle, CAST(NULL AS INT) AS sector_id, 0 AS pain_face_tics,
              0 AS armor, 0 AS armor_class, FALSE AS backpack, 50 AS ammo_bullets, 0 AS ammo_shells,
              0 AS ammo_rockets, 0 AS ammo_cells, FALSE AS key_blue, FALSE AS key_yellow, FALSE AS key_red,
              0 AS radsuit_tics, 0 AS invis_tics, CAST(0 AS FLOAT) AS momentum_z, 0 AS damage_count,
              0 AS bonus_count, 0 AS light_amp_tics, FALSE AS power_map, FALSE AS god_mode, FALSE AS noclip,
              0 AS invuln_tics, FALSE AS berserk, CAST(NULL AS STRING) AS message, 0 AS message_tics, 0 AS frags,
              0 AS death_tics, CAST(NULL AS INT) AS killer_id, 'A' AS sprite_frame {start}""")
        b.replace_rows("level_stats", f"map_id = {m}", f"""
            SELECT t.map_id, t.id AS player_thing_id, {bit} AS skill_bit, CAST(0 AS BIGINT) AS level_tics,
              lp.par_secs * 35 AS par_tics,
              0 AS kills,
              (SELECT count(*) FROM things mt JOIN thing_combat_defs cd ON cd.thing_type = mt.type AND cd.counts_kill
                WHERE mt.map_id = {m} AND (mt.flags & {bit}) <> 0 AND (mt.flags & 16) = 0) AS total_kills,
              0 AS items,
              (SELECT count(*) FROM things it JOIN pickup_defs pd ON pd.thing_type = it.type AND pd.counts_item
                WHERE it.map_id = {m} AND (it.flags & {bit}) <> 0 AND (it.flags & 16) = 0) AS total_items,
              0 AS secrets,
              (SELECT count(*) FROM sectors s JOIN sector_special_defs sd ON sd.special = s.special AND sd.is_secret
                WHERE s.map_id = {m}) AS total_secrets,
              FALSE AS completed, FALSE AS secret_exit
            {start.replace('WHERE t.map_id', '''JOIN maps mm ON mm.map_id = t.map_id
                LEFT JOIN level_pars lp ON lp.episode = CAST(substring(mm.name, 2, 1) AS INT)
                  AND lp.level = CAST(substring(mm.name, 4, 1) AS INT) WHERE t.map_id''')}""")

    def spawn_player(m, p):
        pose = f"""(SELECT sf.sector_id, CAST(s.floor_height AS DOUBLE) + 41.0D AS view_z,
                           CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y, CAST(t.angle AS DOUBLE) AS angle
                    FROM things t
                    JOIN thing_role_defs r ON r.thing_type = t.type AND r.is_player_start
                    JOIN (SELECT min_by(rs.fsec, rs.seg_id) AS sector_id FROM (
                            SELECT st.ssector_id FROM node_path_steps st
                            JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
                            JOIN things t2 ON t2.map_id = {m} AND t2.id = {p}
                            WHERE st.map_id = {m}
                            GROUP BY st.ssector_id, t2.x, t2.y
                            HAVING bool_and(st.side = CASE
                              WHEN (CAST(t2.x AS DOUBLE) - n.x) * CAST(n.dy AS DOUBLE)
                                 - (CAST(t2.y AS DOUBLE) - n.y) * CAST(n.dx AS DOUBLE) > 0 THEN 'R' ELSE 'L' END)) l
                          JOIN render_segs rs ON rs.map_id = {m} AND rs.ssector_id = l.ssector_id) sf ON TRUE
                    JOIN sectors s ON s.map_id = {m} AND s.id = sf.sector_id
                    WHERE t.map_id = {m} AND t.id = {p}) pose"""
        b.update("player_state", {"previous_x": "pose.x", "previous_y": "pose.y", "position_x": "pose.x",
                                  "position_y": "pose.y", "base_z": "pose.view_z", "view_z": "pose.view_z",
                                  "view_angle": "pose.angle", "previous_view_z": "pose.view_z",
                                  "previous_view_angle": "pose.angle", "momentum_x": "0", "momentum_y": "0",
                                  "bob_strength": "0", "sector_id": "pose.sector_id"},
                 f"t.map_id = {m} AND t.player_thing_id = {p} AND pose.x IS NOT NULL",
                 joins=f"LEFT JOIN {pose} ON TRUE")
        b.update("things", {"x": "ps.position_x", "y": "ps.position_y", "z": "ps.view_z", "angle": "ps.view_angle"},
                 f"t.map_id = {m} AND t.id = {p}",
                 joins=f"LEFT JOIN player_state ps ON ps.map_id = {m} AND ps.player_thing_id = {p}")

    def secret(m, p):
        b.replace_rows("level_secret_discoveries", "FALSE", f"""
            SELECT ps.map_id, ps.player_thing_id, ps.sector_id FROM player_state ps
            JOIN sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
            JOIN sector_special_defs sd ON sd.special = s.special AND sd.is_secret
            LEFT ANTI JOIN level_secret_discoveries d ON d.map_id = ps.map_id
              AND d.player_thing_id = ps.player_thing_id AND d.sector_id = ps.sector_id
            WHERE ps.map_id = {m} AND ps.player_thing_id = {p}""")

    def carry(fm, fp, m, p):
        src = f"""(SELECT * FROM player_state WHERE map_id = {fm} AND player_thing_id = {fp}
                   AND alive AND health > 0) src"""
        b.update("player_state", {c: f"src.{c}" for c in (
            "health", "armor", "armor_class", "backpack", "ammo_bullets", "ammo_shells", "ammo_rockets", "ammo_cells")},
            f"t.map_id = {m} AND t.player_thing_id = {p} AND src.map_id IS NOT NULL",
            joins=f"LEFT JOIN {src} ON TRUE")
        alive = bool(s.query(f"SELECT 1 FROM player_state WHERE map_id = {fm} AND player_thing_id = {fp} AND alive AND health > 0"))
        if alive:
            b.replace_rows("player_weapon_owned", f"map_id = {m} AND player_thing_id = {p}", f"""
                SELECT {m} AS map_id, {p} AS player_thing_id, weapon_id FROM player_weapon_owned
                WHERE map_id = {fm} AND player_thing_id = {fp}""")
            b.update("player_weapons", {"current_weapon": "w.current_weapon"},
                     f"t.map_id = {m} AND t.player_thing_id = {p} AND w.map_id IS NOT NULL",
                     joins=f"LEFT JOIN (SELECT * FROM player_weapons WHERE map_id = {fm} AND player_thing_id = {fp}) w ON TRUE")

    @b.handler("doom_enter_level_call")
    def enter_level(m, p, skill, fm, fp):
        reset_stage(m, skill)
        spawn_player(m, p)
        secret(m, p)
        if fm is not None:
            carry(fm, fp, m, p)
        b.update("screen_state", {"cheat_buffer": "''"}, "t.id = 0")
        return [(1,)]

    @b.handler("doom_reset_stage_call")
    def reset_call(m, skill):
        reset_stage(m, skill)
        return VOID

    @b.handler("doom_spawn_player")
    def spawn_call(m, p):
        spawn_player(m, p)
        return VOID

    @b.handler("doom_level_secret")
    def secret_call(m, p):
        secret(m, p)
        return VOID

    @b.handler("doom_carry_player_call")
    def carry_call(fm, fp, m, p):
        carry(fm, fp, m, p)
        return VOID
