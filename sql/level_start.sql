-- The world at tic 0 of a level, from the map's tables: SQLDoom's
-- doom_enter_level (41_flow) -- 04_reset_stage, 05_spawn_player and the
-- secret check -- then the cheats a run starts with (38_cheats: IDDQD,
-- IDCLIP, IDKFA and 07_cheat_arsenal).
--
-- The map's tables are the ones the WAD loader writes, read as map_<table>:
-- map_sectors, map_sidedefs, map_render_segs, map_things, map_render_things,
-- map_line_buttons. Output: one relation per kind (P_out ... F_out) at
-- ntic = 0, which saildoom/game.py packs into world rows.
skill_bit AS (
  SELECT CASE WHEN ${skill} <= 1 THEN 1 WHEN ${skill} = 2 THEN 2 ELSE 4 END AS bit
),
ls_sectors AS (
  -- Mutable sector geometry back to how the map spawned it.
  SELECT 0 AS ntic, s.id, s.map_id, s.spawn_floor_height AS floor_height, s.spawn_ceil_height AS ceil_height,
         s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex, s.spawn_light_level,
         s.spawn_floor_tex AS floor_tex, s.ceil_tex, COALESCE(s.spawn_light_level, s.light_level) AS light_level,
         s.special, s.tag
  FROM map_sectors s
),
ls_light_fx AS (
  SELECT 0 AS ntic, s.map_id, s.id AS sector_id, s.special,
         COALESCE(s.spawn_light_level, s.light_level) AS base_light,
         LEAST(COALESCE(s.spawn_light_level, s.light_level), COALESCE(MIN(other.light_level), 0)) AS dark_light
  FROM map_sectors s
  LEFT JOIN linedefs edge ON edge.map_id = s.map_id
  LEFT JOIN map_sidedefs r ON r.id = edge.right_sd_id
  LEFT JOIN map_sidedefs l ON l.id = edge.left_sd_id
  LEFT JOIN ls_sectors other ON other.id = CASE WHEN r.sector_id = s.id THEN l.sector_id
                                                WHEN l.sector_id = s.id THEN r.sector_id END
  WHERE s.special IN (1, 2, 3, 8, 12, 13, 17)
  GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level
),
ls_sidedefs AS (
  -- Switch textures back to their unpressed state.
  SELECT 0 AS ntic, sd.id, sd.map_id, sd.x_offset, sd.y_offset,
         COALESCE(u.original_tex, sd.upper_tex) AS upper_tex,
         COALESCE(l.original_tex, sd.lower_tex) AS lower_tex,
         COALESCE(m.original_tex, sd.mid_tex) AS mid_tex,
         sd.sector_id
  FROM map_sidedefs sd
  LEFT JOIN map_line_buttons u ON u.sidedef_id = sd.id AND u.texture_part = 'upper'
  LEFT JOIN map_line_buttons m ON m.sidedef_id = sd.id AND m.texture_part = 'middle'
  LEFT JOIN map_line_buttons l ON l.sidedef_id = sd.id AND l.texture_part = 'lower'
),
ls_render_segs AS (
  SELECT 0 AS ntic, rs.map_id, rs.seg_id, rs.ssector_id, rs.direction, rs.linedef_id,
    rs.x1, rs.y1, rs.x2, rs.y2, rs.seg_u1, rs.seg_u2, rs.fsec, rs.bsec,
    COALESCE(sd.x_offset, rs.x_offset) AS x_offset, COALESCE(sd.y_offset, rs.y_offset) AS y_offset,
    CASE WHEN sd.id IS NOT NULL THEN sd.upper_tex ELSE rs.upper_tex END AS upper_tex,
    CASE WHEN sd.id IS NOT NULL THEN sd.mid_tex ELSE rs.mid_tex END AS mid_tex,
    CASE WHEN sd.id IS NOT NULL THEN sd.lower_tex ELSE rs.lower_tex END AS lower_tex,
    rs.flags,
    COALESCE(fs.floor_height, rs.f_floor) AS f_floor, COALESCE(fs.ceil_height, rs.f_ceil) AS f_ceil,
    CASE WHEN fs.id IS NOT NULL THEN fs.ceil_tex ELSE rs.f_ceil_tex END AS f_ceil_tex,
    COALESCE(fs.light_level, rs.f_light) AS f_light,
    COALESCE(bs.floor_height, rs.b_floor) AS b_floor, COALESCE(bs.ceil_height, rs.b_ceil) AS b_ceil,
    CASE WHEN bs.id IS NOT NULL THEN bs.ceil_tex ELSE rs.b_ceil_tex END AS b_ceil_tex,
    COALESCE(bs.light_level, rs.b_light) AS b_light,
    rs.light_bias
  FROM map_render_segs rs
  LEFT JOIN linedefs ld ON ld.map_id = rs.map_id AND ld.id = rs.linedef_id
  LEFT JOIN ls_sidedefs sd ON sd.id = CASE WHEN rs.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
  LEFT JOIN ls_sectors fs ON fs.id = rs.fsec
  LEFT JOIN ls_sectors bs ON bs.id = rs.bsec
),
ls_render_things AS (
  SELECT 0 AS ntic, rt.map_id, rt.thing_id, COALESCE(rt.spawn_sector_id, rt.sector_id) AS sector_id,
         rt.spawn_sector_id, rt.sprite, rt.frame, rt.fullbright, rt.spawn_ceiling, rt.thing_height
  FROM map_render_things rt
  WHERE rt.thing_id < ${DROPPED_THING_ID_BASE}
),
ls_things0 AS (
  -- Back to the spawn spot; a floater back on its sector's floor.
  SELECT t.id, t.map_id, CAST(t.spawn_x AS FLOAT) AS x, CAST(t.spawn_y AS FLOAT) AS y,
    CASE WHEN d.floats THEN CAST(s.floor_height AS FLOAT) ELSE t.z END AS z,
    CAST(t.spawn_angle AS FLOAT) AS angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CAST(0 AS FLOAT) AS mom_x, CAST(0 AS FLOAT) AS mom_y, t.type, t.flags
  FROM map_things t
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type AND d.floats
  LEFT JOIN ls_render_things rt ON rt.thing_id = t.id
  LEFT JOIN ls_sectors s ON s.id = rt.sector_id
  WHERE t.id < ${DROPPED_THING_ID_BASE}
),
ls_spawn AS (
  -- The player on its start: the eye 41 above the floor of the sector the
  -- start is in (02_geometry's doom_sector_at).
  SELECT t.id AS player_thing_id, CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y,
         CAST(t.angle AS DOUBLE) AS angle, sf.sector_id,
         CAST(s.floor_height AS DOUBLE) + ${VIEWHEIGHT} AS view_z
  FROM ls_things0 t
  JOIN thing_role_defs r ON r.thing_type = t.type AND r.is_player_start AND r.player_number = 1
  JOIN (
    SELECT l.player_thing_id, min_by(rs.fsec, rs.seg_id) AS sector_id
    FROM (
      SELECT t2.id AS player_thing_id, st.ssector_id
      FROM ls_things0 t2
      JOIN thing_role_defs r2 ON r2.thing_type = t2.type AND r2.is_player_start AND r2.player_number = 1
      JOIN node_path_steps st ON st.map_id = ${map_id}
      JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
      GROUP BY t2.id, st.ssector_id
      HAVING bool_and(st.side = CASE
        WHEN (CAST(t2.x AS DOUBLE) - n.x) * CAST(n.dy AS DOUBLE)
           - (CAST(t2.y AS DOUBLE) - n.y) * CAST(n.dx AS DOUBLE) > 0 THEN 'R' ELSE 'L' END)
    ) l
    JOIN render_segs rs ON rs.map_id = ${map_id} AND rs.ssector_id = l.ssector_id
    GROUP BY l.player_thing_id
  ) sf ON sf.player_thing_id = t.id
  JOIN ls_sectors s ON s.id = sf.sector_id
),
ammo_caps0 AS (
  SELECT MAX(CASE WHEN ammo_type = 'bullets' THEN cap END) AS bullets,
         MAX(CASE WHEN ammo_type = 'shells' THEN cap END) AS shells,
         MAX(CASE WHEN ammo_type = 'rockets' THEN cap END) AS rockets,
         MAX(CASE WHEN ammo_type = 'cells' THEN cap END) AS cells
  FROM ammo_defs
),
P_out AS (
  SELECT 0 AS tic, ${map_id} AS map_id, p.player_thing_id, 100 AS health, TRUE AS alive, CAST(0 AS BIGINT) AS level_tics,
    CAST(p.x AS FLOAT) AS previous_x, CAST(p.y AS FLOAT) AS previous_y,
    CAST(p.x AS FLOAT) AS position_x, CAST(p.y AS FLOAT) AS position_y,
    CAST(p.view_z AS FLOAT) AS base_z, CAST(p.view_z AS FLOAT) AS view_z, CAST(p.angle AS FLOAT) AS view_angle,
    CAST(0 AS FLOAT) AS momentum_x, CAST(0 AS FLOAT) AS momentum_y, CAST(0 AS FLOAT) AS bob_strength,
    CAST(p.view_z AS FLOAT) AS previous_view_z, CAST(p.angle AS FLOAT) AS previous_view_angle,
    p.sector_id, 0 AS pain_face_tics, 0 AS armor, 0 AS armor_class, FALSE AS backpack,
    CASE WHEN ${arsenal} THEN c.bullets ELSE 50 END AS ammo_bullets,
    CASE WHEN ${arsenal} THEN c.shells ELSE 0 END AS ammo_shells,
    CASE WHEN ${arsenal} THEN c.rockets ELSE 0 END AS ammo_rockets,
    CASE WHEN ${arsenal} THEN c.cells ELSE 0 END AS ammo_cells,
    ${keys} AS key_blue, ${keys} AS key_yellow, ${keys} AS key_red,
    0 AS radsuit_tics, 0 AS invis_tics, CAST(0 AS FLOAT) AS momentum_z, 0 AS damage_count, 0 AS bonus_count,
    0 AS light_amp_tics, FALSE AS power_map, ${god} AS god_mode, ${noclip} AS noclip, 0 AS invuln_tics,
    FALSE AS berserk, CAST(NULL AS STRING) AS message, 0 AS message_tics, 0 AS frags, 0 AS death_tics,
    CAST(NULL AS INT) AS killer_id, 'A' AS sprite_frame,
    CAST(p.x AS FLOAT) AS t_x, CAST(p.y AS FLOAT) AS t_y, CAST(p.view_z AS FLOAT) AS t_z,
    CAST(p.angle AS FLOAT) AS t_angle, CAST(NULL AS STRING) AS last_mode
  FROM ls_spawn p CROSS JOIN ammo_caps0 c
),
S_out AS (SELECT * FROM ls_sectors),
M_out AS (SELECT * FROM M0 WHERE FALSE),
E_out AS (SELECT * FROM E0 WHERE FALSE),
A_out AS (SELECT * FROM A0 WHERE FALSE),
B_out AS (SELECT * FROM B0 WHERE FALSE),
D_out AS (SELECT * FROM ls_sidedefs),
R_out AS (SELECT * FROM ls_render_segs),
T_out AS (
  SELECT 0 AS ntic, t.id, t.map_id,
    CASE WHEN p.player_thing_id IS NOT NULL THEN CAST(p.x AS FLOAT) ELSE t.x END AS x,
    CASE WHEN p.player_thing_id IS NOT NULL THEN CAST(p.y AS FLOAT) ELSE t.y END AS y,
    CASE WHEN p.player_thing_id IS NOT NULL THEN CAST(p.view_z AS FLOAT) ELSE t.z END AS z,
    CASE WHEN p.player_thing_id IS NOT NULL THEN CAST(p.angle AS FLOAT) ELSE t.angle END AS angle,
    t.spawn_x, t.spawn_y, t.spawn_angle, t.mom_x, t.mom_y, t.type, t.flags
  FROM ls_things0 t LEFT JOIN ls_spawn p ON p.player_thing_id = t.id
),
H_out AS (
  SELECT 0 AS ntic, t.map_id, t.id AS thing_id, d.spawn_health AS health, d.spawn_health AS max_health, TRUE AS alive
  FROM ls_things0 t
  JOIN thing_combat_defs d ON d.thing_type = t.type
  CROSS JOIN skill_bit sb
  WHERE (t.flags & sb.bit) <> 0 AND (t.flags & 16) = 0
),
I_out AS (
  SELECT ntic, map_id, thing_id, 'stand' AS state, -1 AS state_tics, 0 AS seq_index, CAST(NULL AS INT) AS sector_id,
         0 AS attack_cooldown, FALSE AS fired_this_tick, CAST(NULL AS INT) AS target_thing_id, 0 AS charge_tics,
         0 AS movedir, 0 AS movecount
  FROM H_out
),
N_out AS (SELECT * FROM ls_render_things),
X_out AS (SELECT * FROM X0 WHERE FALSE),
W_out AS (
  SELECT 0 AS ntic, ${map_id} AS map_id, player_thing_id, 2 AS current_weapon, CAST(NULL AS INT) AS pending_weapon,
         'up' AS state, 0 AS seq_index, 1 AS tics, CAST(NULL AS INT) AS flash_seq_index, 0 AS flash_tics,
         CAST(1 AS FLOAT) AS sx, CAST(128 AS FLOAT) AS sy, CAST(0 AS BIGINT) AS shot_serial, FALSE AS fired_this_tick
  FROM ls_spawn
),
O_out AS (
  SELECT 0 AS ntic, ${map_id} AS map_id, p.player_thing_id, w.weapon_id
  FROM ls_spawn p
  CROSS JOIN (SELECT explode(sequence(1, 8)) AS weapon_id) w
  WHERE w.weapon_id <= 2 OR ${arsenal}
),
U_out AS (SELECT * FROM U0 WHERE FALSE),
L_out AS (
  SELECT 0 AS ntic, ${map_id} AS map_id, p.player_thing_id, p.sector_id
  FROM ls_spawn p
  JOIN ls_sectors s ON s.id = p.sector_id
  JOIN sector_special_defs sd ON sd.special = s.special AND sd.is_secret
),
Y_out AS (SELECT * FROM Y0 WHERE FALSE),
Q_out AS (SELECT * FROM Q0 WHERE FALSE),
Z_out AS (SELECT * FROM Z0 WHERE FALSE),
F_out AS (SELECT * FROM ls_light_fx)
