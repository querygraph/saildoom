-- One 35 Hz game tic of SQLDoom, in Spark SQL: the player's part, after
-- tic_doors.sql (clock, use, specials, movers) and before the outputs.
--
-- Ported from cedardb/sqldoom sql/runtime/functions: 14_cs_movement_mode
-- (which movement runs), 16_cs_turn (turning in place), 15_cs_move
-- (P_MovePlayer, P_TryMove, P_ZMovement, the view bob), 02_geometry's
-- doom_sector_at and 18_cs_cross (the player's line crossings). Sectors and
-- movers come from tic_doors (S2, M2); the stages not ported yet (monsters,
-- pickups ...) are read from the recorded run: rec_things and rec_thing_health
-- at tic t, as SQLDoom's tic order sees them when the player moves.
--
-- player_state and things store positions, angles and momenta as `real`;
-- values are computed in double and stored through CAST(... AS FLOAT), as the
-- original's UPDATEs round them.
movers AS (
  SELECT DISTINCT ntic, TRUE AS active FROM M2 WHERE direction <> 2
),
moded AS (
  SELECT c.*,
    CAST(g.move_fwd AS DOUBLE) AS move_fwd, CAST(g.move_strafe AS DOUBLE) AS move_side,
    g.running, CAST(g.turn_degrees AS DOUBLE) AS turn_degrees, g.skill_bit,
    CASE
      WHEN NOT c.alive THEN 'idle'
      WHEN ABS(g.move_fwd) > 0 OR ABS(g.move_strafe) > 0
        OR ABS(c.momentum_x) > 1e-7D OR ABS(c.momentum_y) > 1e-7D
        OR ABS(c.momentum_z) > 1e-7D
        OR c.bob_strength > 1e-7D
        OR ABS(c.view_z - c.base_z) > 1e-7D
        OR mv.active IS NOT NULL
        THEN 'full'
      WHEN ABS(g.turn_degrees) > 1e-7D THEN 'turn'
      ELSE 'idle'
    END AS mode
  FROM clocked c
  JOIN cmd g ON g.tic = c.ntic
  LEFT JOIN movers mv ON mv.ntic = c.ntic
),
-- ---------------------------------------------------------------- 15_cs_move
current_pose AS (
  SELECT m.ntic, m.move_fwd, m.move_side, m.noclip, m.skill_bit,
         CAST(m.t_x AS DOUBLE) AS px, CAST(m.t_y AS DOUBLE) AS py,
         CAST(m.t_angle AS DOUBLE) AS old_angle,
         CAST(m.momentum_x AS DOUBLE) AS old_mom_x,
         CAST(m.momentum_y AS DOUBLE) AS old_mom_y,
         CAST(m.momentum_z AS DOUBLE) AS old_mom_z,
         CAST(m.base_z - ${VIEWHEIGHT} AS DOUBLE) AS feet_z,
         (m.momentum_z = 0) AS on_ground,
         m.c_level_tics AS level_tics,
         CASE WHEN m.running THEN ${FORWARDMOVE_RUN} ELSE ${FORWARDMOVE} END * ${THRUST_UNIT} AS forward_thrust,
         CASE WHEN m.running THEN ${SIDEMOVE_RUN} ELSE ${SIDEMOVE} END * ${THRUST_UNIT} AS side_thrust,
         m.turn_degrees
  FROM moded m
  WHERE m.mode = 'full'
),
turned AS (
  SELECT c.*,
         (c.old_angle - c.turn_degrees)
           - 360.0D * FLOOR((c.old_angle - c.turn_degrees) / 360.0D) AS new_angle
  FROM current_pose c
),
thrusted AS (
  SELECT t.*,
    LEAST(${MAXMOVE}, GREATEST(-${MAXMOVE},
      t.old_mom_x
      + CASE WHEN t.on_ground THEN
          t.move_fwd * t.forward_thrust * COS(RADIANS(t.new_angle))
          + t.move_side * t.side_thrust * SIN(RADIANS(t.new_angle))
        ELSE 0.0D END)) AS raw_mom_x,
    LEAST(${MAXMOVE}, GREATEST(-${MAXMOVE},
      t.old_mom_y
      + CASE WHEN t.on_ground THEN
          t.move_fwd * t.forward_thrust * SIN(RADIANS(t.new_angle))
          - t.move_side * t.side_thrust * COS(RADIANS(t.new_angle))
        ELSE 0.0D END)) AS raw_mom_y
  FROM turned t
),
reach AS (
  -- The box every candidate position lies in, per tic (P_BlockLinesIterator's
  -- blockmap cells, bounded the way the original bounds them).
  SELECT ntic, px, py, raw_mom_x, raw_mom_y, feet_z, skill_bit,
         GREATEST(px, px + raw_mom_x) AS hi_x, LEAST(px, px + raw_mom_x) AS lo_x,
         GREATEST(py, py + raw_mom_y) AS hi_y, LEAST(py, py + raw_mom_y) AS lo_y
  FROM thrusted
),
blocking AS (
  SELECT r.ntic, CAST(lg.x1 AS DOUBLE) AS x1, CAST(lg.y1 AS DOUBLE) AS y1,
         CAST(lg.x2 AS DOUBLE) AS x2, CAST(lg.y2 AS DOUBLE) AS y2
  FROM reach r
  JOIN linedef_geom lg ON lg.map_id = ${map_id}
  LEFT JOIN S2 sf ON sf.ntic = r.ntic AND sf.id = lg.fsec
  LEFT JOIN S2 sb ON sb.ntic = r.ntic AND sb.id = lg.bsec
  WHERE LEAST(lg.x1, lg.x2) <= r.hi_x + ${PLAYER_RADIUS} + 2.0D
    AND GREATEST(lg.x1, lg.x2) >= r.lo_x - ${PLAYER_RADIUS} - 2.0D
    AND LEAST(lg.y1, lg.y2) <= r.hi_y + ${PLAYER_RADIUS} + 2.0D
    AND GREATEST(lg.y1, lg.y2) >= r.lo_y - ${PLAYER_RADIUS} - 2.0D
    AND (lg.left_sd_id = -1 OR lg.right_sd_id = -1 OR (lg.flags & 1) <> 0
      OR (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
          AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
          AND LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)
              < ${PLAYER_HEIGHT})
      OR (sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
          AND GREATEST(sb.floor_height, sf.floor_height) > r.feet_z + ${MAXSTEP}))
),
blocking_things AS (
  SELECT r.ntic, CAST(tt.x AS DOUBLE) AS tx, CAST(tt.y AS DOUBLE) AS ty,
         CAST(COALESCE(cd.radius, bd.radius) + ${PLAYER_RADIUS} AS DOUBLE) AS blockdist
  FROM reach r
  JOIN rec_things tt ON tt.tic = r.ntic - 1 AND tt.map_id = ${map_id}
  LEFT JOIN thing_combat_defs cd ON cd.thing_type = tt.type
  LEFT JOIN rec_thing_health hh ON hh.tic = r.ntic - 1 AND hh.map_id = tt.map_id AND hh.thing_id = tt.id
  LEFT JOIN thing_blocking_defs bd ON bd.thing_type = tt.type
  WHERE tt.id <> ${player}
    AND ((cd.thing_type IS NOT NULL AND hh.alive)
         OR (bd.thing_type IS NOT NULL AND (tt.flags & 16) = 0 AND (tt.flags & r.skill_bit) <> 0))
    AND tt.x <= r.hi_x + COALESCE(cd.radius, bd.radius) + ${PLAYER_RADIUS} + ${BLOCK_MARGIN}
    AND tt.x >= r.lo_x - COALESCE(cd.radius, bd.radius) - ${PLAYER_RADIUS} - ${BLOCK_MARGIN}
    AND tt.y <= r.hi_y + COALESCE(cd.radius, bd.radius) + ${PLAYER_RADIUS} + ${BLOCK_MARGIN}
    AND tt.y >= r.lo_y - COALESCE(cd.radius, bd.radius) - ${PLAYER_RADIUS} - ${BLOCK_MARGIN}
),
candidates AS (
  SELECT t.ntic, t.px, t.py, t.noclip, t.c0.pri AS pri, t.c0.cx AS cx, t.c0.cy AS cy
  FROM (
    SELECT th.*, explode(array(
      named_struct('pri', 1, 'cx', th.px + th.raw_mom_x, 'cy', th.py + th.raw_mom_y),
      named_struct('pri', 2, 'cx', th.px + th.raw_mom_x, 'cy', th.py),
      named_struct('pri', 3, 'cx', th.px, 'cy', th.py + th.raw_mom_y),
      named_struct('pri', 4, 'cx', th.px, 'cy', th.py))) AS c0
    FROM thrusted th
  ) t
),
line_tests AS (
  -- Per candidate and blocking line: the distance from the candidate to the
  -- line, the distance from the current position, and whether the move
  -- crosses the line.
  SELECT q.ntic, q.pri, q.noclip,
    SQRT(POWER(q.cx - (q.x1 + q.t * (q.x2 - q.x1)), 2)
       + POWER(q.cy - (q.y1 + q.t * (q.y2 - q.y1)), 2)) AS dist,
    SQRT(POWER(q.px - (q.x1 + q.t0 * (q.x2 - q.x1)), 2)
       + POWER(q.py - (q.y1 + q.t0 * (q.y2 - q.y1)), 2)) AS dist0,
    ((q.px - q.x1) * (q.y2 - q.y1) - (q.py - q.y1) * (q.x2 - q.x1))
      * ((q.cx - q.x1) * (q.y2 - q.y1) - (q.cy - q.y1) * (q.x2 - q.x1)) < 0
    AND ((q.x1 - q.px) * (q.cy - q.py) - (q.y1 - q.py) * (q.cx - q.px))
      * ((q.x2 - q.px) * (q.cy - q.py) - (q.y2 - q.py) * (q.cx - q.px)) < 0 AS intersects
  FROM (
    SELECT c.ntic, c.pri, c.cx, c.cy, c.px, c.py, c.noclip, b.x1, b.y1, b.x2, b.y2,
      LEAST(1.0D, GREATEST(0.0D,
        ((c.cx - b.x1) * (b.x2 - b.x1) + (c.cy - b.y1) * (b.y2 - b.y1))
        / NULLIF(POWER(b.x2 - b.x1, 2) + POWER(b.y2 - b.y1, 2), 0.0D))) AS t,
      LEAST(1.0D, GREATEST(0.0D,
        ((c.px - b.x1) * (b.x2 - b.x1) + (c.py - b.y1) * (b.y2 - b.y1))
        / NULLIF(POWER(b.x2 - b.x1, 2) + POWER(b.y2 - b.y1, 2), 0.0D))) AS t0
    FROM candidates c
    JOIN blocking b ON b.ntic = c.ntic
  ) q
),
candidate_blocked AS (
  SELECT c.ntic, c.pri, c.cx, c.cy,
    (COALESCE(lb.blocked, FALSE) OR COALESCE(tb.blocked, FALSE)) AND NOT c.noclip AS blocked
  FROM candidates c
  LEFT JOIN (
    SELECT ntic, pri, bool_or((dist < ${PLAYER_RADIUS} AND dist < dist0) OR intersects) AS blocked
    FROM line_tests GROUP BY ntic, pri
  ) lb ON lb.ntic = c.ntic AND lb.pri = c.pri
  LEFT JOIN (
    SELECT c2.ntic, c2.pri,
           bool_or(ABS(c2.cx - bt.tx) < bt.blockdist AND ABS(c2.cy - bt.ty) < bt.blockdist) AS blocked
    FROM candidates c2 JOIN blocking_things bt ON bt.ntic = c2.ntic
    GROUP BY c2.ntic, c2.pri
  ) tb ON tb.ntic = c.ntic AND tb.pri = c.pri
),
best_pos AS (
  SELECT ntic, min_by(cx, pri) AS cx, min_by(cy, pri) AS cy
  FROM candidate_blocked WHERE NOT blocked
  GROUP BY ntic
),
-- 02_geometry doom_sector_at: the subsector the BSP descent reaches is the one
-- whose recorded path takes the point's side at every node.
leaf AS (
  SELECT bp.ntic, st.ssector_id
  FROM best_pos bp
  JOIN node_path_steps st ON st.map_id = ${map_id}
  JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
  GROUP BY bp.ntic, st.ssector_id
  HAVING bool_and(st.side = CASE
    WHEN (bp.cx - n.x) * CAST(n.dy AS DOUBLE) - (bp.cy - n.y) * CAST(n.dx AS DOUBLE) > 0
    THEN 'R' ELSE 'L' END)
),
sector_floor AS (
  SELECT l.ntic, s.id AS sector_id, s.floor_height
  FROM (
    SELECT l.ntic, min_by(rs.fsec, rs.seg_id) AS fsec
    FROM leaf l JOIN render_segs rs ON rs.map_id = ${map_id} AND rs.ssector_id = l.ssector_id
    GROUP BY l.ntic
  ) l
  JOIN S2 s ON s.ntic = l.ntic AND s.id = l.fsec
),
resolved AS (
  SELECT t.*, bp.cx, bp.cy, sf.sector_id,
    CASE WHEN t.feet_z + t.old_mom_z <= sf.floor_height THEN CAST(sf.floor_height AS DOUBLE)
         ELSE t.feet_z + t.old_mom_z END + ${VIEWHEIGHT} AS new_base_z,
    CASE WHEN t.feet_z + t.old_mom_z <= sf.floor_height THEN 0.0D
         WHEN t.old_mom_z = 0.0D THEN -2.0D * ${GRAVITY}
         ELSE t.old_mom_z - ${GRAVITY} END AS next_mom_z,
    LEAST((POWER(t.raw_mom_x, 2) + POWER(t.raw_mom_y, 2)) / ${BOB_FACTOR}, ${MAXBOB}) AS new_bob,
    CASE WHEN ABS(bp.cx - (t.px + t.raw_mom_x)) < ${POS_EPSILON} THEN t.raw_mom_x ELSE 0.0D END AS slide_mom_x,
    CASE WHEN ABS(bp.cy - (t.py + t.raw_mom_y)) < ${POS_EPSILON} THEN t.raw_mom_y ELSE 0.0D END AS slide_mom_y
  FROM thrusted t
  JOIN best_pos bp ON bp.ntic = t.ntic
  JOIN sector_floor sf ON sf.ntic = t.ntic
),
motion AS (
  SELECT r.ntic, r.px, r.py, r.cx, r.cy, r.new_angle, r.new_base_z, r.next_mom_z,
         r.new_bob, r.sector_id,
         (r.new_bob / 2.0D) * SIN(2.0D * PI() * r.level_tics / ${BOB_PERIOD_TICS}) AS bob_offset,
    CASE WHEN NOT r.on_ground THEN r.slide_mom_x
         WHEN r.move_fwd = 0 AND r.move_side = 0
          AND ABS(r.slide_mom_x) < ${STOPSPEED} AND ABS(r.slide_mom_y) < ${STOPSPEED} THEN 0.0D
         ELSE r.slide_mom_x * ${FRICTION} END AS next_mom_x,
    CASE WHEN NOT r.on_ground THEN r.slide_mom_y
         WHEN r.move_fwd = 0 AND r.move_side = 0
          AND ABS(r.slide_mom_x) < ${STOPSPEED} AND ABS(r.slide_mom_y) < ${STOPSPEED} THEN 0.0D
         ELSE r.slide_mom_y * ${FRICTION} END AS next_mom_y
  FROM resolved r
),
-- ---------------------------------------------------------------- the row
stepped AS (
  SELECT m.*,
    -- turning in place (16_cs_turn)
    CAST((CAST(m.t_angle AS DOUBLE) - m.turn_degrees)
         - 360.0D * FLOOR((CAST(m.t_angle AS DOUBLE) - m.turn_degrees) / 360.0D) AS FLOAT) AS turn_angle,
    mo.ntic IS NOT NULL AS moved,
    mo.px AS mo_px, mo.py AS mo_py, mo.cx AS mo_cx, mo.cy AS mo_cy,
    mo.new_angle AS mo_angle, mo.new_base_z AS mo_base_z, mo.bob_offset AS mo_bob_offset,
    mo.next_mom_x AS mo_mom_x, mo.next_mom_y AS mo_mom_y, mo.next_mom_z AS mo_mom_z,
    mo.new_bob AS mo_bob, mo.sector_id AS mo_sector_id
  FROM moded m
  LEFT JOIN motion mo ON mo.ntic = m.ntic
),
next_player AS (
  SELECT
    s.ntic AS tic, s.map_id, s.player_thing_id, s.health, s.alive,
    s.c_level_tics AS level_tics,
    CASE s.mode
      WHEN 'idle' THEN s.position_x
      WHEN 'turn' THEN s.t_x
      ELSE CASE WHEN s.moved THEN CAST(s.mo_px AS FLOAT) ELSE s.previous_x END END AS previous_x,
    CASE s.mode
      WHEN 'idle' THEN s.position_y
      WHEN 'turn' THEN s.t_y
      ELSE CASE WHEN s.moved THEN CAST(s.mo_py AS FLOAT) ELSE s.previous_y END END AS previous_y,
    CASE s.mode
      WHEN 'turn' THEN s.t_x
      WHEN 'full' THEN CASE WHEN s.moved THEN CAST(s.mo_cx AS FLOAT) ELSE s.position_x END
      ELSE s.position_x END AS position_x,
    CASE s.mode
      WHEN 'turn' THEN s.t_y
      WHEN 'full' THEN CASE WHEN s.moved THEN CAST(s.mo_cy AS FLOAT) ELSE s.position_y END
      ELSE s.position_y END AS position_y,
    CASE WHEN s.mode = 'full' AND s.moved THEN CAST(s.mo_base_z AS FLOAT) ELSE s.base_z END AS base_z,
    CASE s.mode
      WHEN 'idle' THEN CASE WHEN s.alive THEN s.base_z ELSE s.view_z END
      WHEN 'turn' THEN s.base_z
      ELSE CASE WHEN s.moved
                THEN CAST(s.mo_base_z + s.mo_bob_offset AS FLOAT)
                ELSE s.view_z END END AS view_z,
    CASE s.mode
      WHEN 'turn' THEN s.turn_angle
      WHEN 'full' THEN CASE WHEN s.moved THEN CAST(s.mo_angle AS FLOAT) ELSE s.view_angle END
      ELSE s.view_angle END AS view_angle,
    CASE s.mode
      WHEN 'full' THEN CASE WHEN s.moved THEN CAST(s.mo_mom_x AS FLOAT) ELSE s.momentum_x END
      ELSE CAST(0 AS FLOAT) END AS momentum_x,
    CASE s.mode
      WHEN 'full' THEN CASE WHEN s.moved THEN CAST(s.mo_mom_y AS FLOAT) ELSE s.momentum_y END
      ELSE CAST(0 AS FLOAT) END AS momentum_y,
    CASE s.mode
      WHEN 'full' THEN CASE WHEN s.moved THEN CAST(s.mo_bob AS FLOAT) ELSE s.bob_strength END
      ELSE CAST(0 AS FLOAT) END AS bob_strength,
    CASE s.mode
      WHEN 'idle' THEN CASE WHEN s.alive THEN s.base_z ELSE s.view_z END
      ELSE CASE WHEN s.mode = 'full' AND NOT s.moved THEN s.previous_view_z ELSE s.view_z END END
      AS previous_view_z,
    CASE WHEN s.mode = 'full' AND NOT s.moved THEN s.previous_view_angle ELSE s.view_angle END
      AS previous_view_angle,
    CASE WHEN s.mode = 'full' AND s.moved THEN s.mo_sector_id ELSE s.sector_id END AS sector_id,
    s.c_pain_face_tics AS pain_face_tics, s.armor, s.armor_class, s.backpack,
    s.ammo_bullets, s.ammo_shells, s.ammo_rockets, s.ammo_cells,
    s.key_blue, s.key_yellow, s.key_red,
    s.c_radsuit_tics AS radsuit_tics, s.c_invis_tics AS invis_tics,
    CASE WHEN s.mode = 'full' AND s.moved THEN CAST(s.mo_mom_z AS FLOAT) ELSE s.momentum_z END AS momentum_z,
    s.c_damage_count AS damage_count, s.c_bonus_count AS bonus_count,
    s.c_light_amp_tics AS light_amp_tics, s.power_map, s.god_mode, s.noclip,
    s.c_invuln_tics AS invuln_tics, s.berserk, s.c_message AS message,
    s.c_message_tics AS message_tics, s.frags, s.death_tics, s.killer_id, s.sprite_frame,
    s.mode AS last_mode
  FROM stepped s
),
next_world AS (
  -- The player Thing follows the player (15_cs_move and 16_cs_turn's
  -- UPDATE things).
  SELECT n.*,
    CASE WHEN n.last_mode = 'full' AND p.moved THEN n.position_x ELSE p.t_x END AS t_x,
    CASE WHEN n.last_mode = 'full' AND p.moved THEN n.position_y ELSE p.t_y END AS t_y,
    CASE WHEN n.last_mode = 'full' AND p.moved THEN n.view_z ELSE p.t_z END AS t_z,
    CASE WHEN n.last_mode = 'turn' OR (n.last_mode = 'full' AND p.moved) THEN n.view_angle ELSE p.t_angle END AS t_angle
  FROM next_player n
  JOIN stepped p ON p.ntic = n.tic
),
-- ---------------------------------------------------------------- 18_cs_cross
cross_events AS (
  -- Runs when the player's position moved this tic (plan bit 8).
  SELECT c.ntic, ${map_id} AS map_id, c.player_thing_id, c.line_id, 'cross' AS trigger_type,
         c.from_front
  FROM (
    SELECT p.tic AS ntic, p.player_thing_id, ld.linedef_id AS line_id, d.cross_once,
      ((ld.x2 - ld.x1) * (p.oy - ld.y1) - (ld.y2 - ld.y1) * (p.ox - ld.x1)) < 0 AS from_front,
      ABS((ld.x2 - ld.x1) * (p.oy - ld.y1) - (ld.y2 - ld.y1) * (p.ox - ld.x1)) AS old_side,
      ((ld.x2 - ld.x1) * (p.ny - ld.y1) - (ld.y2 - ld.y1) * (p.nx - ld.x1)) AS new_side,
      ((p.nx - p.ox) * (ld.y1 - p.oy) - (p.ny - p.oy) * (ld.x1 - p.ox)) AS v1_side,
      ((p.nx - p.ox) * (ld.y2 - p.oy) - (p.ny - p.oy) * (ld.x2 - p.ox)) AS v2_side
    FROM (
      SELECT tic, player_thing_id,
             CAST(previous_x AS DOUBLE) AS ox, CAST(previous_y AS DOUBLE) AS oy,
             CAST(position_x AS DOUBLE) AS nx, CAST(position_y AS DOUBLE) AS ny
      FROM next_player
      WHERE ABS(position_x - previous_x) > ${POS_EPSILON} OR ABS(position_y - previous_y) > ${POS_EPSILON}
    ) p
    JOIN (SELECT linedef_id, special, CAST(x1 AS DOUBLE) AS x1, CAST(y1 AS DOUBLE) AS y1,
                 CAST(x2 AS DOUBLE) AS x2, CAST(y2 AS DOUBLE) AS y2
          FROM linedef_geom WHERE map_id = ${map_id}) ld ON TRUE
    JOIN linedefs d ON d.map_id = ${map_id} AND d.id = ld.linedef_id AND d.cross_activated
  ) c
  LEFT JOIN A1 a ON a.ntic = c.ntic AND a.line_id = c.line_id
  WHERE c.old_side > 1e-7D AND c.new_side <> 0
    AND ((c.from_front AND c.new_side > 0) OR (NOT c.from_front AND c.new_side < 0))
    AND c.v1_side * c.v2_side < 0
    AND NOT (COALESCE(c.cross_once, FALSE) AND a.line_id IS NOT NULL)
),
-- ---------------------------------------------------------------- the outputs
P_out AS (SELECT * FROM next_world),
S_out AS (SELECT * FROM S2),
M_out AS (SELECT * FROM M2),
E_out AS (
  -- The player's crossings, and the events the unported stages (monsters
  -- crossing lines ...) left queued at the end of the tic.
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM cross_events
  UNION ALL
  SELECT e.tic AS ntic, e.map_id, e.player_thing_id, e.line_id, e.trigger_type, e.from_front
  FROM rec_line_special_events e
  JOIN (SELECT DISTINCT ntic FROM P0) t ON t.ntic = e.tic
  WHERE e.map_id = ${map_id}
    AND NOT (e.player_thing_id = ${player} AND e.trigger_type IN ('cross', 'use'))
),
A_out AS (SELECT * FROM A1),
B_out AS (SELECT * FROM B2),
D_out AS (SELECT * FROM D2),
R_out AS (SELECT * FROM R2)
