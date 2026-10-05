-- The start of SQLDoom's tic, before the player moves: the clock, use,
-- linedef special activation and the sector mover stage.
--
-- Ported from cedardb/sqldoom sql/runtime/functions: 09_cs_clock,
-- 10_cs_plan (the gates), 11_cs_use, 12_cs_activate_specials (the door,
-- floor and platform mechanics, switch textures, one-shot activations) and
-- 13_cs_doors (movers, switch restore, plane heights, render_segs). The
-- other mechanics of 12 (donut, raise, stairs, lights, teleport, ceiling,
-- crusher, stop) are not ported yet: `unported_events` lists any that fire.
--
-- Input: P0 S0 M0 E0 A0 B0 D0 R0, the tables at the end of tic t, keyed by
-- ntic = t + 1. Output: P1 (clocked), S2 M2 E2 A1 B2 D2 R2.
clocked AS (
  SELECT p.*,
         p.level_tics + 1 AS c_level_tics,
         GREATEST(0, p.pain_face_tics - 1) AS c_pain_face_tics,
         GREATEST(0, p.radsuit_tics - 1) AS c_radsuit_tics,
         GREATEST(0, p.invis_tics - 1) AS c_invis_tics,
         GREATEST(0, p.light_amp_tics - 1) AS c_light_amp_tics,
         GREATEST(0, p.invuln_tics - 1) AS c_invuln_tics,
         GREATEST(0, p.message_tics - 1) AS c_message_tics,
         CASE WHEN p.message_tics <= 1 THEN CAST(NULL AS STRING) ELSE p.message END AS c_message,
         GREATEST(0, p.damage_count - 1) AS c_damage_count,
         GREATEST(0, p.bonus_count - 1) AS c_bonus_count
  FROM P0 p
),
-- 10_cs_plan, bit 4: movers or switch buttons are running at the start of the tic.
movers_due0 AS (
  SELECT ntic FROM M0 WHERE direction <> 2
  UNION SELECT ntic FROM B0 WHERE countdown > 0
),
-- ---------------------------------------------------------------- 11_cs_use
use_lines AS (
  SELECT c.ntic, ld.linedef_id AS id, ld.special, ld.flags, ld.left_sd_id, ld.right_sd_id,
         CAST(ld.x1 AS DOUBLE) AS x1, CAST(ld.y1 AS DOUBLE) AS y1,
         CAST(ld.x2 AS DOUBLE) AS x2, CAST(ld.y2 AS DOUBLE) AS y2,
         rf.floor_height AS front_floor, rf.ceil_height AS front_ceil,
         rb.floor_height AS back_floor, rb.ceil_height AS back_ceil,
         CAST(c.t_x AS DOUBLE) AS px, CAST(c.t_y AS DOUBLE) AS py,
         COS(RADIANS(CAST(c.t_angle AS DOUBLE))) AS dx,
         SIN(RADIANS(CAST(c.t_angle AS DOUBLE))) AS dy,
         c.key_red, c.key_blue, c.key_yellow, c.player_thing_id
  FROM clocked c
  JOIN cmd g ON g.tic = c.ntic AND g.use_requested
  JOIN linedef_geom ld ON ld.map_id = ${map_id}
  LEFT JOIN S0 rf ON rf.ntic = c.ntic AND rf.id = ld.fsec
  LEFT JOIN S0 rb ON rb.ntic = c.ntic AND rb.id = ld.bsec
),
use_hits AS (
  SELECT q.*,
    ((q.x1 - q.px) * (q.y2 - q.y1) - (q.y1 - q.py) * (q.x2 - q.x1)) / q.denom AS distance,
    ((q.x1 - q.px) * q.dy - (q.y1 - q.py) * q.dx) / q.denom AS line_fraction,
    ((q.x2 - q.x1) * (q.py - q.y1) - (q.y2 - q.y1) * (q.px - q.x1)) < 0 AS from_front
  FROM (SELECT l.*, l.dx * (l.y2 - l.y1) - l.dy * (l.x2 - l.x1) AS denom FROM use_lines l) q
  WHERE ABS(q.denom) > 1e-9D
),
use_hit AS (
  SELECT * FROM (
    SELECT h.*, ROW_NUMBER() OVER (PARTITION BY h.ntic ORDER BY h.distance, h.id) AS rn
    FROM use_hits h
    WHERE h.distance BETWEEN 0 AND ${USERANGE}
      AND h.line_fraction BETWEEN 0 AND 1
      AND (h.special <> 0 OR h.left_sd_id = -1 OR h.right_sd_id = -1 OR (h.flags & 1) <> 0
        OR (LEAST(h.front_ceil, h.back_ceil) - GREATEST(h.front_floor, h.back_floor)) <= 0)
  ) q WHERE q.rn = 1
),
use_events AS (
  SELECT h.ntic, ${map_id} AS map_id, h.player_thing_id, h.id AS line_id,
         'use' AS trigger_type, h.from_front
  FROM use_hit h
  LEFT JOIN line_special_defs d ON d.special = h.special
  LEFT JOIN A0 a ON a.ntic = h.ntic AND a.line_id = h.id
  WHERE (h.from_front AND COALESCE(d.use_activated, FALSE))
    AND NOT COALESCE((d.key_required = 'red' AND NOT h.key_red)
                  OR (d.key_required = 'blue' AND NOT h.key_blue)
                  OR (d.key_required = 'yellow' AND NOT h.key_yellow), FALSE)
    AND NOT (COALESCE(d.use_once, FALSE) AND a.line_id IS NOT NULL)
),
E1 AS (
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM E0
  UNION ALL
  SELECT u.ntic, u.map_id, u.player_thing_id, u.line_id, u.trigger_type, u.from_front
  FROM use_events u
  LEFT ANTI JOIN E0 e ON e.ntic = u.ntic AND e.player_thing_id = u.player_thing_id
    AND e.line_id = u.line_id AND e.trigger_type = u.trigger_type
),
-- ---------------------------------------------------------------- 12_cs_activate_specials
ev1 AS (
  SELECT e.*, ld.special, ld.tag, ld.right_sd_id, ld.left_sd_id,
         d.mechanic, d.flips_switch, d.door_target, d.mover_type, d.direction,
         d.speed, d.wait_tics, d.height_target, d.change_tex,
         (COALESCE(d.cross_once, FALSE) OR COALESCE(d.use_once, FALSE)) AS one_shot
  FROM E1 e
  JOIN linedefs ld ON ld.map_id = ${map_id} AND ld.id = e.line_id
  LEFT JOIN line_special_defs d ON d.special = ld.special
),
ev_dedup AS (
  -- One event per mechanic and tag: the lowest line (then the lowest player) wins.
  SELECT e.* FROM ev1 e
  LEFT ANTI JOIN ev1 e2 ON e2.ntic = e.ntic AND e2.mechanic = e.mechanic
    AND ((e.tag <> 0 AND e2.tag = e.tag) OR (e.tag = 0 AND e2.line_id = e.line_id))
    AND (e2.line_id < e.line_id OR (e2.line_id = e.line_id AND e2.player_thing_id < e.player_thing_id))
),
ev AS (
  -- Drop one-shot events whose line has fired already.
  SELECT e.* FROM ev_dedup e
  LEFT ANTI JOIN A0 a ON a.ntic = e.ntic AND a.line_id = e.line_id AND e.one_shot
),
unported_events AS (
  SELECT ntic, line_id, special, mechanic FROM ev
  WHERE mechanic IN ('donut', 'raise', 'stairs', 'lights', 'teleport', 'ceiling', 'crusher', 'stop')
),
adjacency AS (
  SELECT sector_id, other_id, linedef_id FROM sector_adjacency
  WHERE map_id = ${map_id} AND sector_id <> other_id
),
-- doors
door_sectors AS (
  SELECT e.ntic, e.line_id, e.special,
         CASE WHEN e.door_target = 'back' THEN back.sector_id ELSE s.id END AS sector_id
  FROM ev e
  LEFT JOIN D0 back ON back.ntic = e.ntic AND back.id = e.left_sd_id
  LEFT JOIN S0 s ON s.ntic = e.ntic AND s.tag = e.tag
  WHERE e.mechanic = 'door'
    AND ((e.door_target = 'back' AND back.sector_id IS NOT NULL)
      OR (e.door_target = 'tag' AND s.id IS NOT NULL))
),
door_targets AS (
  SELECT q.* FROM (
    SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.ntic, t.sector_id ORDER BY t.line_id) AS rn
    FROM (
      SELECT d.ntic, d.line_id, d.special, d.sector_id, s.floor_height, s.ceil_height,
             GREATEST(s.ceil_height, COALESCE(MIN(n.ceil_height) - 4, s.ceil_height)) AS open_height
      FROM door_sectors d
      JOIN S0 s ON s.ntic = d.ntic AND s.id = d.sector_id
      LEFT JOIN adjacency a ON a.sector_id = d.sector_id
      LEFT JOIN S0 n ON n.ntic = d.ntic AND n.id = a.other_id
      GROUP BY d.ntic, d.line_id, d.special, d.sector_id, s.floor_height, s.ceil_height
    ) t
  ) q WHERE q.rn = 1
),
door_new AS (
  SELECT t.ntic, ${map_id} AS map_id, t.sector_id, t.line_id AS source_line_id,
         d.mover_type, 'ceiling' AS plane, d.direction, t.floor_height AS bottom_height,
         CASE WHEN d.direction = -1 THEN t.ceil_height ELSE t.open_height END AS top_height,
         d.speed, 0.0D AS move_carry, d.wait_tics, 0 AS countdown,
         CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor,
         CAST(NULL AS STRING) AS target_floor_tex, FALSE AS moved_this_tick, FALSE AS crush
  FROM door_targets t JOIN line_special_defs d ON d.special = t.special
),
M1a AS (
  -- INSERT ... ON CONFLICT (sector) DO UPDATE: a manual door toggles an
  -- existing ceiling mover; anything else is left as it is.
  SELECT m.ntic, m.map_id, m.sector_id,
    CASE WHEN n.mover_type = 'door_manual_raise' AND m.plane = 'ceiling' THEN n.source_line_id ELSE m.source_line_id END AS source_line_id,
    m.mover_type, m.plane,
    CASE WHEN n.mover_type = 'door_manual_raise' AND m.plane = 'ceiling'
         THEN CASE WHEN m.direction IN (-1, 2) THEN 1 ELSE -1 END ELSE m.direction END AS direction,
    m.bottom_height, m.top_height, m.speed, m.move_carry, m.wait_tics,
    CASE WHEN n.mover_type = 'door_manual_raise' AND m.plane = 'ceiling' THEN 0 ELSE m.countdown END AS countdown,
    CASE WHEN n.mover_type = 'door_manual_raise' AND m.plane = 'ceiling' THEN CAST(NULL AS INT) ELSE m.next_ceiling END AS next_ceiling,
    m.next_floor, m.target_floor_tex,
    CASE WHEN n.mover_type = 'door_manual_raise' AND m.plane = 'ceiling' THEN FALSE ELSE m.moved_this_tick END AS moved_this_tick,
    m.crush
  FROM M0 m LEFT JOIN door_new n ON n.ntic = m.ntic AND n.sector_id = m.sector_id
  UNION ALL
  SELECT n.* FROM door_new n LEFT ANTI JOIN M0 m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
-- floors (lower)
floor_dest AS (
  SELECT t.*,
    CASE WHEN t.height_target = 'lowest' THEN t.lowest_floor
         WHEN t.height_target = 'highest' THEN t.highest_floor
         WHEN t.highest_floor <> t.floor_height THEN t.highest_floor + 8
         ELSE t.floor_height END AS destination
  FROM (
    SELECT e.ntic, e.line_id, e.special, e.height_target, e.mover_type, e.direction,
           e.speed, e.change_tex, s.id AS sector_id, s.floor_height,
           MIN(o.floor_height) AS lowest_floor, MAX(o.floor_height) AS highest_floor
    FROM ev e
    JOIN S0 s ON s.ntic = e.ntic AND s.tag = e.tag
    JOIN adjacency a ON a.sector_id = s.id
    JOIN S0 o ON o.ntic = e.ntic AND o.id = a.other_id
    WHERE e.mechanic = 'floor'
    GROUP BY e.ntic, e.line_id, e.special, e.height_target, e.mover_type, e.direction,
             e.speed, e.change_tex, s.id, s.floor_height
  ) t
),
floor_new AS (
  SELECT q.ntic, ${map_id} AS map_id, q.sector_id, q.line_id AS source_line_id,
         q.mover_type, 'floor' AS plane, q.direction,
         LEAST(q.floor_height, q.destination) AS bottom_height, q.floor_height AS top_height,
         q.speed, 0.0D AS move_carry, 0 AS wait_tics, 0 AS countdown,
         CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor,
         q.model_tex AS target_floor_tex, FALSE AS moved_this_tick, FALSE AS crush
  FROM (
    SELECT d.*, CASE WHEN d.change_tex THEN mt.model_tex END AS model_tex,
      ROW_NUMBER() OVER (PARTITION BY d.ntic, d.sector_id ORDER BY d.line_id) AS rn
    FROM floor_dest d
    LEFT JOIN (
      -- The texture of the lowest-numbered neighbour at the destination height.
      SELECT d2.ntic, d2.line_id, d2.sector_id, min_by(o.floor_tex, o.id) AS model_tex
      FROM floor_dest d2
      JOIN adjacency a2 ON a2.sector_id = d2.sector_id
      JOIN S0 o ON o.ntic = d2.ntic AND o.id = a2.other_id AND o.floor_height = d2.destination
      GROUP BY d2.ntic, d2.line_id, d2.sector_id
    ) mt ON mt.ntic = d.ntic AND mt.line_id = d.line_id AND mt.sector_id = d.sector_id
    WHERE d.destination < d.floor_height
  ) q WHERE q.rn = 1
),
M1b AS (
  SELECT * FROM M1a
  UNION ALL
  SELECT n.* FROM floor_new n LEFT ANTI JOIN M1a m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
-- lifts (platforms)
lift_new AS (
  SELECT q.ntic, ${map_id} AS map_id, q.sector_id, q.line_id AS source_line_id,
         q.mover_type, 'floor' AS plane, q.direction,
         LEAST(q.floor_height, q.lowest_floor) AS bottom_height,
         CASE WHEN q.mover_type = 'platform_perpetual' THEN GREATEST(q.floor_height, q.highest_floor)
              ELSE q.floor_height END AS top_height,
         q.speed, 0.0D AS move_carry, q.wait_tics, 0 AS countdown,
         CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor,
         CAST(NULL AS STRING) AS target_floor_tex, FALSE AS moved_this_tick, FALSE AS crush
  FROM (
    SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.ntic, t.sector_id ORDER BY t.line_id) AS rn
    FROM (
      SELECT e.ntic, e.line_id, e.mover_type, e.direction, e.speed, e.wait_tics,
             s.id AS sector_id, s.floor_height,
             MIN(o.floor_height) AS lowest_floor, MAX(o.floor_height) AS highest_floor
      FROM ev e
      JOIN S0 s ON s.ntic = e.ntic AND s.tag = e.tag
      JOIN adjacency a ON a.sector_id = s.id
      JOIN S0 o ON o.ntic = e.ntic AND o.id = a.other_id
      WHERE e.mechanic = 'platform'
      GROUP BY e.ntic, e.line_id, e.mover_type, e.direction, e.speed, e.wait_tics, s.id, s.floor_height
    ) t
  ) q WHERE q.rn = 1
),
M1 AS (
  -- ON CONFLICT DO UPDATE ... WHERE the existing mover is a finished floor:
  -- it starts down again.
  SELECT m.ntic, m.map_id, m.sector_id,
    CASE WHEN n.sector_id IS NOT NULL AND m.direction = 2 AND m.plane = 'floor' THEN n.source_line_id ELSE m.source_line_id END AS source_line_id,
    m.mover_type, m.plane,
    CASE WHEN n.sector_id IS NOT NULL AND m.direction = 2 AND m.plane = 'floor' THEN -1 ELSE m.direction END AS direction,
    m.bottom_height, m.top_height, m.speed, m.move_carry, m.wait_tics,
    CASE WHEN n.sector_id IS NOT NULL AND m.direction = 2 AND m.plane = 'floor' THEN 0 ELSE m.countdown END AS countdown,
    m.next_ceiling,
    CASE WHEN n.sector_id IS NOT NULL AND m.direction = 2 AND m.plane = 'floor' THEN CAST(NULL AS INT) ELSE m.next_floor END AS next_floor,
    m.target_floor_tex,
    CASE WHEN n.sector_id IS NOT NULL AND m.direction = 2 AND m.plane = 'floor' THEN FALSE ELSE m.moved_this_tick END AS moved_this_tick,
    m.crush
  FROM M1b m LEFT JOIN lift_new n ON n.ntic = m.ntic AND n.sector_id = m.sector_id
  UNION ALL
  SELECT n.* FROM lift_new n LEFT ANTI JOIN M1b m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
-- switch textures (flips_switch on an SW1 texture)
button_events AS (
  SELECT DISTINCT e.ntic, e.line_id, e.right_sd_id, e.one_shot
  FROM ev e WHERE e.flips_switch
),
button_parts AS (
  SELECT x.ntic, x.line_id, x.sidedef_id, x.p.part AS texture_part, x.p.tex AS original_tex,
         CASE WHEN x.one_shot THEN -1 ELSE 35 END AS countdown
  FROM (
    SELECT e.ntic, e.line_id, e.right_sd_id AS sidedef_id, e.one_shot,
           explode(array(named_struct('part', 'upper', 'tex', sd.upper_tex),
                         named_struct('part', 'middle', 'tex', sd.mid_tex),
                         named_struct('part', 'lower', 'tex', sd.lower_tex))) AS p
    FROM button_events e JOIN D0 sd ON sd.ntic = e.ntic AND sd.id = e.right_sd_id
  ) x
  WHERE x.p.tex LIKE 'SW1%'
),
B1 AS (
  -- A restored repeatable button keeps its row at countdown 0 until it is
  -- pressed again.
  SELECT b.* FROM B0 b
  LEFT ANTI JOIN (SELECT DISTINCT ntic, line_id FROM ev) e
    ON e.ntic = b.ntic AND e.line_id = b.line_id AND b.countdown = 0
  UNION ALL
  SELECT p.ntic, ${map_id} AS map_id, p.line_id, p.sidedef_id, p.texture_part, p.original_tex,
         'SW2' || substring(p.original_tex, 4) AS active_tex, p.countdown, FALSE AS just_restored
  FROM button_parts p
),
pressed_sidedefs AS (
  SELECT DISTINCT b.ntic, b.sidedef_id FROM B1 b
  JOIN (SELECT DISTINCT ntic, line_id FROM ev) e ON e.ntic = b.ntic AND e.line_id = b.line_id
),
D1 AS (
  SELECT sd.ntic, sd.id, sd.map_id, sd.x_offset, sd.y_offset,
    CASE WHEN ps.sidedef_id IS NOT NULL THEN COALESCE(u.active_tex, sd.upper_tex) ELSE sd.upper_tex END AS upper_tex,
    CASE WHEN ps.sidedef_id IS NOT NULL THEN COALESCE(l.active_tex, sd.lower_tex) ELSE sd.lower_tex END AS lower_tex,
    CASE WHEN ps.sidedef_id IS NOT NULL THEN COALESCE(mi.active_tex, sd.mid_tex) ELSE sd.mid_tex END AS mid_tex,
    sd.sector_id
  FROM D0 sd
  LEFT JOIN pressed_sidedefs ps ON ps.ntic = sd.ntic AND ps.sidedef_id = sd.id
  LEFT JOIN B1 u ON u.ntic = sd.ntic AND u.sidedef_id = sd.id AND u.texture_part = 'upper'
  LEFT JOIN B1 mi ON mi.ntic = sd.ntic AND mi.sidedef_id = sd.id AND mi.texture_part = 'middle'
  LEFT JOIN B1 l ON l.ntic = sd.ntic AND l.sidedef_id = sd.id AND l.texture_part = 'lower'
),
buttons_ran AS (SELECT DISTINCT ntic FROM button_events),
R1 AS (
  -- When the switch branch runs, every seg's textures are read back from its sidedef.
  SELECT r.ntic, r.map_id, r.seg_id, r.ssector_id, r.direction, r.linedef_id,
    r.x1, r.y1, r.x2, r.y2, r.seg_u1, r.seg_u2, r.fsec, r.bsec, r.x_offset, r.y_offset,
    CASE WHEN br.ntic IS NOT NULL THEN sd.upper_tex ELSE r.upper_tex END AS upper_tex,
    CASE WHEN br.ntic IS NOT NULL THEN sd.mid_tex ELSE r.mid_tex END AS mid_tex,
    CASE WHEN br.ntic IS NOT NULL THEN sd.lower_tex ELSE r.lower_tex END AS lower_tex,
    r.flags, r.f_floor, r.f_ceil, r.f_ceil_tex, r.f_light, r.b_floor, r.b_ceil, r.b_ceil_tex,
    r.b_light, r.light_bias
  FROM R0 r
  LEFT JOIN buttons_ran br ON br.ntic = r.ntic
  LEFT JOIN linedefs ld ON br.ntic IS NOT NULL AND ld.map_id = ${map_id} AND ld.id = r.linedef_id
  LEFT JOIN D1 sd ON br.ntic IS NOT NULL AND sd.ntic = r.ntic
    AND sd.id = CASE WHEN r.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
),
A1 AS (
  SELECT ntic, map_id, line_id FROM A0
  UNION
  SELECT ntic, ${map_id} AS map_id, line_id FROM ev WHERE one_shot
),
activate_ran AS (SELECT DISTINCT ntic FROM E1),
active_after AS (
  SELECT ntic FROM M1 WHERE direction <> 2
  UNION SELECT ntic FROM B1 WHERE countdown > 0
),
doors_run AS (
  -- 40_run_game_tic: the mover stage runs when movers were due at the start
  -- of the tic, or the activation ran and left something active.
  SELECT ntic FROM movers_due0
  UNION SELECT a.ntic FROM activate_ran a JOIN active_after x ON x.ntic = a.ntic
),
-- ---------------------------------------------------------------- 13_cs_doors
B2 AS (
  SELECT b.ntic, b.map_id, b.line_id, b.sidedef_id, b.texture_part, b.original_tex, b.active_tex,
    CASE WHEN dr.ntic IS NOT NULL AND b.countdown >= 0 THEN GREATEST(0, b.countdown - 1) ELSE b.countdown END AS countdown,
    CASE WHEN dr.ntic IS NOT NULL AND b.countdown >= 0 THEN b.countdown = 1 ELSE b.just_restored END AS just_restored
  FROM B1 b LEFT JOIN doors_run dr ON dr.ntic = b.ntic
),
restored AS (
  SELECT DISTINCT b.ntic, b.sidedef_id, b.line_id FROM B2 b
  JOIN doors_run dr ON dr.ntic = b.ntic WHERE b.just_restored
),
D2 AS (
  SELECT sd.ntic, sd.id, sd.map_id, sd.x_offset, sd.y_offset,
    CASE WHEN r.sidedef_id IS NOT NULL THEN COALESCE(u.original_tex, sd.upper_tex) ELSE sd.upper_tex END AS upper_tex,
    CASE WHEN r.sidedef_id IS NOT NULL THEN COALESCE(l.original_tex, sd.lower_tex) ELSE sd.lower_tex END AS lower_tex,
    CASE WHEN r.sidedef_id IS NOT NULL THEN COALESCE(mi.original_tex, sd.mid_tex) ELSE sd.mid_tex END AS mid_tex,
    sd.sector_id
  FROM D1 sd
  LEFT JOIN (SELECT DISTINCT ntic, sidedef_id FROM restored) r ON r.ntic = sd.ntic AND r.sidedef_id = sd.id
  LEFT JOIN B2 u ON u.ntic = sd.ntic AND u.sidedef_id = sd.id AND u.texture_part = 'upper'
  LEFT JOIN B2 mi ON mi.ntic = sd.ntic AND mi.sidedef_id = sd.id AND mi.texture_part = 'middle'
  LEFT JOIN B2 l ON l.ntic = sd.ntic AND l.sidedef_id = sd.id AND l.texture_part = 'lower'
),
mover_pos AS (
  -- doom_sector_at(player Thing): the subsector whose BSP path matches.
  SELECT l.ntic, min_by(rs.fsec, rs.seg_id) AS sector_id
  FROM (
    SELECT c.ntic, st.ssector_id
    FROM clocked c
    JOIN doors_run dr ON dr.ntic = c.ntic
    JOIN node_path_steps st ON st.map_id = ${map_id}
    JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
    GROUP BY c.ntic, st.ssector_id
    HAVING bool_and(st.side = CASE
      WHEN (CAST(c.t_x AS DOUBLE) - n.x) * CAST(n.dy AS DOUBLE)
         - (CAST(c.t_y AS DOUBLE) - n.y) * CAST(n.dx AS DOUBLE) > 0 THEN 'R' ELSE 'L' END)
  ) l
  JOIN render_segs rs ON rs.map_id = ${map_id} AND rs.ssector_id = l.ssector_id
  GROUP BY l.ntic
),
occupied AS (
  SELECT DISTINCT ai.ntic, COALESCE(ai.sector_id, rt.sector_id) AS sector_id
  FROM I0 ai
  JOIN H0 h ON h.ntic = ai.ntic AND h.thing_id = ai.thing_id AND h.alive
  JOIN N0 rt ON rt.ntic = ai.ntic AND rt.thing_id = ai.thing_id
  JOIN doors_run dr ON dr.ntic = ai.ntic
),
mover_step AS (
  SELECT q.*,
    CASE WHEN q.plane = 'ceiling' THEN
      CASE q.move_direction WHEN 1 THEN LEAST(q.top_height, q.ceil_height + q.step_units)
        WHEN -1 THEN GREATEST(q.bottom_height, q.ceil_height - q.step_units)
        ELSE q.ceil_height END
      ELSE q.ceil_height END AS computed_ceiling,
    CASE WHEN q.plane = 'floor' THEN
      CASE q.move_direction WHEN 1 THEN LEAST(q.top_height, q.floor_height + q.step_units)
        WHEN -1 THEN GREATEST(q.bottom_height, q.floor_height - q.step_units)
        ELSE q.floor_height END
      ELSE q.floor_height END AS computed_floor
  FROM (
    SELECT m.*, s.floor_height, s.ceil_height,
      CASE WHEN m.plane = 'ceiling' AND m.direction = -1
            AND m.mover_type NOT IN ('door_close_open', 'door_close', 'crusher', 'ceiling_lower')
            AND (pp.sector_id = m.sector_id OR occ.sector_id IS NOT NULL)
           THEN 1 ELSE m.direction END AS move_direction,
      CAST(FLOOR(m.speed + m.move_carry) AS INT) AS step_units,
      (m.speed + m.move_carry) - FLOOR(m.speed + m.move_carry) AS carry_out
    FROM M1 m
    JOIN doors_run dr ON dr.ntic = m.ntic
    JOIN S0 s ON s.ntic = m.ntic AND s.id = m.sector_id
    LEFT JOIN mover_pos pp ON pp.ntic = m.ntic
    LEFT JOIN occupied occ ON occ.ntic = m.ntic AND occ.sector_id = m.sector_id
    WHERE m.direction <> 2
  ) q
),
mover_next AS (
  SELECT m.*,
    CASE
      WHEN m.move_direction = 1
        AND ((m.plane = 'ceiling' AND m.computed_ceiling >= m.top_height)
          OR (m.plane = 'floor' AND m.computed_floor >= m.top_height))
        THEN CASE WHEN m.mover_type IN ('door_raise', 'door_manual_raise', 'platform_perpetual') THEN 0
                  WHEN m.mover_type = 'crusher' THEN -1 ELSE 2 END
      WHEN m.move_direction = 0 AND m.countdown <= 1
        THEN CASE WHEN m.mover_type IN ('platform', 'door_close_open') THEN 1
                  WHEN m.mover_type = 'platform_perpetual'
                    THEN CASE WHEN m.floor_height >= m.top_height THEN -1 ELSE 1 END
                  ELSE -1 END
      WHEN m.move_direction = -1
        AND ((m.plane = 'ceiling' AND m.computed_ceiling <= m.bottom_height)
          OR (m.plane = 'floor' AND m.computed_floor <= m.bottom_height))
        THEN CASE WHEN m.mover_type IN ('platform', 'door_close_open', 'platform_perpetual') THEN 0
                  WHEN m.mover_type = 'crusher' THEN 1 ELSE 2 END
      ELSE m.move_direction END AS computed_direction,
    CASE
      WHEN m.move_direction = 1 AND m.mover_type IN ('door_raise', 'door_manual_raise', 'platform_perpetual')
        AND ((m.plane = 'ceiling' AND m.computed_ceiling >= m.top_height)
          OR (m.plane = 'floor' AND m.computed_floor >= m.top_height)) THEN m.wait_tics
      WHEN m.move_direction = -1 AND m.mover_type IN ('platform', 'platform_perpetual')
        AND m.computed_floor <= m.bottom_height THEN m.wait_tics
      WHEN m.move_direction = -1 AND m.mover_type = 'door_close_open'
        AND m.computed_ceiling <= m.bottom_height THEN m.wait_tics
      WHEN m.move_direction = 0 THEN GREATEST(0, m.countdown - 1)
      ELSE m.countdown END AS computed_countdown
  FROM mover_step m
),
M2 AS (
  SELECT m.ntic, m.map_id, m.sector_id, m.source_line_id, m.mover_type, m.plane,
    COALESCE(n.computed_direction, m.direction) AS direction,
    m.bottom_height, m.top_height, m.speed,
    CASE WHEN n.sector_id IS NULL THEN m.move_carry
         WHEN n.computed_direction IN (0, 2) THEN 0.0D ELSE n.carry_out END AS move_carry,
    m.wait_tics,
    COALESCE(n.computed_countdown, m.countdown) AS countdown,
    CASE WHEN n.sector_id IS NULL THEN m.next_ceiling ELSE n.computed_ceiling END AS next_ceiling,
    CASE WHEN n.sector_id IS NULL THEN m.next_floor ELSE n.computed_floor END AS next_floor,
    m.target_floor_tex,
    CASE WHEN n.sector_id IS NULL THEN m.moved_this_tick
         ELSE (n.computed_ceiling <> n.ceil_height OR n.computed_floor <> n.floor_height) END AS moved_this_tick,
    m.crush
  FROM M1 m LEFT JOIN mover_next n ON n.ntic = m.ntic AND n.sector_id = m.sector_id
),
moved AS (
  SELECT m.* FROM M2 m JOIN doors_run dr ON dr.ntic = m.ntic WHERE m.moved_this_tick
),
S2 AS (
  SELECT s.ntic, s.id, s.map_id,
    CASE WHEN mf.sector_id IS NOT NULL THEN mf.next_floor ELSE s.floor_height END AS floor_height,
    CASE WHEN mc.sector_id IS NOT NULL THEN mc.next_ceiling ELSE s.ceil_height END AS ceil_height,
    s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex, s.spawn_light_level,
    CASE WHEN mf.sector_id IS NOT NULL AND mf.direction = 2 AND mf.target_floor_tex IS NOT NULL
         THEN mf.target_floor_tex ELSE s.floor_tex END AS floor_tex,
    s.ceil_tex, s.light_level, s.special, s.tag
  FROM S0 s
  LEFT JOIN moved mf ON mf.ntic = s.ntic AND mf.sector_id = s.id AND mf.plane = 'floor'
  LEFT JOIN moved mc ON mc.ntic = s.ntic AND mc.sector_id = s.id AND mc.plane = 'ceiling'
),
R2 AS (
  SELECT r.ntic, r.map_id, r.seg_id, r.ssector_id, r.direction, r.linedef_id,
    r.x1, r.y1, r.x2, r.y2, r.seg_u1, r.seg_u2, r.fsec, r.bsec, r.x_offset, r.y_offset,
    CASE WHEN rb.ntic IS NOT NULL THEN sd.upper_tex ELSE r.upper_tex END AS upper_tex,
    CASE WHEN rb.ntic IS NOT NULL THEN sd.mid_tex ELSE r.mid_tex END AS mid_tex,
    CASE WHEN rb.ntic IS NOT NULL THEN sd.lower_tex ELSE r.lower_tex END AS lower_tex,
    r.flags,
    CASE WHEN fm.ntic IS NOT NULL THEN fs.floor_height ELSE r.f_floor END AS f_floor,
    CASE WHEN fm.ntic IS NOT NULL THEN fs.ceil_height ELSE r.f_ceil END AS f_ceil,
    CASE WHEN fm.ntic IS NOT NULL THEN fs.ceil_tex ELSE r.f_ceil_tex END AS f_ceil_tex,
    CASE WHEN fm.ntic IS NOT NULL THEN fs.light_level ELSE r.f_light END AS f_light,
    CASE WHEN bm.ntic IS NOT NULL THEN bs.floor_height ELSE r.b_floor END AS b_floor,
    CASE WHEN bm.ntic IS NOT NULL THEN bs.ceil_height ELSE r.b_ceil END AS b_ceil,
    CASE WHEN bm.ntic IS NOT NULL THEN bs.ceil_tex ELSE r.b_ceil_tex END AS b_ceil_tex,
    CASE WHEN bm.ntic IS NOT NULL THEN bs.light_level ELSE r.b_light END AS b_light,
    r.light_bias
  FROM R1 r
  LEFT JOIN (SELECT DISTINCT ntic, line_id FROM restored) rb ON rb.ntic = r.ntic AND rb.line_id = r.linedef_id
  LEFT JOIN linedefs ld ON rb.ntic IS NOT NULL AND ld.map_id = ${map_id} AND ld.id = r.linedef_id
  LEFT JOIN D2 sd ON rb.ntic IS NOT NULL AND sd.ntic = r.ntic
    AND sd.id = CASE WHEN r.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
  LEFT JOIN (SELECT DISTINCT ntic, sector_id FROM moved) fm ON fm.ntic = r.ntic AND fm.sector_id = r.fsec
  LEFT JOIN S2 fs ON fm.ntic IS NOT NULL AND fs.ntic = r.ntic AND fs.id = r.fsec
  LEFT JOIN (SELECT DISTINCT ntic, sector_id FROM moved) bm ON bm.ntic = r.ntic AND bm.sector_id = r.bsec
  LEFT JOIN S2 bs ON bm.ntic IS NOT NULL AND bs.ntic = r.ntic AND bs.id = r.bsec
),
