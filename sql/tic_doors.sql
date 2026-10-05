-- The start of SQLDoom's tic, before the player moves: the clock, use,
-- linedef special activation and the sector mover stage.
--
-- Ported from cedardb/sqldoom sql/runtime/functions: 09_cs_clock,
-- 10_cs_plan (the gates), 11_cs_use, 12_cs_activate_specials (the door,
-- floor and platform mechanics, switch textures, one-shot activations) and
-- 13_cs_doors (movers, switch restore, plane heights, crushing,
-- render_segs). Every mechanic of 12 is here: doors, floors, lifts, donuts,
-- switches, one-shot activations, raises, stairs, lights, teleports,
-- ceilings, crushers and stops, in the order 12 runs them.
--
-- Input: P0 S0 M0 E0 A0 B0 D0 R0, the tables at the end of tic t, keyed by
-- ntic = t + 1. Output: P1 (clocked0), S2 M2 E2 A1 B2 D2 R2.
clocked0 AS (
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
  FROM clocked0 c
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
         d.speed, d.wait_tics, d.height_target, d.change_tex, d.crush, d.step_height,
         d.target_light, d.light_source, d.stops_mover,
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
M1c AS (
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
donut_outside AS (
  SELECT q.* FROM (
    SELECT r.*, e.other_id AS outside_id,
           ROW_NUMBER() OVER (PARTITION BY r.ntic, r.line_id, r.pillar_id ORDER BY e.linedef_id) AS orn
    FROM (
      SELECT q2.* FROM (
        SELECT p.ntic, p.line_id, p.pillar_id, p.pillar_floor, e.other_id AS ring_id,
               ROW_NUMBER() OVER (PARTITION BY p.ntic, p.line_id, p.pillar_id ORDER BY e.linedef_id) AS rn
        FROM (SELECT e.ntic, e.line_id, s.id AS pillar_id, s.floor_height AS pillar_floor
              FROM ev e JOIN S0 s ON s.ntic = e.ntic AND s.tag = e.tag
              WHERE e.mechanic = 'donut') p
        JOIN sector_adjacency e ON e.map_id = ${map_id} AND e.sector_id = p.pillar_id
      ) q2 WHERE q2.rn = 1
    ) r
    JOIN sector_adjacency e ON e.map_id = ${map_id} AND e.sector_id = r.ring_id AND e.other_id <> r.pillar_id
  ) q WHERE q.orn = 1
),
-- donuts: lower the tagged pillar, raise its ring to the next sector outside
donut_motions AS (
  SELECT o.ntic, o.line_id, o.pillar_id AS sector_id, 'floor_lower' AS mover_type, -1 AS direction,
         LEAST(o.pillar_floor, s.floor_height) AS bottom_height, o.pillar_floor AS top_height,
         CAST(NULL AS STRING) AS target_tex
  FROM donut_outside o JOIN S0 s ON s.ntic = o.ntic AND s.id = o.outside_id
  UNION ALL
  SELECT o.ntic, o.line_id, o.ring_id, 'donut_raise', 1,
         ring.floor_height, GREATEST(ring.floor_height, s.floor_height), s.floor_tex
  FROM donut_outside o
  JOIN S0 ring ON ring.ntic = o.ntic AND ring.id = o.ring_id
  JOIN S0 s ON s.ntic = o.ntic AND s.id = o.outside_id
),
donut_new AS (
  SELECT ntic, ${map_id} AS map_id, sector_id, line_id AS source_line_id, mover_type, 'floor' AS plane,
         direction, bottom_height, top_height, 1.0D AS speed, 0.0D AS move_carry, 0 AS wait_tics, 0 AS countdown,
         CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor, target_tex AS target_floor_tex,
         FALSE AS moved_this_tick, FALSE AS crush
  FROM (SELECT d.*, ROW_NUMBER() OVER (PARTITION BY d.ntic, d.sector_id ORDER BY d.line_id, d.direction) AS rn
        FROM donut_motions d WHERE d.bottom_height <> d.top_height) q
  WHERE rn = 1
),
M1d AS (
  SELECT * FROM M1c
  UNION ALL
  SELECT n.* FROM donut_new n LEFT ANTI JOIN M1c m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
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
-- raises: to the lowest neighbouring ceiling, the next floor up, a fixed
-- rise or the shortest lower texture; the lowest_ceiling ones that are above
-- their target drop there at once
raise_targets AS (
  SELECT t.*,
    CASE t.height_target
      WHEN 'lowest_ceiling' THEN t.lowest_ceiling
      WHEN 'lowest_ceiling_minus8' THEN t.lowest_ceiling - 8
      WHEN 'plus24' THEN t.floor_height + 24
      WHEN 'plus32' THEN t.floor_height + 32
      WHEN 'plus512' THEN t.floor_height + 512
      WHEN 'shortest_texture' THEN t.floor_height + t.shortest_texture
      ELSE t.next_floor END AS destination
  FROM (
    SELECT e.ntic, e.line_id, e.height_target, e.change_tex, e.mover_type, e.direction, e.speed, e.crush,
      fs.floor_tex AS front_tex, s.id AS sector_id, s.floor_height,
      LEAST(MIN(o.ceil_height), s.ceil_height) AS lowest_ceiling,
      MIN(CASE WHEN o.floor_height > s.floor_height THEN o.floor_height END) AS next_floor,
      MIN(sh.shortest) AS shortest_texture
    FROM ev e
    JOIN S0 s ON s.ntic = e.ntic AND s.tag = e.tag
    JOIN adjacency a ON a.sector_id = s.id
    JOIN S0 o ON o.ntic = e.ntic AND o.id = a.other_id
    LEFT JOIN D0 fsd ON fsd.ntic = e.ntic AND fsd.id = e.right_sd_id
    LEFT JOIN S0 fs ON fs.ntic = e.ntic AND fs.id = fsd.sector_id
    LEFT JOIN (
      -- the shortest lower texture on the sector's two-sided lines, either side
      SELECT x.ntic, x.sector_id, MIN(wt.height) AS shortest
      FROM (
        SELECT sd.ntic, sd.sector_id, ld.right_sd_id, ld.left_sd_id
        FROM (SELECT DISTINCT ntic FROM ev WHERE mechanic = 'raise') rt
        JOIN D1 sd ON sd.ntic = rt.ntic
        JOIN linedefs ld ON ld.map_id = ${map_id} AND ld.right_sd_id = sd.id
        WHERE ld.right_sd_id IS NOT NULL AND ld.left_sd_id IS NOT NULL
        UNION ALL
        SELECT sd.ntic, sd.sector_id, ld.right_sd_id, ld.left_sd_id
        FROM (SELECT DISTINCT ntic FROM ev WHERE mechanic = 'raise') rt
        JOIN D1 sd ON sd.ntic = rt.ntic
        JOIN linedefs ld ON ld.map_id = ${map_id} AND ld.left_sd_id = sd.id AND ld.right_sd_id <> sd.id
        WHERE ld.right_sd_id IS NOT NULL AND ld.left_sd_id IS NOT NULL
      ) x
      JOIN D1 both_sides ON both_sides.ntic = x.ntic
        AND (both_sides.id = x.right_sd_id OR both_sides.id = x.left_sd_id)
      JOIN walltex_meta wt ON wt.name = both_sides.lower_tex
      WHERE both_sides.lower_tex IS NOT NULL AND both_sides.lower_tex <> '-'
      GROUP BY x.ntic, x.sector_id
    ) sh ON sh.ntic = e.ntic AND sh.sector_id = s.id
    WHERE e.mechanic = 'raise'
    GROUP BY e.ntic, e.line_id, e.height_target, e.change_tex, e.mover_type, e.direction, e.speed, e.crush,
             fs.floor_tex, s.id, s.floor_height, s.ceil_height
  ) t
),
raise_new AS (
  SELECT q.ntic, ${map_id} AS map_id, q.sector_id, q.line_id AS source_line_id, q.mover_type, 'floor' AS plane,
         q.direction, q.floor_height AS bottom_height, q.destination AS top_height, q.speed, 0.0D AS move_carry,
         0 AS wait_tics, 0 AS countdown, CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor,
         CASE WHEN q.change_tex THEN q.model_tex END AS target_floor_tex, FALSE AS moved_this_tick,
         COALESCE(q.crush, FALSE) AS crush
  FROM (
    SELECT r.*, CASE WHEN r.height_target IN ('plus24', 'plus32') THEN r.front_tex ELSE mt.model_tex END AS model_tex,
           ROW_NUMBER() OVER (PARTITION BY r.ntic, r.sector_id ORDER BY r.line_id) AS rn
    FROM raise_targets r
    LEFT JOIN (
      SELECT r2.ntic, r2.line_id, r2.sector_id, min_by(o.floor_tex, o.id) AS model_tex
      FROM raise_targets r2
      JOIN adjacency a ON a.sector_id = r2.sector_id
      JOIN S0 o ON o.ntic = r2.ntic AND o.id = a.other_id AND o.floor_height = r2.destination
      GROUP BY r2.ntic, r2.line_id, r2.sector_id
    ) mt ON mt.ntic = r.ntic AND mt.line_id = r.line_id AND mt.sector_id = r.sector_id
    WHERE r.destination IS NOT NULL AND r.destination > r.floor_height
  ) q WHERE q.rn = 1
),
M1e AS (
  SELECT * FROM M1d
  UNION ALL
  SELECT n.* FROM raise_new n LEFT ANTI JOIN M1d m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
raise_instant AS (
  SELECT q.ntic, q.id, MIN(q.dest) AS dest FROM (
    SELECT e.ntic, s.id, s.floor_height,
      LEAST(MIN(o.ceil_height), s.ceil_height) - CASE WHEN e.height_target = 'lowest_ceiling_minus8' THEN 8 ELSE 0 END AS dest
    FROM ev e
    JOIN S0 s ON s.ntic = e.ntic AND s.tag = e.tag AND e.tag <> 0
    JOIN sector_adjacency a ON a.map_id = ${map_id} AND a.sector_id = s.id
    JOIN S0 o ON o.ntic = e.ntic AND o.id = a.other_id
    WHERE e.mechanic = 'raise' AND e.height_target IN ('lowest_ceiling', 'lowest_ceiling_minus8') AND o.id <> s.id
    GROUP BY e.ntic, s.id, s.floor_height, s.ceil_height, e.height_target
  ) q
  LEFT ANTI JOIN M1e m ON m.ntic = q.ntic AND m.sector_id = q.id
  WHERE q.dest < q.floor_height
  GROUP BY q.ntic, q.id
),
S1a AS (
  SELECT s.ntic, s.id, s.map_id, COALESCE(r.dest, s.floor_height) AS floor_height, s.ceil_height,
         s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex, s.spawn_light_level,
         s.floor_tex, s.ceil_tex, s.light_level, s.special, s.tag
  FROM S0 s LEFT JOIN raise_instant r ON r.ntic = s.ntic AND r.id = s.id
),
-- stairs: outward from the tagged sector, one neighbour with the same flat
-- at a time, each step another step_height up
stair_chain AS (
  SELECT e.ntic, e.line_id, s.id AS sector_id, s.floor_tex, 0 AS step,
         s.floor_height + CAST(COALESCE(e.step_height, 8) AS INT) AS destination,
         array(s.id) AS seen, CAST(COALESCE(e.step_height, 8) AS INT) AS step_h, COALESCE(e.speed, 1.0D) AS speed
  FROM ev e JOIN S1a s ON s.ntic = e.ntic AND s.tag = e.tag
  WHERE e.mechanic = 'stairs'
  UNION ALL
  SELECT n.ntic, n.line_id, n.nid, n.ntex, n.step + 1, n.destination + n.step_h,
         concat(n.seen, array(n.nid)), n.step_h, n.speed
  FROM (
    SELECT c.ntic, c.line_id, c.step, c.destination, c.seen, c.step_h, c.speed,
           min_by(nxt.id, a.linedef_id) AS nid, min_by(nxt.floor_tex, a.linedef_id) AS ntex
    FROM stair_chain c
    JOIN sector_adjacency a ON a.map_id = ${map_id} AND a.sector_id = c.sector_id AND a.other_id <> a.sector_id
    JOIN S1a nxt ON nxt.ntic = c.ntic AND nxt.id = a.other_id AND nxt.floor_tex = c.floor_tex
    WHERE NOT array_contains(c.seen, nxt.id) AND c.step < 24
    GROUP BY c.ntic, c.line_id, c.sector_id, c.step, c.destination, c.seen, c.step_h, c.speed
  ) n
),
stair_new AS (
  SELECT q.ntic, ${map_id} AS map_id, q.sector_id, q.line_id AS source_line_id, 'floor_raise' AS mover_type,
         'floor' AS plane, 1 AS direction, q.floor_height AS bottom_height, q.destination AS top_height,
         q.speed, 0.0D AS move_carry, 0 AS wait_tics, 0 AS countdown,
         CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor, CAST(NULL AS STRING) AS target_floor_tex,
         FALSE AS moved_this_tick, FALSE AS crush
  FROM (
    SELECT c.*, s.floor_height, ROW_NUMBER() OVER (PARTITION BY c.ntic, c.sector_id ORDER BY c.line_id, c.step) AS rn
    FROM stair_chain c JOIN S1a s ON s.ntic = c.ntic AND s.id = c.sector_id
    WHERE c.destination > s.floor_height
  ) q WHERE q.rn = 1
),
M1f AS (
  SELECT * FROM M1e
  UNION ALL
  SELECT n.* FROM stair_new n LEFT ANTI JOIN M1e m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
-- lights: a fixed level or the brightest/dimmest neighbour; strobes start
-- flashing like a special-3 sector
light_new AS (
  SELECT e.ntic, s.id AS sector_id,
    MAX(CASE e.light_source WHEN 'max_neighbor' THEN nb.brightest WHEN 'min_neighbor' THEN nb.dimmest
             ELSE CAST(e.target_light AS INT) END) AS lvl
  FROM ev e
  JOIN S1a s ON s.ntic = e.ntic AND s.tag = e.tag
  LEFT JOIN (SELECT a.sector_id, o.ntic, MAX(o.light_level) AS brightest, MIN(o.light_level) AS dimmest
             FROM adjacency a JOIN S1a o ON o.id = a.other_id
             WHERE o.ntic IN (SELECT ntic FROM ev WHERE mechanic = 'lights')
             GROUP BY a.sector_id, o.ntic) nb ON nb.ntic = e.ntic AND nb.sector_id = s.id
  WHERE e.mechanic = 'lights' AND (e.light_source IS NULL OR e.light_source <> 'strobe')
  GROUP BY e.ntic, s.id
),
S1 AS (
  SELECT s.ntic, s.id, s.map_id, s.floor_height, s.ceil_height,
         s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex, s.spawn_light_level,
         s.floor_tex, s.ceil_tex,
         CASE WHEN l.lvl IS NOT NULL THEN l.lvl ELSE s.light_level END AS light_level, s.special, s.tag
  FROM S1a s LEFT JOIN light_new l ON l.ntic = s.ntic AND l.sector_id = s.id
),
F1 AS (
  SELECT ntic, map_id, sector_id, special, base_light, dark_light FROM F0
  UNION ALL
  SELECT q.ntic, ${map_id} AS map_id, q.id AS sector_id, 3 AS special, q.light_level AS base_light,
         LEAST(q.light_level, COALESCE(q.dimmest, 0)) AS dark_light
  FROM (
    SELECT DISTINCT e.ntic, s.id, s.light_level, nb.dimmest
    FROM ev e
    JOIN S1 s ON s.ntic = e.ntic AND s.tag = e.tag
    LEFT JOIN (SELECT a.sector_id, o.ntic, MIN(o.light_level) AS dimmest
               FROM sector_adjacency a JOIN S1 o ON o.id = a.other_id
               WHERE a.map_id = ${map_id} AND a.other_id <> a.sector_id
                 AND o.ntic IN (SELECT ntic FROM ev WHERE light_source = 'strobe')
               GROUP BY a.sector_id, o.ntic) nb ON nb.ntic = e.ntic AND nb.sector_id = s.id
    WHERE e.light_source = 'strobe'
  ) q
  LEFT ANTI JOIN F0 f ON f.ntic = q.ntic AND f.sector_id = q.id
),
lit_sectors AS (
  SELECT DISTINCT e.ntic, s.id FROM ev e JOIN S1 s ON s.ntic = e.ntic AND s.tag = e.tag
  WHERE e.mechanic = 'lights'
),
R1b AS (
  SELECT r.ntic, r.map_id, r.seg_id, r.ssector_id, r.direction, r.linedef_id,
    r.x1, r.y1, r.x2, r.y2, r.seg_u1, r.seg_u2, r.fsec, r.bsec, r.x_offset, r.y_offset,
    r.upper_tex, r.mid_tex, r.lower_tex, r.flags, r.f_floor, r.f_ceil, r.f_ceil_tex,
    CASE WHEN fl.id IS NOT NULL THEN fs.light_level ELSE r.f_light END AS f_light,
    r.b_floor, r.b_ceil, r.b_ceil_tex,
    CASE WHEN bl.id IS NOT NULL THEN bs.light_level ELSE r.b_light END AS b_light,
    r.light_bias
  FROM R1 r
  LEFT JOIN lit_sectors fl ON fl.ntic = r.ntic AND fl.id = r.fsec
  LEFT JOIN S1 fs ON fl.id IS NOT NULL AND fs.ntic = r.ntic AND fs.id = r.fsec
  LEFT JOIN lit_sectors bl ON bl.ntic = r.ntic AND bl.id = r.bsec
  LEFT JOIN S1 bs ON bl.id IS NOT NULL AND bs.ntic = r.ntic AND bs.id = r.bsec
),
-- teleports: onto the destination Thing in the tagged sector, facing its way
teleport_dest AS (
  SELECT q.* FROM (
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.ntic, c.player_thing_id ORDER BY c.off_centre, c.dest_id) AS rn
    FROM (
      SELECT t.ntic, t.player_thing_id, t.sector_id, t.floor_height, th.id AS dest_id,
             th.x AS dest_x, th.y AS dest_y, th.angle AS dest_angle,
             ABS(th.x - (t.min_x + t.max_x) / 2.0D) + ABS(th.y - (t.min_y + t.max_y) / 2.0D) AS off_centre
      FROM (
        SELECT e.ntic, e.line_id, e.player_thing_id, s.id AS sector_id, s.floor_height,
               MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x, MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
        FROM ev e
        JOIN S1 s ON s.ntic = e.ntic AND s.tag = e.tag
        JOIN render_segs rs ON rs.map_id = ${map_id} AND rs.fsec = s.id
        WHERE e.mechanic = 'teleport'
        GROUP BY e.ntic, e.line_id, e.player_thing_id, s.id, s.floor_height
      ) t
      JOIN T0 th ON th.ntic = t.ntic
      JOIN thing_role_defs tr ON tr.thing_type = th.type AND tr.is_teleport_dest
        AND th.x BETWEEN t.min_x AND t.max_x AND th.y BETWEEN t.min_y AND t.max_y
    ) c
  ) q WHERE q.rn = 1
),
clocked_t AS (
  SELECT c.ntic, c.map_id, c.player_thing_id, c.health, c.alive, c.level_tics,
    CASE WHEN d.ntic IS NULL THEN c.previous_x ELSE d.dest_x END AS previous_x,
    CASE WHEN d.ntic IS NULL THEN c.previous_y ELSE d.dest_y END AS previous_y,
    CASE WHEN d.ntic IS NULL THEN c.position_x ELSE d.dest_x END AS position_x,
    CASE WHEN d.ntic IS NULL THEN c.position_y ELSE d.dest_y END AS position_y,
    CASE WHEN d.ntic IS NULL THEN c.base_z ELSE CAST(d.floor_height + 41.0 AS FLOAT) END AS base_z,
    CASE WHEN d.ntic IS NULL THEN c.view_z ELSE CAST(d.floor_height + 41.0 AS FLOAT) END AS view_z,
    CASE WHEN d.ntic IS NULL THEN c.view_angle ELSE d.dest_angle END AS view_angle,
    CASE WHEN d.ntic IS NULL THEN c.momentum_x ELSE CAST(0 AS FLOAT) END AS momentum_x,
    CASE WHEN d.ntic IS NULL THEN c.momentum_y ELSE CAST(0 AS FLOAT) END AS momentum_y,
    CASE WHEN d.ntic IS NULL THEN c.bob_strength ELSE CAST(0 AS FLOAT) END AS bob_strength,
    CASE WHEN d.ntic IS NULL THEN c.previous_view_z ELSE CAST(d.floor_height + 41.0 AS FLOAT) END AS previous_view_z,
    CASE WHEN d.ntic IS NULL THEN c.previous_view_angle ELSE d.dest_angle END AS previous_view_angle,
    CASE WHEN d.ntic IS NULL THEN c.sector_id ELSE d.sector_id END AS sector_id,
    c.pain_face_tics, c.armor, c.armor_class, c.backpack, c.ammo_bullets, c.ammo_shells, c.ammo_rockets,
    c.ammo_cells, c.key_blue, c.key_yellow, c.key_red, c.radsuit_tics, c.invis_tics, c.momentum_z,
    c.damage_count, c.bonus_count, c.light_amp_tics, c.power_map, c.god_mode, c.noclip, c.invuln_tics,
    c.berserk, c.message, c.message_tics, c.frags, c.death_tics, c.killer_id, c.sprite_frame,
    CASE WHEN d.ntic IS NULL THEN c.t_x ELSE d.dest_x END AS t_x,
    CASE WHEN d.ntic IS NULL THEN c.t_y ELSE d.dest_y END AS t_y,
    CASE WHEN d.ntic IS NULL THEN c.t_z ELSE CAST(d.floor_height + 41.0 AS FLOAT) END AS t_z,
    CASE WHEN d.ntic IS NULL THEN c.t_angle ELSE d.dest_angle END AS t_angle,
    c.last_mode,
    c.c_level_tics, c.c_pain_face_tics, c.c_radsuit_tics, c.c_invis_tics, c.c_light_amp_tics,
    c.c_invuln_tics, c.c_message_tics, c.c_message, c.c_damage_count, c.c_bonus_count
  FROM clocked0 c LEFT JOIN teleport_dest d ON d.ntic = c.ntic AND d.player_thing_id = c.player_thing_id
),
-- ceilings on their own, crushers, and the lines that stop them
ceiling_new AS (
  SELECT q.ntic, ${map_id} AS map_id, q.sector_id, q.line_id AS source_line_id, q.mover_type, 'ceiling' AS plane,
    q.direction,
    CASE q.height_target WHEN 'highest_ceiling' THEN q.ceil_height
                         WHEN 'floor8' THEN q.floor_height + 8 ELSE q.floor_height END AS bottom_height,
    CASE q.height_target WHEN 'highest_ceiling' THEN GREATEST(q.ceil_height, COALESCE(q.highest_ceiling, q.ceil_height))
                         ELSE q.ceil_height END AS top_height,
    q.speed, 0.0D AS move_carry, 0 AS wait_tics, 0 AS countdown,
    CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor, CAST(NULL AS STRING) AS target_floor_tex,
    FALSE AS moved_this_tick, COALESCE(q.crush, FALSE) AS crush
  FROM (
    SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.ntic, t.sector_id ORDER BY t.line_id) AS rn
    FROM (
      SELECT e.ntic, e.line_id, e.height_target, e.mover_type, e.direction, e.speed, e.crush,
             s.id AS sector_id, s.floor_height, s.ceil_height, MAX(o.ceil_height) AS highest_ceiling
      FROM ev e
      JOIN S1 s ON s.ntic = e.ntic AND s.tag = e.tag
      LEFT JOIN adjacency a ON a.sector_id = s.id
      LEFT JOIN S1 o ON o.ntic = e.ntic AND o.id = a.other_id
      WHERE e.mechanic = 'ceiling'
      GROUP BY e.ntic, e.line_id, e.height_target, e.mover_type, e.direction, e.speed, e.crush,
               s.id, s.floor_height, s.ceil_height
    ) t
  ) q
  WHERE q.rn = 1
    AND ((q.direction = 1 AND COALESCE(q.highest_ceiling, q.ceil_height) > q.ceil_height)
      OR (q.direction = -1 AND q.ceil_height > CASE q.height_target WHEN 'floor8' THEN q.floor_height + 8 ELSE q.floor_height END))
),
M1g AS (
  SELECT * FROM M1f
  UNION ALL
  SELECT n.* FROM ceiling_new n LEFT ANTI JOIN M1f m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
crusher_new AS (
  SELECT q.ntic, ${map_id} AS map_id, q.sector_id, q.line_id AS source_line_id, 'crusher' AS mover_type,
         'ceiling' AS plane, -1 AS direction, q.floor_height + 8 AS bottom_height, q.ceil_height AS top_height,
         q.speed, 0.0D AS move_carry, 0 AS wait_tics, 0 AS countdown,
         CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor, CAST(NULL AS STRING) AS target_floor_tex,
         FALSE AS moved_this_tick, TRUE AS crush
  FROM (
    SELECT e.ntic, e.line_id, e.speed, s.id AS sector_id, s.floor_height, s.ceil_height,
           ROW_NUMBER() OVER (PARTITION BY e.ntic, s.id ORDER BY e.line_id) AS rn
    FROM ev e JOIN S1 s ON s.ntic = e.ntic AND s.tag = e.tag
    WHERE e.mechanic = 'crusher'
  ) q
  WHERE q.rn = 1 AND q.ceil_height > q.floor_height + 8
),
M1h AS (
  -- ON CONFLICT DO UPDATE ... WHERE the existing mover is a stopped crusher:
  -- it starts down again.
  SELECT m.ntic, m.map_id, m.sector_id,
    CASE WHEN r THEN n_source ELSE m.source_line_id END AS source_line_id,
    m.mover_type, m.plane,
    CASE WHEN r THEN -1 ELSE m.direction END AS direction,
    m.bottom_height, m.top_height, m.speed, m.move_carry, m.wait_tics,
    CASE WHEN r THEN 0 ELSE m.countdown END AS countdown,
    CASE WHEN r THEN CAST(NULL AS INT) ELSE m.next_ceiling END AS next_ceiling,
    m.next_floor, m.target_floor_tex,
    CASE WHEN r THEN FALSE ELSE m.moved_this_tick END AS moved_this_tick,
    m.crush
  FROM (SELECT m.*, n.sector_id IS NOT NULL AND m.mover_type = 'crusher' AND m.direction = 2 AS r,
               n.source_line_id AS n_source
        FROM M1g m LEFT JOIN crusher_new n ON n.ntic = m.ntic AND n.sector_id = m.sector_id) m
  UNION ALL
  SELECT n.* FROM crusher_new n LEFT ANTI JOIN M1g m ON m.ntic = n.ntic AND m.sector_id = n.sector_id
),
M1 AS (
  -- EV_CeilingCrushStop / EV_StopPlat: freeze the tagged movers of that kind.
  SELECT m.ntic, m.map_id, m.sector_id, m.source_line_id, m.mover_type, m.plane,
    CASE WHEN x.sector_id IS NOT NULL THEN 2 ELSE m.direction END AS direction,
    m.bottom_height, m.top_height, m.speed, m.move_carry, m.wait_tics, m.countdown,
    m.next_ceiling, m.next_floor, m.target_floor_tex,
    CASE WHEN x.sector_id IS NOT NULL THEN FALSE ELSE m.moved_this_tick END AS moved_this_tick,
    m.crush
  FROM M1h m
  LEFT JOIN (
    SELECT DISTINCT e.ntic, s.id AS sector_id, e.stops_mover
    FROM ev e JOIN S1 s ON s.ntic = e.ntic AND s.tag = e.tag
    WHERE e.mechanic = 'stop'
  ) x ON x.ntic = m.ntic AND x.sector_id = m.sector_id AND m.mover_type = x.stops_mover AND m.direction <> 2
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
    FROM clocked_t c
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
    JOIN S1 s ON s.ntic = m.ntic AND s.id = m.sector_id
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
  FROM S1 s
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
  FROM R1b r
  LEFT JOIN (SELECT DISTINCT ntic, line_id FROM restored) rb ON rb.ntic = r.ntic AND rb.line_id = r.linedef_id
  LEFT JOIN linedefs ld ON rb.ntic IS NOT NULL AND ld.map_id = ${map_id} AND ld.id = r.linedef_id
  LEFT JOIN D2 sd ON rb.ntic IS NOT NULL AND sd.ntic = r.ntic
    AND sd.id = CASE WHEN r.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
  LEFT JOIN (SELECT DISTINCT ntic, sector_id FROM moved) fm ON fm.ntic = r.ntic AND fm.sector_id = r.fsec
  LEFT JOIN S2 fs ON fm.ntic IS NOT NULL AND fs.ntic = r.ntic AND fs.id = r.fsec
  LEFT JOIN (SELECT DISTINCT ntic, sector_id FROM moved) bm ON bm.ntic = r.ntic AND bm.sector_id = r.bsec
  LEFT JOIN S2 bs ON bm.ntic IS NOT NULL AND bs.ntic = r.ntic AND bs.id = r.bsec
),
-- PIT_ChangeSector's crush: a crushing mover that has just closed the gap
-- below a Thing's height hurts it for 10 every fourth tic.
crushing AS (
  SELECT m.ntic, m.sector_id, s.ceil_height - s.floor_height AS gap
  FROM M2 m
  JOIN doors_run dr ON dr.ntic = m.ntic
  JOIN S2 s ON s.ntic = m.ntic AND s.id = m.sector_id
  JOIN clocked_t c ON c.ntic = m.ntic
  WHERE m.crush AND m.moved_this_tick
    AND ((m.plane = 'ceiling' AND m.direction = -1) OR (m.plane = 'floor' AND m.direction = 1))
    AND c.c_level_tics % 4 = 0
),
Hc AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN x.thing_id IS NULL THEN h.health ELSE h.health - 10 END AS health, h.max_health,
    CASE WHEN x.thing_id IS NULL THEN h.alive ELSE h.health - 10 > 0 END AS alive
  FROM H0 h
  LEFT JOIN (
    SELECT DISTINCT k.ntic, t.id AS thing_id
    FROM crushing k
    JOIN N0 rt ON rt.ntic = k.ntic AND rt.sector_id = k.sector_id
    JOIN T0 t ON t.ntic = k.ntic AND t.id = rt.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type AND NOT d.explodes
    WHERE k.gap < d.height
  ) x ON x.ntic = h.ntic AND x.thing_id = h.thing_id AND h.alive
),
clocked AS (
  -- The player, teleported, and crushed (10 a fourth tic) unless god mode.
  SELECT c.ntic, c.map_id, c.player_thing_id,
    CASE WHEN k.ntic IS NULL THEN c.health ELSE GREATEST(0, c.health - (10 - k.saved)) END AS health,
    CASE WHEN k.ntic IS NULL THEN c.alive ELSE (c.health - (10 - k.saved)) > 0 END AS alive,
    c.level_tics, c.previous_x, c.previous_y, c.position_x, c.position_y, c.base_z, c.view_z, c.view_angle,
    c.momentum_x, c.momentum_y, c.bob_strength, c.previous_view_z, c.previous_view_angle, c.sector_id,
    c.pain_face_tics,
    CASE WHEN k.ntic IS NULL THEN c.armor ELSE c.armor - k.saved END AS armor,
    CASE WHEN k.ntic IS NOT NULL AND c.armor - k.saved <= 0 THEN 0 ELSE c.armor_class END AS armor_class,
    c.backpack, c.ammo_bullets, c.ammo_shells, c.ammo_rockets, c.ammo_cells,
    c.key_blue, c.key_yellow, c.key_red, c.radsuit_tics, c.invis_tics, c.momentum_z,
    c.damage_count, c.bonus_count, c.light_amp_tics, c.power_map, c.god_mode, c.noclip, c.invuln_tics,
    c.berserk, c.message, c.message_tics, c.frags, c.death_tics,
    CASE WHEN k.ntic IS NOT NULL AND (c.health - (10 - k.saved)) <= 0 THEN -1 ELSE c.killer_id END AS killer_id,
    c.sprite_frame, c.t_x, c.t_y, c.t_z, c.t_angle, c.last_mode,
    c.c_level_tics,
    CASE WHEN k.ntic IS NULL THEN c.c_pain_face_tics ELSE 12 END AS c_pain_face_tics,
    c.c_radsuit_tics, c.c_invis_tics, c.c_light_amp_tics, c.c_invuln_tics, c.c_message_tics, c.c_message,
    CASE WHEN k.ntic IS NULL THEN c.c_damage_count ELSE LEAST(100, c.c_damage_count + (10 - k.saved)) END AS c_damage_count,
    c.c_bonus_count
  FROM clocked_t c
  LEFT JOIN (
    SELECT DISTINCT k.ntic,
           LEAST(c2.armor, CASE c2.armor_class WHEN 2 THEN 5 WHEN 1 THEN 3 ELSE 0 END) AS saved
    FROM crushing k
    JOIN clocked_t c2 ON c2.ntic = k.ntic AND c2.sector_id = k.sector_id
    WHERE k.gap < 56 AND c2.alive AND NOT c2.god_mode AND c2.invuln_tics <= 0
  ) k ON k.ntic = c.ntic
),
