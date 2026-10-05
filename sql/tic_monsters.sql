-- The monsters, sector effects and Thing physics: the rest of the tic.
-- Follows tic_projectiles.sql.
--
-- Ported from cedardb/sqldoom sql/runtime/functions: 26_cs_monsters (retarget,
-- noise, think, step, move, float, chase, attack, barrel, blast, deaths, each
-- gated by doom_cs_monster_plan), 28_cs_sector_fx and 29_cs_thing_physics.
-- 25_cs_sound is tic_sound.sql, before this file. P_NightmareRespawn
-- runs on skill 4; -respawn is the deathmatch phase's. 35_cs_boss lowers
-- E1M8's tag 666; the E2M8/E3M8 exits are the level flow's.
mo_player AS (
  SELECT p.tic AS ntic, p.player_thing_id, p.alive, p.level_tics, p.invis_tics > 0 AS shadowed,
         CAST(t.x AS DOUBLE) AS px, CAST(t.y AS DOUBLE) AS py, t.x AS fx, t.y AS fy, g.skill, g.skill_bit
  FROM P6 p
  JOIN T2 t ON t.ntic = p.tic AND t.id = p.player_thing_id
  JOIN cmd g ON g.tic = p.tic
),
mo_walls AS (
  -- What blocks sight and shots: one-sided lines and closed portals.
  SELECT s.ntic, CAST(ld.x1 AS DOUBLE) AS x1, CAST(ld.y1 AS DOUBLE) AS y1,
         CAST(ld.x2 AS DOUBLE) AS x2, CAST(ld.y2 AS DOUBLE) AS y2
  FROM (SELECT DISTINCT ntic FROM mo_player) s
  JOIN linedef_geom ld ON ld.map_id = ${map_id}
  LEFT JOIN S2 fr ON fr.ntic = s.ntic AND fr.id = ld.fsec
  LEFT JOIN S2 bk ON bk.ntic = s.ntic AND bk.id = ld.bsec
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height, bk.ceil_height) <= GREATEST(fr.floor_height, bk.floor_height)
),
-- ---------------------------------------------------------------- retarget
I3 AS (
  -- A target that died is dropped; a monster that is up takes the player.
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.sector_id,
    ai.attack_cooldown, ai.fired_this_tick,
    CASE WHEN dropped AND ai.state IN ('see', 'missile', 'pain') THEN ${player}
         WHEN dropped THEN CAST(NULL AS INT)
         WHEN ai.target_thing_id IS NULL AND ai.state IN ('see', 'missile', 'pain') THEN ${player}
         ELSE ai.target_thing_id END AS target_thing_id,
    ai.charge_tics, ai.movedir, ai.movecount
  FROM (
    SELECT a.*,
      a.target_thing_id IS NOT NULL
        AND ((a.target_thing_id = ${player} AND NOT p.alive) OR COALESCE(NOT th.alive, FALSE)) AS dropped
    FROM I2s a
    JOIN mo_player p ON p.ntic = a.ntic
    LEFT JOIN H2 th ON th.ntic = a.ntic AND th.thing_id = a.target_thing_id
  ) ai
),
-- ---------------------------------------------------------------- noise
mo_sound_edges AS (
  SELECT s.ntic, x.a, x.b, x.block
  FROM (SELECT DISTINCT w.ntic FROM W1 w JOIN mo_player p ON p.ntic = w.ntic
        WHERE w.fired_this_tick AND p.alive) s
  JOIN (SELECT ld.fsec AS a, ld.bsec AS b, CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END AS block, ld.fsec, ld.bsec
        FROM linedef_geom ld WHERE ld.map_id = ${map_id}
        UNION ALL
        SELECT ld.bsec, ld.fsec, CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END, ld.fsec, ld.bsec
        FROM linedef_geom ld WHERE ld.map_id = ${map_id}) x ON TRUE
  JOIN S2 sf ON sf.ntic = s.ntic AND sf.id = x.fsec
  JOIN S2 sb ON sb.ntic = s.ntic AND sb.id = x.bsec
  WHERE LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height) > 0
),
mo_flood AS (
  -- P_RecursiveSound: through open two-sided lines, across at most one
  -- sound-blocking line.
  SELECT p.tic AS ntic, p.sector_id, 0 AS block
  FROM P6 p
  JOIN W1 w ON w.ntic = p.tic AND w.fired_this_tick
  WHERE p.alive AND p.sector_id IS NOT NULL
  UNION
  SELECT f.ntic, e.b, f.block + e.block
  FROM mo_flood f JOIN mo_sound_edges e ON e.ntic = f.ntic AND e.a = f.sector_id
  WHERE f.block + e.block <= 1
),
I4 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    CASE WHEN w.thing_id IS NOT NULL THEN 'see' ELSE ai.state END AS state,
    CASE WHEN w.thing_id IS NOT NULL THEN 0 ELSE ai.state_tics END AS state_tics,
    CASE WHEN w.thing_id IS NOT NULL THEN 0 ELSE ai.seq_index END AS seq_index,
    ai.sector_id, ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id, ai.charge_tics,
    ai.movedir, ai.movecount
  FROM I3 ai
  LEFT JOIN (
    SELECT DISTINCT a.ntic, a.thing_id
    FROM I3 a
    JOIN T2 t ON t.ntic = a.ntic AND t.id = a.thing_id
    JOIN N1 rt ON rt.ntic = a.ntic AND rt.thing_id = a.thing_id
    JOIN mo_flood fl ON fl.ntic = a.ntic AND fl.sector_id = COALESCE(a.sector_id, rt.sector_id)
    LEFT ANTI JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
    WHERE a.state = 'stand'
  ) w ON w.ntic = ai.ntic AND w.thing_id = ai.thing_id
),
-- ---------------------------------------------------------------- think
mo_target AS (
  -- Where each monster's target is: a live target Thing, else the player.
  SELECT ai.ntic, ai.thing_id,
         COALESCE(CAST(tt.x AS DOUBLE), p.px) AS tx, COALESCE(CAST(tt.y AS DOUBLE), p.py) AS ty
  FROM I4 ai
  JOIN mo_player p ON p.ntic = ai.ntic
  LEFT JOIN (SELECT ntic, thing_id FROM H2 WHERE alive
             UNION ALL SELECT tic, player_thing_id FROM P6 WHERE alive) th
    ON th.ntic = ai.ntic AND th.thing_id = ai.target_thing_id
  LEFT JOIN T2 tt ON tt.ntic = ai.ntic AND tt.id = th.thing_id
),
mo_monsters AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.attack_cooldown,
         t.type, CAST(t.x AS DOUBLE) AS mx, CAST(t.y AS DOUBLE) AS my, CAST(t.angle AS DOUBLE) AS facing,
         h.alive, h.health, h.max_health, cd.xdeath_frame, COALESCE(cd.explodes, FALSE) AS explodes,
         CAST(COALESCE(cd.attack_range, ${DEFAULT_ATTACK_RANGE}) AS DOUBLE) AS attack_range,
         mt.tx, mt.ty
  FROM I4 ai
  JOIN T2 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
  JOIN H2 h ON h.ntic = ai.ntic AND h.thing_id = ai.thing_id
  LEFT JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN mo_target mt ON mt.ntic = ai.ntic AND mt.thing_id = ai.thing_id
  WHERE h.alive OR ai.state <> 'dead'
),
mo_los AS (
  SELECT m.ntic, m.thing_id,
    COALESCE(n.visible, FALSE) AS visible, COALESCE(n.in_view_cone, FALSE) AS in_view_cone,
    SQRT(POWER(m.mx - m.tx, 2) + POWER(m.my - m.ty, 2)) AS dist
  FROM mo_monsters m
  LEFT JOIN (
    SELECT nm.ntic, nm.thing_id,
      NOT COALESCE(bw.blocked, FALSE) AS visible,
      (COS(RADIANS(nm.facing)) * (nm.tx - nm.mx) + SIN(RADIANS(nm.facing)) * (nm.ty - nm.my)) > 0 AS in_view_cone
    FROM mo_monsters nm
    LEFT JOIN (
      SELECT q.ntic, q.thing_id, bool_or(q.d1 * q.d2 < 0 AND q.d3 * q.d4 < 0) AS blocked
      FROM (
        SELECT nm2.ntic, nm2.thing_id,
          (nm2.mx - b.x1) * (b.y2 - b.y1) - (nm2.my - b.y1) * (b.x2 - b.x1) AS d1,
          (nm2.tx - b.x1) * (b.y2 - b.y1) - (nm2.ty - b.y1) * (b.x2 - b.x1) AS d2,
          (b.x1 - nm2.mx) * (nm2.ty - nm2.my) - (b.y1 - nm2.my) * (nm2.tx - nm2.mx) AS d3,
          (b.x2 - nm2.mx) * (nm2.ty - nm2.my) - (b.y2 - nm2.my) * (nm2.tx - nm2.mx) AS d4
        FROM mo_monsters nm2
        JOIN mo_walls b ON b.ntic = nm2.ntic
          AND LEAST(b.x1, b.x2) <= GREATEST(nm2.mx, nm2.tx) AND GREATEST(b.x1, b.x2) >= LEAST(nm2.mx, nm2.tx)
          AND LEAST(b.y1, b.y2) <= GREATEST(nm2.my, nm2.ty) AND GREATEST(b.y1, b.y2) >= LEAST(nm2.my, nm2.ty)
        WHERE POWER(nm2.mx - nm2.tx, 2) + POWER(nm2.my - nm2.ty, 2) <= ${SIGHT_RANGE} * ${SIGHT_RANGE}
      ) q
      GROUP BY q.ntic, q.thing_id
    ) bw ON bw.ntic = nm.ntic AND bw.thing_id = nm.thing_id
    WHERE POWER(nm.mx - nm.tx, 2) + POWER(nm.my - nm.ty, 2) <= ${SIGHT_RANGE} * ${SIGHT_RANGE}
  ) n ON n.ntic = m.ntic AND n.thing_id = m.thing_id
),
mo_max_seq AS (
  SELECT thing_type, state, MAX(seq_index) AS max_idx FROM thing_ai_frames GROUP BY thing_type, state
),
mo_transitions AS (
  SELECT d.*,
    d.state_tics <= 1 OR (NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath')) AS advances,
    CASE
      WHEN NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath') THEN
        CASE WHEN d.health < -d.max_health AND d.xdeath_frame IS NOT NULL THEN 'xdeath' ELSE 'die' END
      WHEN d.state = 'die' THEN
        CASE WHEN d.state_tics > 1 THEN 'die' WHEN d.seq_index >= d.die_max THEN 'dead' ELSE 'die' END
      WHEN d.state = 'xdeath' THEN
        CASE WHEN d.state_tics > 1 THEN 'xdeath' WHEN d.seq_index >= d.xdeath_max THEN 'dead' ELSE 'xdeath' END
      WHEN d.explodes THEN 'stand'
      WHEN d.state = 'stand' THEN
        CASE WHEN d.visible AND d.in_view_cone AND d.dist <= ${SIGHT_RANGE} THEN 'see' ELSE 'stand' END
      WHEN d.state_tics > 1 THEN d.state
      WHEN d.state = 'see' THEN
        CASE WHEN d.visible AND d.dist <= d.attack_range AND d.attack_cooldown <= 0 THEN 'missile' ELSE 'see' END
      WHEN d.state = 'missile' THEN CASE WHEN d.seq_index >= d.missile_max THEN 'see' ELSE 'missile' END
      WHEN d.state = 'pain' THEN CASE WHEN d.seq_index >= d.pain_max THEN 'see' ELSE 'pain' END
      ELSE d.state
    END AS next_state,
    CASE
      WHEN NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath') THEN 0
      WHEN d.state = 'die' THEN
        CASE WHEN d.state_tics > 1 THEN d.seq_index WHEN d.seq_index >= d.die_max THEN 0 ELSE d.seq_index + 1 END
      WHEN d.state = 'xdeath' THEN
        CASE WHEN d.state_tics > 1 THEN d.seq_index WHEN d.seq_index >= d.xdeath_max THEN 0 ELSE d.seq_index + 1 END
      WHEN d.explodes THEN 0
      WHEN d.state = 'stand' THEN 0
      WHEN d.state_tics > 1 THEN d.seq_index
      WHEN d.state = 'see' THEN
        CASE WHEN d.visible AND d.dist <= d.attack_range AND d.attack_cooldown <= 0 THEN 0
             WHEN d.seq_index >= d.see_max THEN 0 ELSE d.seq_index + 1 END
      WHEN d.state = 'missile' THEN CASE WHEN d.seq_index >= d.missile_max THEN 0 ELSE d.seq_index + 1 END
      WHEN d.state = 'pain' THEN CASE WHEN d.seq_index >= d.pain_max THEN 0 ELSE d.seq_index + 1 END
      ELSE d.seq_index
    END AS next_seq
  FROM (
    SELECT m.*, l.visible, l.in_view_cone, l.dist,
           ms.max_idx AS see_max, mm.max_idx AS missile_max, mp.max_idx AS pain_max,
           md.max_idx AS die_max, mx.max_idx AS xdeath_max
    FROM mo_monsters m
    JOIN mo_los l ON l.ntic = m.ntic AND l.thing_id = m.thing_id
    LEFT JOIN mo_max_seq ms ON ms.thing_type = m.type AND ms.state = 'see'
    LEFT JOIN mo_max_seq mm ON mm.thing_type = m.type AND mm.state = 'missile'
    LEFT JOIN mo_max_seq mp ON mp.thing_type = m.type AND mp.state = 'pain'
    LEFT JOIN mo_max_seq md ON md.thing_type = m.type AND md.state = 'die'
    LEFT JOIN mo_max_seq mx ON mx.thing_type = m.type AND mx.state = 'xdeath'
  ) d
),
mo_next AS (
  SELECT t.ntic, t.thing_id, t.next_state, t.next_seq,
    CASE WHEN NOT t.advances THEN t.state_tics - 1
         WHEN t.next_state = 'stand' THEN -1
         WHEN cd.fast_on_nightmare AND t.next_state IN ('see', 'missile', 'pain') AND p.skill = 4
           THEN GREATEST(1, COALESCE(f.tics, -1) >> 1)
         ELSE COALESCE(f.tics, -1) END AS next_tics,
    CASE WHEN t.state = 'missile' AND t.next_state = 'see' THEN 30
         ELSE GREATEST(0, t.attack_cooldown - 1) END AS next_cooldown,
    t.advances AND COALESCE(f.is_attack_frame, FALSE) AS fires
  FROM mo_transitions t
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN mo_player p ON p.ntic = t.ntic
  LEFT JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = t.next_state AND f.seq_index = t.next_seq
),
I5 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    COALESCE(n.next_state, ai.state) AS state,
    COALESCE(n.next_tics, ai.state_tics) AS state_tics,
    COALESCE(n.next_seq, ai.seq_index) AS seq_index,
    ai.sector_id,
    COALESCE(n.next_cooldown, ai.attack_cooldown) AS attack_cooldown,
    COALESCE(n.fires, ai.fired_this_tick) AS fired_this_tick,
    ai.target_thing_id, ai.charge_tics, ai.movedir, ai.movecount
  FROM I4 ai LEFT JOIN mo_next n ON n.ntic = ai.ntic AND n.thing_id = ai.thing_id
),
mo_plan AS (
  -- doom_cs_monster_plan, asked again after the think stage.
  SELECT p.ntic,
    COALESCE(st.due, FALSE) AS stepping_due, COALESCE(fl.due, FALSE) AS floater_due,
    COALESCE(ch.due, FALSE) AS chasing_due, COALESCE(at.due, FALSE) AS attacking_due,
    COALESCE(br.due, FALSE) AS barrel_due, COALESCE(rk.due, FALSE) AS rocket_due
  FROM (SELECT DISTINCT ntic FROM mo_player) p
  LEFT JOIN (SELECT ai.ntic, TRUE AS due FROM I5 ai
             JOIN T2 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
             JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = 'see' AND f.seq_index = ai.seq_index
             JOIN thing_combat_defs cd ON cd.thing_type = t.type AND NOT cd.explodes
             WHERE ai.state = 'see' AND (ai.state_tics = f.tics OR ai.state_tics = CAST(FLOOR(f.tics / 2.0D) AS INT))
             GROUP BY ai.ntic) st ON st.ntic = p.ntic
  LEFT JOIN (SELECT ai.ntic, TRUE AS due FROM I5 ai
             JOIN T2 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
             JOIN thing_combat_defs d ON d.thing_type = t.type
             WHERE d.floats AND ai.state IN ('see', 'missile') GROUP BY ai.ntic) fl ON fl.ntic = p.ntic
  LEFT JOIN (SELECT ntic, TRUE AS due FROM I5 WHERE state = 'see' GROUP BY ntic) ch ON ch.ntic = p.ntic
  LEFT JOIN (SELECT ntic, TRUE AS due FROM I5 WHERE fired_this_tick GROUP BY ntic) at ON at.ntic = p.ntic
  LEFT JOIN (SELECT ai.ntic, TRUE AS due FROM I5 ai
             JOIN T2 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
             JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
             WHERE ai.fired_this_tick GROUP BY ai.ntic) br ON br.ntic = p.ntic
  LEFT JOIN (SELECT ntic, TRUE AS due FROM projectile_impacts WHERE projectile_type = 'rocket'
             GROUP BY ntic) rk ON rk.ntic = p.ntic
),
-- ---------------------------------------------------------------- step (A_Chase's P_NewChaseDir, P_TryMove)
mo_walk AS (
  SELECT c.ntic, c.thing_id, c.mx, c.my, c.radius, c.floats, c.movedir, c.movecount,
    od.opposite AS turnaround,
    CASE WHEN c.tx - c.mx > ${CHASE_AXIS_DEADBAND} THEN 0 WHEN c.tx - c.mx < -${CHASE_AXIS_DEADBAND} THEN 4 END AS dx_dir,
    CASE WHEN c.ty - c.my < -${CHASE_AXIS_DEADBAND} THEN 6 WHEN c.ty - c.my > ${CHASE_AXIS_DEADBAND} THEN 2 END AS dy_dir,
    dg.dir AS diag,
    (PRANDOM(c.thing_id, c.level_tics, 50) > ${CHASE_SWAP_CHANCE} OR ABS(c.ty - c.my) > ABS(c.tx - c.mx)) AS swap,
    (PRANDOM(c.thing_id, c.level_tics, 51) & 1) = 1 AS sweep_up,
    PRANDOM(c.thing_id, c.level_tics, 52) & ${CHASE_MOVECOUNT_MASK} AS fresh_movecount,
    (c.movecount > 0 AND c.movedir IS NOT NULL) AS keep_going
  FROM (
    SELECT ai.ntic, ai.thing_id, CAST(t.x AS DOUBLE) AS mx, CAST(t.y AS DOUBLE) AS my,
           CAST(d.radius AS DOUBLE) AS radius, d.floats, ai.movedir, ai.movecount,
           mt.tx, mt.ty, p.level_tics
    FROM I5 ai
    JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.stepping_due
    JOIN mo_player p ON p.ntic = ai.ntic
    JOIN T2 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type
    JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = 'see' AND f.seq_index = ai.seq_index
    JOIN mo_target mt ON mt.ntic = ai.ntic AND mt.thing_id = ai.thing_id
    WHERE ai.state = 'see' AND NOT d.explodes
      AND (ai.state_tics = f.tics OR ai.state_tics = CAST(FLOOR(f.tics / 2.0D) AS INT))
  ) c
  LEFT JOIN chase_dir_defs od ON od.dir = c.movedir
  JOIN chase_dir_defs dg ON dg.is_diagonal
   AND (dg.dx > 0) = (c.tx - c.mx > 0) AND (dg.dy > 0) = (c.ty - c.my >= 0)
),
mo_desired AS (
  SELECT r.ntic, r.pri, w.thing_id, w.mx, w.my, w.radius, w.floats,
    w.mx + ${MONSTER_STEP} * d.dx AS cx, w.my + ${MONSTER_STEP} * d.dy AS cy,
    d.angle AS face_angle, d.dir,
    CASE WHEN r.pri = -1 THEN w.movecount - 1 ELSE w.fresh_movecount END AS next_movecount
  FROM (
    SELECT w.ntic, w.thing_id, d.dir,
      LEAST(
        CASE WHEN w.keep_going AND d.dir = w.movedir THEN -1 ELSE 99 END,
        CASE WHEN w.dx_dir IS NOT NULL AND w.dy_dir IS NOT NULL AND d.dir = w.diag
              AND (w.turnaround IS NULL OR w.diag <> w.turnaround) THEN 0 ELSE 99 END,
        CASE WHEN d.dir = (CASE WHEN w.swap THEN w.dy_dir ELSE w.dx_dir END)
              AND (w.turnaround IS NULL OR d.dir <> w.turnaround) THEN 1 ELSE 99 END,
        CASE WHEN d.dir = (CASE WHEN w.swap THEN w.dx_dir ELSE w.dy_dir END)
              AND (w.turnaround IS NULL OR d.dir <> w.turnaround) THEN 2 ELSE 99 END,
        CASE WHEN d.dir = w.movedir THEN 3 ELSE 99 END,
        CASE WHEN w.turnaround IS NULL OR d.dir <> w.turnaround
             THEN 4 + CASE WHEN w.sweep_up THEN d.dir ELSE 7 - d.dir END ELSE 99 END,
        CASE WHEN d.dir = w.turnaround THEN 12 ELSE 99 END
      ) AS pri
    FROM mo_walk w CROSS JOIN chase_dir_defs d
  ) r
  JOIN mo_walk w ON w.ntic = r.ntic AND w.thing_id = r.thing_id
  JOIN chase_dir_defs d ON d.dir = r.dir
  WHERE r.pri < 99
),
mo_blocking AS (
  SELECT s.ntic, CAST(ld.x1 AS DOUBLE) AS x1, CAST(ld.y1 AS DOUBLE) AS y1,
         CAST(ld.x2 AS DOUBLE) AS x2, CAST(ld.y2 AS DOUBLE) AS y2,
         (NOT (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0)
          AND NOT (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
                   AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
                   AND LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height) < ${MIN_WALK_OPENING}))
           AS floor_step_only
  FROM (SELECT DISTINCT ntic FROM mo_walk) s
  JOIN linedef_geom ld ON ld.map_id = ${map_id}
  LEFT JOIN S2 sf ON sf.ntic = s.ntic AND sf.id = ld.fsec
  LEFT JOIN S2 sb ON sb.ntic = s.ntic AND sb.id = ld.bsec
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0
     OR (sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
         AND ABS(sb.floor_height - sf.floor_height) > ${MAXSTEP})
     OR (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
         AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
         AND LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height) < ${MIN_WALK_OPENING})
),
mo_solid AS (
  -- PIT_CheckThing: live actors, solid decorations, the player.
  SELECT s.ntic, tt.id AS thing_id, CAST(tt.x AS DOUBLE) AS tx, CAST(tt.y AS DOUBLE) AS ty,
         CAST(cd.radius AS DOUBLE) AS radius
  FROM (SELECT DISTINCT ntic FROM mo_walk) s
  JOIN T2 tt ON tt.ntic = s.ntic
  JOIN thing_combat_defs cd ON cd.thing_type = tt.type
  JOIN H2 hh ON hh.ntic = s.ntic AND hh.thing_id = tt.id AND hh.alive
  UNION ALL
  SELECT s.ntic, tt.id, CAST(tt.x AS DOUBLE), CAST(tt.y AS DOUBLE), CAST(bd.radius AS DOUBLE)
  FROM (SELECT DISTINCT ntic FROM mo_walk) s
  JOIN T2 tt ON tt.ntic = s.ntic
  JOIN thing_blocking_defs bd ON bd.thing_type = tt.type
  JOIN mo_player p ON p.ntic = s.ntic
  WHERE (tt.flags & p.skill_bit) <> 0 AND (tt.flags & 16) = 0
  UNION ALL
  SELECT p.ntic, p.player_thing_id, p.px, p.py, ${PLAYER_RADIUS}
  FROM mo_player p JOIN (SELECT DISTINCT ntic FROM mo_walk) s ON s.ntic = p.ntic
  WHERE p.alive
),
mo_candidate_blocked AS (
  SELECT c.*, COALESCE(wb.blocked, FALSE) OR COALESCE(th.hit, FALSE) AS blocked
  FROM mo_desired c
  LEFT JOIN (
    SELECT q.ntic, q.pri, q.thing_id,
      bool_or(SQRT(POWER(q.cx - (q.x1 + q.t * (q.x2 - q.x1)), 2) + POWER(q.cy - (q.y1 + q.t * (q.y2 - q.y1)), 2)) < q.radius
        OR (((q.mx - q.x1) * (q.y2 - q.y1) - (q.my - q.y1) * (q.x2 - q.x1))
              * ((q.cx - q.x1) * (q.y2 - q.y1) - (q.cy - q.y1) * (q.x2 - q.x1)) < 0
            AND ((q.x1 - q.mx) * (q.cy - q.my) - (q.y1 - q.my) * (q.cx - q.mx))
              * ((q.x2 - q.mx) * (q.cy - q.my) - (q.y2 - q.my) * (q.cx - q.mx)) < 0)) AS blocked
    FROM (
      SELECT c2.ntic, c2.pri, c2.thing_id, c2.radius, c2.cx, c2.cy, c2.mx, c2.my, b.x1, b.y1, b.x2, b.y2,
        LEAST(1.0D, GREATEST(0.0D, ((c2.cx - b.x1) * (b.x2 - b.x1) + (c2.cy - b.y1) * (b.y2 - b.y1))
          / NULLIF((b.x2 - b.x1) * (b.x2 - b.x1) + (b.y2 - b.y1) * (b.y2 - b.y1), 0.0D))) AS t
      FROM mo_desired c2
      JOIN mo_blocking b ON b.ntic = c2.ntic AND NOT (b.floor_step_only AND c2.floats)
        AND LEAST(b.x1, b.x2) <= GREATEST(c2.cx, c2.mx) + c2.radius + 2.0D
        AND GREATEST(b.x1, b.x2) >= LEAST(c2.cx, c2.mx) - c2.radius - 2.0D
        AND LEAST(b.y1, b.y2) <= GREATEST(c2.cy, c2.my) + c2.radius + 2.0D
        AND GREATEST(b.y1, b.y2) >= LEAST(c2.cy, c2.my) - c2.radius - 2.0D
    ) q
    GROUP BY q.ntic, q.pri, q.thing_id
  ) wb ON wb.ntic = c.ntic AND wb.pri = c.pri AND wb.thing_id = c.thing_id
  LEFT JOIN (
    SELECT c4.ntic, c4.pri, c4.thing_id, TRUE AS hit
    FROM mo_desired c4
    JOIN mo_solid st ON st.ntic = c4.ntic AND st.thing_id <> c4.thing_id
      AND ABS(st.tx - c4.cx) < st.radius + c4.radius AND ABS(st.ty - c4.cy) < st.radius + c4.radius
    GROUP BY c4.ntic, c4.pri, c4.thing_id
  ) th ON th.ntic = c.ntic AND th.pri = c.pri AND th.thing_id = c.thing_id
),
monster_steps AS (
  SELECT b.ntic, b.thing_id, CAST(b.mx AS FLOAT) AS old_x, CAST(b.my AS FLOAT) AS old_y,
         CAST(b.cx AS FLOAT) AS new_x, CAST(b.cy AS FLOAT) AS new_y, b.face_angle,
         b.dir AS movedir, GREATEST(0, b.next_movecount) AS movecount
  FROM (
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.ntic, c.thing_id ORDER BY c.pri) AS rn
    FROM mo_candidate_blocked c WHERE NOT c.blocked
  ) b WHERE b.rn = 1
  UNION ALL
  SELECT w.ntic, w.thing_id, CAST(w.mx AS FLOAT), CAST(w.my AS FLOAT), CAST(w.mx AS FLOAT), CAST(w.my AS FLOAT),
         CAST(0 AS FLOAT), CAST(NULL AS INT), w.fresh_movecount
  FROM mo_walk w
  LEFT ANTI JOIN mo_candidate_blocked c ON c.ntic = w.ntic AND c.thing_id = w.thing_id AND NOT c.blocked
),
I6 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.sector_id,
    ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id, ai.charge_tics,
    CASE WHEN ms.thing_id IS NOT NULL THEN ms.movedir ELSE ai.movedir END AS movedir,
    CASE WHEN ms.thing_id IS NOT NULL THEN ms.movecount ELSE ai.movecount END AS movecount
  FROM I5 ai LEFT JOIN monster_steps ms ON ms.ntic = ai.ntic AND ms.thing_id = ai.thing_id
),
-- ---------------------------------------------------------------- move
mo_moved AS (
  SELECT * FROM monster_steps WHERE new_x <> old_x OR new_y <> old_y
),
mo_cross_events AS (
  -- Monster-crossable walk-over lines.
  SELECT c.ntic, ${map_id} AS map_id, c.thing_id AS player_thing_id, c.line_id, 'cross' AS trigger_type, c.from_front
  FROM (
    SELECT ms.ntic, ms.thing_id, ld.id AS line_id, ld.cross_once,
      CAST(v2.x - v1.x AS DOUBLE) * CAST(ms.old_y - v1.y AS DOUBLE)
        - CAST(v2.y - v1.y AS DOUBLE) * CAST(ms.old_x - v1.x AS DOUBLE) < 0 AS from_front,
      ABS(CAST(v2.x - v1.x AS DOUBLE) * CAST(ms.old_y - v1.y AS DOUBLE)
        - CAST(v2.y - v1.y AS DOUBLE) * CAST(ms.old_x - v1.x AS DOUBLE)) AS old_side,
      CAST(v2.x - v1.x AS DOUBLE) * CAST(ms.new_y - v1.y AS DOUBLE)
        - CAST(v2.y - v1.y AS DOUBLE) * CAST(ms.new_x - v1.x AS DOUBLE) AS new_side,
      (ms.new_x - ms.old_x) * CAST(v1.y - ms.old_y AS DOUBLE) - (ms.new_y - ms.old_y) * CAST(v1.x - ms.old_x AS DOUBLE) AS v1_side,
      (ms.new_x - ms.old_x) * CAST(v2.y - ms.old_y AS DOUBLE) - (ms.new_y - ms.old_y) * CAST(v2.x - ms.old_x AS DOUBLE) AS v2_side
    FROM mo_moved ms
    JOIN linedefs ld ON ld.map_id = ${map_id} AND ld.monster_crossable
    JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
    JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
  ) c
  LEFT JOIN A1 a ON a.ntic = c.ntic AND a.line_id = c.line_id
  WHERE c.old_side > 1e-7D AND c.new_side <> 0
    AND ((c.from_front AND c.new_side > 0) OR (NOT c.from_front AND c.new_side < 0))
    AND c.v1_side * c.v2_side < 0
    AND NOT (c.cross_once AND a.line_id IS NOT NULL)
),
mo_teleports AS (
  -- EV_Teleport for a monster: the destination nearest the tagged sector's middle.
  SELECT q.ntic, q.thing_id, q.dest_x, q.dest_y, q.dest_angle, q.sector_id FROM (
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.ntic, c.thing_id ORDER BY c.off_centre, c.dest_id) AS rn
    FROM (
      SELECT t.ntic, t.thing_id, t.sector_id, th.id AS dest_id, th.x AS dest_x, th.y AS dest_y,
             th.angle AS dest_angle,
             ABS(th.x - (t.min_x + t.max_x) / 2.0D) + ABS(th.y - (t.min_y + t.max_y) / 2.0D) AS off_centre
      FROM (
        SELECT e.ntic, e.player_thing_id AS thing_id, s.id AS sector_id,
               MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x, MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
        FROM mo_cross_events e
        JOIN linedefs ld ON ld.map_id = ${map_id} AND ld.id = e.line_id
        JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'teleport'
        JOIN S2 s ON s.ntic = e.ntic AND s.tag = ld.tag
        JOIN render_segs rs ON rs.map_id = ${map_id} AND rs.fsec = s.id
        GROUP BY e.ntic, e.player_thing_id, s.id
      ) t
      JOIN T2 th ON th.ntic = t.ntic
      JOIN thing_role_defs tr ON tr.thing_type = th.type AND tr.is_teleport_dest
        AND th.x BETWEEN t.min_x AND t.max_x AND th.y BETWEEN t.min_y AND t.max_y
    ) c
  ) q WHERE q.rn = 1
),
T3 AS (
  SELECT t.ntic, t.id, t.map_id,
    CASE WHEN tp.thing_id IS NOT NULL THEN tp.dest_x WHEN ms.thing_id IS NOT NULL THEN ms.new_x ELSE t.x END AS x,
    CASE WHEN tp.thing_id IS NOT NULL THEN tp.dest_y WHEN ms.thing_id IS NOT NULL THEN ms.new_y ELSE t.y END AS y,
    t.z,
    CASE WHEN tp.thing_id IS NOT NULL THEN tp.dest_angle WHEN ms.thing_id IS NOT NULL THEN ms.face_angle ELSE t.angle END AS angle,
    t.spawn_x, t.spawn_y, t.spawn_angle, t.mom_x, t.mom_y, t.type, t.flags
  FROM T2 t
  LEFT JOIN mo_moved ms ON ms.ntic = t.ntic AND ms.thing_id = t.id
  LEFT JOIN mo_teleports tp ON tp.ntic = t.ntic AND tp.thing_id = t.id
),
I7 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index,
    COALESCE(tp.sector_id, ai.sector_id) AS sector_id,
    ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id, ai.charge_tics, ai.movedir, ai.movecount
  FROM I6 ai LEFT JOIN mo_teleports tp ON tp.ntic = ai.ntic AND tp.thing_id = ai.thing_id
),
-- ---------------------------------------------------------------- float (P_ZMovement's float, A_SkullAttack)
mo_float AS (
  SELECT ai.ntic, ai.thing_id, s.floor_height, s.ceil_height, d.height,
    CAST(p.base_z - ${VIEWHEIGHT} AS DOUBLE) + ${PLAYER_HEIGHT} / 2.0D - th.z AS delta,
    FHYPOT(pt.x - th.x, pt.y - th.y) AS dist
  FROM I7 ai
  JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.floater_due
  JOIN T3 th ON th.ntic = ai.ntic AND th.id = ai.thing_id
  LEFT JOIN N1 rt ON rt.ntic = ai.ntic AND rt.thing_id = ai.thing_id
  JOIN S2 s ON s.ntic = ai.ntic AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  JOIN P6 p ON p.tic = ai.ntic AND p.player_thing_id = COALESCE(ai.target_thing_id, ${player})
  JOIN T3 pt ON pt.ntic = ai.ntic AND pt.id = p.player_thing_id
  JOIN thing_combat_defs d ON d.thing_type = th.type
  WHERE d.floats AND ai.state IN ('see', 'missile')
),
mo_skull_launch AS (
  SELECT ai.ntic, ai.thing_id, CAST(pt.x AS DOUBLE) AS tx, CAST(pt.y AS DOUBLE) AS ty,
         FHYPOT(pt.x - th.x, pt.y - th.y) AS len
  FROM I7 ai
  JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.floater_due
  JOIN T3 th ON th.ntic = ai.ntic AND th.id = ai.thing_id
  JOIN T3 pt ON pt.ntic = ai.ntic AND pt.id = COALESCE(ai.target_thing_id, ${player})
  JOIN thing_combat_defs d ON d.thing_type = th.type AND d.skull_fly
  WHERE ai.fired_this_tick
),
T4a AS (
  SELECT t.ntic, t.id, t.map_id, t.x, t.y,
    CASE WHEN f.thing_id IS NOT NULL
         THEN CAST(LEAST(f.ceil_height - f.height, GREATEST(f.floor_height,
                t.z + CASE WHEN f.delta > 0 AND f.dist < f.delta * 3 THEN 4
                           WHEN f.delta < 0 AND f.dist < -f.delta * 3 THEN -4 ELSE 0 END)) AS FLOAT)
         ELSE t.z END AS z,
    t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN k.thing_id IS NOT NULL AND k.len > 0
         THEN CAST(${SKULL_CHARGE_SPEED} * (k.tx - t.x) / k.len AS FLOAT) ELSE t.mom_x END AS mom_x,
    CASE WHEN k.thing_id IS NOT NULL AND k.len > 0
         THEN CAST(${SKULL_CHARGE_SPEED} * (k.ty - t.y) / k.len AS FLOAT) ELSE t.mom_y END AS mom_y,
    t.type, t.flags
  FROM T3 t
  LEFT JOIN mo_float f ON f.ntic = t.ntic AND f.thing_id = t.id
  LEFT JOIN mo_skull_launch k ON k.ntic = t.ntic AND k.thing_id = t.id
),
I8a AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.sector_id,
    ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id,
    CASE WHEN sk.thing_id IS NOT NULL AND (ai.fired_this_tick OR ai.charge_tics > 0)
         THEN CASE WHEN ai.fired_this_tick THEN CAST(${TICRATE} AS INT) ELSE GREATEST(0, ai.charge_tics - 1) END
         ELSE ai.charge_tics END AS charge_tics,
    ai.movedir, ai.movecount
  FROM I7 ai
  LEFT JOIN (SELECT ai2.ntic, ai2.thing_id FROM I7 ai2
             JOIN mo_plan pl ON pl.ntic = ai2.ntic AND pl.floater_due
             JOIN T4a t ON t.ntic = ai2.ntic AND t.id = ai2.thing_id
             JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly) sk
    ON sk.ntic = ai.ntic AND sk.thing_id = ai.thing_id
),
mo_skull_hits AS (
  -- The charge lands: within reach of the player.
  SELECT ai.ntic, ai.thing_id, p.player_thing_id
  FROM I8a ai
  JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.floater_due
  JOIN T4a t ON t.ntic = ai.ntic AND t.id = ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
  JOIN mo_player p ON p.ntic = ai.ntic AND p.alive
  WHERE ai.charge_tics > 0 AND ABS(p.fx - t.x) < ${SKULL_HIT_REACH} AND ABS(p.fy - t.y) < ${SKULL_HIT_REACH}
),
mo_skull_damage AS (
  SELECT h.ntic, CAST(SUM((PRANDOM(h.thing_id, p.level_tics, 21) % d.charge_sides + 1) * d.charge_mult) AS INT) AS dmg
  FROM mo_skull_hits h
  JOIN T4a t ON t.ntic = h.ntic AND t.id = h.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type
  JOIN mo_player p ON p.ntic = h.ntic
  GROUP BY h.ntic
),
T4 AS (
  SELECT t.ntic, t.id, t.map_id, t.x, t.y, t.z, t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN s.thing_id IS NOT NULL THEN CAST(0 AS FLOAT) ELSE t.mom_x END AS mom_x,
    CASE WHEN s.thing_id IS NOT NULL THEN CAST(0 AS FLOAT) ELSE t.mom_y END AS mom_y,
    t.type, t.flags
  FROM T4a t
  LEFT JOIN (
    -- A charging skull within reach of any player stops.
    SELECT DISTINCT ai.ntic, ai.thing_id FROM I8a ai
    JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.floater_due
    JOIN T4a t2 ON t2.ntic = ai.ntic AND t2.id = ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t2.type AND d.skull_fly
    JOIN mo_player p ON p.ntic = ai.ntic
    WHERE ai.charge_tics > 0 AND ABS(p.fx - t2.x) < ${SKULL_HIT_REACH} AND ABS(p.fy - t2.y) < ${SKULL_HIT_REACH}
  ) s ON s.ntic = t.ntic AND s.thing_id = t.id
),
I8 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.sector_id,
    ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id,
    CASE WHEN st.thing_id IS NOT NULL THEN 0 ELSE ai.charge_tics END AS charge_tics,
    ai.movedir, ai.movecount
  FROM I8a ai
  LEFT JOIN (
    SELECT ai2.ntic, ai2.thing_id FROM I8a ai2
    JOIN mo_plan pl ON pl.ntic = ai2.ntic AND pl.floater_due
    JOIN T4 t ON t.ntic = ai2.ntic AND t.id = ai2.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
    WHERE ai2.charge_tics > 0 AND t.mom_x = 0 AND t.mom_y = 0 AND NOT ai2.fired_this_tick
  ) st ON st.ntic = ai.ntic AND st.thing_id = ai.thing_id
),
-- ---------------------------------------------------------------- chase
mo_use_events AS (
  -- A chasing monster next to a monster-usable door opens it.
  SELECT DISTINCT q.ntic, ${map_id} AS map_id, q.thing_id AS player_thing_id, q.linedef_id AS line_id,
         'use' AS trigger_type, TRUE AS from_front
  FROM (
    SELECT u.*,
      SQRT(POWER(u.sx - (u.x1 + u.uu * (u.x2 - u.x1)), 2) + POWER(u.sy - (u.y1 + u.uu * (u.y2 - u.y1)), 2)) AS gap
    FROM (
      SELECT s.*, ld.linedef_id, ld.flags, ld.left_sd_id, ld.x1, ld.y1, ld.x2, ld.y2,
        LEAST(1.0D, GREATEST(0.0D, ((s.sx - ld.x1) * (ld.x2 - ld.x1) + (s.sy - ld.y1) * (ld.y2 - ld.y1))
          / NULLIF(POWER(ld.x2 - ld.x1, 2) + POWER(ld.y2 - ld.y1, 2), 0.0D))) AS uu
      FROM (
        SELECT ai.ntic, ai.thing_id, cd.radius,
          t.x + 8.0 * (pt.x - t.x) / NULLIF(CAST(FHYPOT(pt.x - t.x, pt.y - t.y) AS DOUBLE), 0.0D) AS sx,
          t.y + 8.0 * (pt.y - t.y) / NULLIF(CAST(FHYPOT(pt.x - t.x, pt.y - t.y) AS DOUBLE), 0.0D) AS sy
        FROM I8 ai
        JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.chasing_due
        JOIN T4 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
        JOIN thing_combat_defs cd ON cd.thing_type = t.type
        JOIN T4 pt ON pt.ntic = ai.ntic AND pt.id = ${player}
        WHERE ai.state = 'see' AND NOT cd.explodes
      ) s
      JOIN linedef_geom ld ON ld.map_id = ${map_id}
      JOIN line_special_defs d ON d.special = ld.special AND d.monster_usable
    ) u
  ) q
  LEFT JOIN D2 back ON back.ntic = q.ntic AND back.id = q.left_sd_id
  LEFT JOIN M2 sm ON sm.ntic = q.ntic AND sm.sector_id = back.sector_id AND sm.direction <> -1
  WHERE (q.flags & 32) = 0 AND q.gap < q.radius AND sm.sector_id IS NULL
),
mo_sector_of AS (
  -- doom_cs_monster_chase's BSP descent, for the chasers that stepped (or were
  -- never placed): the subsector whose path the point follows, and its first
  -- seg's sector.
  SELECT l.ntic, l.thing_id, min_by(rs.fsec, rs.seg_id) AS sector_id
  FROM (
    SELECT m.ntic, m.thing_id, st.ssector_id
    FROM (
      SELECT ai.ntic, ai.thing_id, CAST(t.x AS DOUBLE) AS mx, CAST(t.y AS DOUBLE) AS my
      FROM I8 ai
      JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.chasing_due
      JOIN T4 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
      LEFT JOIN monster_steps ms ON ms.ntic = ai.ntic AND ms.thing_id = ai.thing_id
      WHERE ai.state = 'see' AND (ai.sector_id IS NULL OR ms.thing_id IS NOT NULL)
    ) m
    JOIN node_path_steps st ON st.map_id = ${map_id}
    JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
    GROUP BY m.ntic, m.thing_id, st.ssector_id
    HAVING bool_and(st.side = CASE
      WHEN (m.mx - n.x) * CAST(n.dy AS DOUBLE) - (m.my - n.y) * CAST(n.dx AS DOUBLE) > 0 THEN 'R' ELSE 'L' END)
  ) l
  JOIN render_segs rs ON rs.map_id = ${map_id} AND rs.ssector_id = l.ssector_id
  GROUP BY l.ntic, l.thing_id
),
I9 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index,
    COALESCE(so.sector_id, ai.sector_id) AS sector_id,
    ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id, ai.charge_tics, ai.movedir, ai.movecount
  FROM I8 ai LEFT JOIN mo_sector_of so ON so.ntic = ai.ntic AND so.thing_id = ai.thing_id
),
N2 AS (
  SELECT rt.ntic, rt.map_id, rt.thing_id,
    CASE WHEN pl.ntic IS NOT NULL AND ai.sector_id IS NOT NULL THEN ai.sector_id ELSE rt.sector_id END AS sector_id,
    rt.spawn_sector_id, rt.sprite, rt.frame, rt.fullbright, rt.spawn_ceiling, rt.thing_height
  FROM N1 rt
  LEFT JOIN I9 ai ON ai.ntic = rt.ntic AND ai.thing_id = rt.thing_id
  LEFT JOIN (SELECT ntic FROM mo_plan WHERE chasing_due) pl ON pl.ntic = rt.ntic
),
-- ---------------------------------------------------------------- attack
mo_attack_target AS (
  SELECT ai.ntic, ai.thing_id,
    COALESCE(CAST(tt.x AS DOUBLE), pp.px) AS tx, COALESCE(CAST(tt.y AS DOUBLE), pp.py) AS ty,
    CASE WHEN th.thing_id IS NULL THEN CAST(NULL AS INT) ELSE ai.target_thing_id END AS victim_id,
    pp.player_thing_id AS victim_player
  FROM I9 ai
  JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.attacking_due
  JOIN mo_player pp ON pp.ntic = ai.ntic
  LEFT JOIN T4 tt ON tt.ntic = ai.ntic AND tt.id = ai.target_thing_id
  LEFT JOIN H2 th ON th.ntic = ai.ntic AND th.thing_id = ai.target_thing_id AND th.alive
),
mo_hits AS (
  SELECT q.*, NOT COALESCE(b.blocked, FALSE) AS visible
  FROM (
    SELECT ai.ntic, ai.thing_id, t.type, CAST(t.x AS DOUBLE) AS mx, CAST(t.y AS DOUBLE) AS my,
      d.hitscan_pellets, d.hitscan_mult, d.hitscan_sides, d.melee_mult, d.melee_sides, d.explodes,
      d.blast_radius, mt.victim_id, mt.victim_player, mt.tx, mt.ty, p.level_tics AS tic, p.shadowed,
      SQRT(POWER(CAST(t.x AS DOUBLE) - mt.tx, 2) + POWER(CAST(t.y AS DOUBLE) - mt.ty, 2)) AS dist
    FROM I9 ai
    JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.attacking_due
    JOIN T4 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type
    JOIN mo_attack_target mt ON mt.ntic = ai.ntic AND mt.thing_id = ai.thing_id
    JOIN mo_player p ON p.ntic = ai.ntic
    WHERE ai.fired_this_tick
  ) q
  LEFT JOIN (
    SELECT q2.ntic, q2.thing_id, TRUE AS blocked
    FROM (
      SELECT ai.ntic, ai.thing_id, CAST(t.x AS DOUBLE) AS mx, CAST(t.y AS DOUBLE) AS my, mt.tx, mt.ty
      FROM I9 ai
      JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.attacking_due
      JOIN T4 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
      JOIN mo_attack_target mt ON mt.ntic = ai.ntic AND mt.thing_id = ai.thing_id
      WHERE ai.fired_this_tick
    ) q2
    JOIN mo_walls b ON b.ntic = q2.ntic
    WHERE ((q2.mx - b.x1) * (b.y2 - b.y1) - (q2.my - b.y1) * (b.x2 - b.x1))
        * ((q2.tx - b.x1) * (b.y2 - b.y1) - (q2.ty - b.y1) * (b.x2 - b.x1)) < 0
      AND ((b.x1 - q2.mx) * (q2.ty - q2.my) - (b.y1 - q2.my) * (q2.tx - q2.mx))
        * ((b.x2 - q2.mx) * (q2.ty - q2.my) - (b.y2 - q2.my) * (q2.tx - q2.mx)) < 0
    GROUP BY q2.ntic, q2.thing_id
  ) b ON b.ntic = q.ntic AND b.thing_id = q.thing_id
),
monster_attack_damage AS (
  SELECT r.ntic, r.thing_id AS attacker_id, r.victim_id, r.victim_player,
    CASE WHEN r.visible AND r.dist <= ${DEFAULT_ATTACK_RANGE}
           AND (r.dist <= ${PLAYER_RADIUS}
             OR ABS((r.r1 - r.r2) * 360.0D / ${HITSCAN_SPREAD_UNITS} + r.shadow_err)
               <= DEGREES(ASIN(LEAST(1.0D, ${PLAYER_RADIUS} / NULLIF(r.dist, 0.0D)))))
         THEN r.pellet_damage ELSE 0 END AS dmg,
    r.mx, r.my
  FROM (
    SELECT g.*,
      PRANDOM(g.thing_id, g.tic * 8 + g.pellet, 12) AS r1,
      PRANDOM(g.thing_id, g.tic * 8 + g.pellet, 13) AS r2,
      (PRANDOM(g.thing_id, g.tic * 8 + g.pellet, 14) % g.hitscan_sides + 1) * g.hitscan_mult AS pellet_damage,
      CASE WHEN g.shadowed THEN (PRANDOM(g.thing_id, g.tic, 15) - PRANDOM(g.thing_id, g.tic, 16)) * 360.0D / ${SHADOW_MISS_UNITS}
           ELSE 0.0D END AS shadow_err
    FROM (SELECT h.*, explode(sequence(1, h.hitscan_pellets)) AS pellet FROM mo_hits h
          WHERE h.hitscan_pellets IS NOT NULL) g
  ) r
  UNION ALL
  SELECT h.ntic, h.thing_id, h.victim_id, h.victim_player,
    CASE WHEN h.melee_mult IS NOT NULL AND h.visible AND h.dist <= ${MELEE_REACH}
           THEN (PRANDOM(h.thing_id, h.tic, 17) % h.melee_sides + 1) * h.melee_mult
         WHEN h.explodes AND h.visible AND h.dist < h.blast_radius
           THEN CAST(GREATEST(0, h.blast_radius - CAST(FLOOR(h.dist) AS INT)) AS INT)
         ELSE 0 END,
    h.mx, h.my
  FROM mo_hits h WHERE h.melee_mult IS NOT NULL OR h.explodes
),
P6s AS (
  -- The charge lands: 3d8 to the player, unless god mode or invulnerable.
  SELECT p.tic, p.map_id, p.player_thing_id,
    CASE WHEN k.dmg IS NULL THEN p.health ELSE GREATEST(0, p.health - (k.dmg - k.saved)) END AS health,
    CASE WHEN k.dmg IS NULL THEN p.alive ELSE (p.health - (k.dmg - k.saved)) > 0 END AS alive,
    p.level_tics, p.previous_x, p.previous_y, p.position_x, p.position_y, p.base_z, p.view_z, p.view_angle,
    p.momentum_x, p.momentum_y, p.bob_strength, p.previous_view_z, p.previous_view_angle, p.sector_id,
    CASE WHEN k.dmg IS NULL THEN p.pain_face_tics ELSE 12 END AS pain_face_tics,
    CASE WHEN k.dmg IS NULL THEN p.armor ELSE p.armor - k.saved END AS armor,
    CASE WHEN k.dmg IS NOT NULL AND p.armor - k.saved <= 0 THEN 0 ELSE p.armor_class END AS armor_class,
    p.backpack, p.ammo_bullets, p.ammo_shells, p.ammo_rockets, p.ammo_cells,
    p.key_blue, p.key_yellow, p.key_red, p.radsuit_tics, p.invis_tics, p.momentum_z,
    CASE WHEN k.dmg IS NULL THEN p.damage_count ELSE LEAST(100, p.damage_count + (k.dmg - k.saved)) END AS damage_count,
    p.bonus_count, p.light_amp_tics, p.power_map, p.god_mode, p.noclip, p.invuln_tics,
    p.berserk, p.message, p.message_tics, p.frags, p.death_tics,
    CASE WHEN k.dmg IS NOT NULL AND (p.health - (k.dmg - k.saved)) <= 0 THEN -1 ELSE p.killer_id END AS killer_id,
    p.sprite_frame, p.t_x, p.t_y, p.t_z, p.t_angle, p.last_mode
  FROM P6 p
  LEFT JOIN (
    SELECT d.ntic, d.dmg,
      LEAST(p2.armor, CASE p2.armor_class WHEN 2 THEN d.dmg DIV 2 WHEN 1 THEN d.dmg DIV 3 ELSE 0 END) AS saved
    FROM mo_skull_damage d JOIN P6 p2 ON p2.tic = d.ntic
    WHERE NOT p2.god_mode AND p2.invuln_tics <= 0
  ) k ON k.ntic = p.tic
),
mo_player_hurt AS (
  SELECT s.ntic, CAST(SUM(s.dmg) AS INT) AS dmg,
         CAST(SUM(FLOOR(s.dmg / 3.0D)) AS INT) AS green_saved,
         CAST(SUM(FLOOR(s.dmg / 2.0D)) AS INT) AS blue_saved,
         SUM(ROUND(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * s.ddx / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_x,
         SUM(ROUND(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * s.ddy / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_y
  FROM (
    SELECT d.ntic, d.dmg >> CASE WHEN p.skill = 0 THEN 1 ELSE 0 END AS dmg,
           p.px - d.mx AS ddx, p.py - d.my AS ddy,
           SQRT(POWER(p.px - d.mx, 2) + POWER(p.py - d.my, 2)) AS dist
    FROM monster_attack_damage d
    JOIN mo_player p ON p.ntic = d.ntic AND p.player_thing_id = d.victim_player
    JOIN P6s a ON a.tic = d.ntic AND a.player_thing_id = d.victim_player AND a.alive
    WHERE d.victim_id IS NULL
  ) s
  GROUP BY s.ntic
),
P7 AS (
  -- 26_cs_monsters' P_DamageMobj on the player: a lost soul's charge (the
  -- float stage), then the attack stage's rolls.
  SELECT q.tic, q.map_id, q.player_thing_id,
    CASE WHEN q.mtic IS NULL THEN q.health ELSE GREATEST(0, q.health - q.took) END AS health,
    CASE WHEN q.mtic IS NULL THEN q.alive ELSE GREATEST(0, q.health - q.took) > 0 END AS alive,
    q.level_tics, q.previous_x, q.previous_y, q.position_x, q.position_y, q.base_z, q.view_z, q.view_angle,
    CASE WHEN q.mtic IS NULL THEN q.momentum_x ELSE CAST(q.momentum_x + q.thrust_x AS FLOAT) END AS momentum_x,
    CASE WHEN q.mtic IS NULL THEN q.momentum_y ELSE CAST(q.momentum_y + q.thrust_y AS FLOAT) END AS momentum_y,
    q.bob_strength, q.previous_view_z, q.previous_view_angle, q.sector_id,
    CASE WHEN q.took > 0 THEN 12 ELSE q.pain_face_tics END AS pain_face_tics,
    q.armor - q.saved AS armor,
    CASE WHEN q.mtic IS NOT NULL AND q.armor - q.saved <= 0 THEN 0 ELSE q.armor_class END AS armor_class,
    q.backpack, q.ammo_bullets, q.ammo_shells, q.ammo_rockets, q.ammo_cells,
    q.key_blue, q.key_yellow, q.key_red, q.radsuit_tics, q.invis_tics, q.momentum_z,
    CASE WHEN q.mtic IS NULL THEN q.damage_count ELSE LEAST(100, q.damage_count + q.took) END AS damage_count,
    q.bonus_count, q.light_amp_tics, q.power_map, q.god_mode, q.noclip, q.invuln_tics,
    q.berserk, q.message, q.message_tics, q.frags, q.death_tics,
    CASE WHEN q.mtic IS NOT NULL AND q.alive AND q.health - q.took <= 0 THEN -1 ELSE q.killer_id END AS killer_id,
    q.sprite_frame, q.t_x, q.t_y, q.t_z, q.t_angle, q.last_mode
  FROM (
    SELECT p.*, h.ntic AS mtic, h.thrust_x, h.thrust_y,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE LEAST(p.armor, CASE p.armor_class WHEN 2 THEN h.blue_saved
                                                           WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS saved,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE h.dmg - LEAST(p.armor, CASE p.armor_class WHEN 2 THEN h.blue_saved
                                                                   WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS took
    FROM P6s p LEFT JOIN mo_player_hurt h ON h.ntic = p.tic
  ) q
),
mo_infight AS (
  SELECT ntic, victim_id, CAST(SUM(dmg) AS INT) AS dmg, MIN(CASE WHEN dmg > 0 THEN attacker_id END) AS attacker
  FROM monster_attack_damage WHERE victim_id IS NOT NULL AND victim_player = ${player}
  GROUP BY ntic, victim_id
),
H3 AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN f.dmg > 0 THEN h.health - f.dmg ELSE h.health END AS health, h.max_health,
    CASE WHEN f.dmg > 0 THEN h.health - f.dmg > 0 ELSE h.alive END AS alive
  FROM H2 h LEFT JOIN mo_infight f ON f.ntic = h.ntic AND f.victim_id = h.thing_id
),
I10 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    CASE WHEN r.attacker IS NOT NULL AND ai.state = 'stand' THEN 'see' ELSE ai.state END AS state,
    CASE WHEN r.attacker IS NOT NULL AND ai.state = 'stand' THEN 0 ELSE ai.state_tics END AS state_tics,
    CASE WHEN r.attacker IS NOT NULL AND ai.state = 'stand' THEN 0 ELSE ai.seq_index END AS seq_index,
    ai.sector_id, ai.attack_cooldown, ai.fired_this_tick,
    COALESCE(r.attacker, ai.target_thing_id) AS target_thing_id,
    ai.charge_tics, ai.movedir, ai.movecount
  FROM I9 ai
  LEFT JOIN (
    SELECT f.ntic, f.victim_id, f.attacker FROM mo_infight f
    JOIN H3 th ON th.ntic = f.ntic AND th.thing_id = f.victim_id AND th.alive
    WHERE f.attacker IS NOT NULL
  ) r ON r.ntic = ai.ntic AND r.victim_id = ai.thing_id AND ai.thing_id <> r.attacker
    AND (ai.target_thing_id IS NULL OR ai.target_thing_id <> r.attacker)
),
-- ---------------------------------------------------------------- barrel, blast
mo_explosions AS (
  SELECT ai.ntic, t.id AS source_id, CAST(t.x AS DOUBLE) AS ex, CAST(t.y AS DOUBLE) AS ey
  FROM I10 ai
  JOIN mo_plan pl ON pl.ntic = ai.ntic AND pl.barrel_due
  JOIN T4 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
  WHERE ai.fired_this_tick
),
mo_barrel_damage AS (
  SELECT q.ntic, q.thing_id, CAST(SUM(CAST(GREATEST(0, q.r - CAST(FLOOR(q.dist) AS INT)) AS INT)) AS INT) AS damage
  FROM (
    SELECT e.ntic, e.source_id, e.ex, e.ey, v.thing_id, v.vx, v.vy, bl.r,
           SQRT(POWER(v.vx - e.ex, 2) + POWER(v.vy - e.ey, 2)) AS dist
    FROM mo_explosions e
    CROSS JOIN (SELECT MAX(blast_radius) AS r FROM thing_combat_defs WHERE explodes) bl
    JOIN (SELECT DISTINCT e2.ntic, h.thing_id, CAST(t.x AS DOUBLE) AS vx, CAST(t.y AS DOUBLE) AS vy
          FROM mo_explosions e2
          CROSS JOIN (SELECT MAX(blast_radius) AS r FROM thing_combat_defs WHERE explodes) bl2
          JOIN T4 t ON t.ntic = e2.ntic AND t.x BETWEEN e2.ex - bl2.r AND e2.ex + bl2.r
            AND t.y BETWEEN e2.ey - bl2.r AND e2.ey + bl2.r
          JOIN H3 h ON h.ntic = t.ntic AND h.thing_id = t.id AND h.alive) v ON v.ntic = e.ntic
  ) q
  LEFT ANTI JOIN mo_walls b ON b.ntic = q.ntic
    AND ((q.ex - b.x1) * (b.y2 - b.y1) - (q.ey - b.y1) * (b.x2 - b.x1))
      * ((q.vx - b.x1) * (b.y2 - b.y1) - (q.vy - b.y1) * (b.x2 - b.x1)) < 0
    AND ((b.x1 - q.ex) * (q.vy - q.ey) - (b.y1 - q.ey) * (q.vx - q.ex))
      * ((b.x2 - q.ex) * (q.vy - q.ey) - (b.y2 - q.ey) * (q.vx - q.ex)) < 0
  WHERE q.thing_id <> q.source_id AND q.dist < q.r
  GROUP BY q.ntic, q.thing_id
),
H4 AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN d.thing_id IS NULL THEN h.health ELSE h.health - d.damage END AS health, h.max_health,
    CASE WHEN d.thing_id IS NULL THEN h.alive ELSE h.health - d.damage > 0 END AS alive
  FROM H3 h LEFT JOIN mo_barrel_damage d ON d.ntic = h.ntic AND d.thing_id = h.thing_id
),
mo_blast AS (
  -- P_DamageMobj's thrust from rockets and barrels.
  SELECT q.ntic, q.thing_id,
    SUM(ROUND(GREATEST(0, 128 - CAST(FLOOR(q.dist) AS INT)) * 12.5D / GREATEST(1, q.mass) * q.dx / NULLIF(q.dist, 0.0D) * 65536.0D)) / 65536.0D AS push_x,
    SUM(ROUND(GREATEST(0, 128 - CAST(FLOOR(q.dist) AS INT)) * 12.5D / GREATEST(1, q.mass) * q.dy / NULLIF(q.dist, 0.0D) * 65536.0D)) / 65536.0D AS push_y
  FROM (
    SELECT e.ntic, v.id AS thing_id, cd.mass, e.source_id,
      v.x - e.ex AS dx, v.y - e.ey AS dy, SQRT(POWER(v.x - e.ex, 2) + POWER(v.y - e.ey, 2)) AS dist
    FROM (
      SELECT i.ntic, i.owner_thing_id AS source_id, CAST(i.x AS DOUBLE) AS ex, CAST(i.y AS DOUBLE) AS ey
      FROM projectile_impacts i
      JOIN mo_plan pl ON pl.ntic = i.ntic AND (pl.barrel_due OR pl.rocket_due)
      WHERE i.projectile_type = 'rocket'
      UNION ALL
      SELECT e2.ntic, e2.source_id, e2.ex, e2.ey FROM mo_explosions e2
    ) e
    JOIN T4 v ON v.ntic = e.ntic
    JOIN thing_combat_defs cd ON cd.thing_type = v.type
  ) q
  WHERE q.thing_id <> q.source_id AND q.dist < 128.0D AND q.dist > 0.0D
  GROUP BY q.ntic, q.thing_id
),
T5 AS (
  SELECT t.ntic, t.id, t.map_id, t.x, t.y, t.z, t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN b.thing_id IS NULL THEN t.mom_x ELSE CAST(t.mom_x + b.push_x AS FLOAT) END AS mom_x,
    CASE WHEN b.thing_id IS NULL THEN t.mom_y ELSE CAST(t.mom_y + b.push_y AS FLOAT) END AS mom_y,
    t.type, t.flags
  FROM T4 t LEFT JOIN mo_blast b ON b.ntic = t.ntic AND b.thing_id = t.id
),
-- ---------------------------------------------------------------- deaths
Z1 AS (
  SELECT ntic, map_id, thing_id, death_tic FROM Z0
  UNION ALL
  SELECT ai.ntic, ${map_id} AS map_id, ai.thing_id, CAST(p.level_tics AS BIGINT) AS death_tic
  FROM I10 ai
  JOIN T5 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
  JOIN mo_player p ON p.ntic = ai.ntic
  LEFT ANTI JOIN Z0 z ON z.ntic = ai.ntic AND z.thing_id = ai.thing_id
  WHERE ai.state = 'dead'
),
mo_respawns AS (
  -- P_NightmareRespawn: on skill 4, a corpse twelve seconds dead, checked on
  -- every 32nd tic, comes back on a roll of 4 in 256 if its spawn spot is free.
  SELECT z.ntic, z.thing_id, t.x AS old_x, t.y AS old_y
  FROM Z1 z
  JOIN T5 t ON t.ntic = z.ntic AND t.id = z.thing_id
  JOIN mo_player p ON p.ntic = z.ntic
  JOIN thing_combat_defs md ON md.thing_type = t.type
  LEFT ANTI JOIN (
    SELECT oh.ntic, ot.x, ot.y, od.radius, oh.thing_id
    FROM H4 oh JOIN T5 ot ON ot.ntic = oh.ntic AND ot.id = oh.thing_id
    JOIN thing_combat_defs od ON od.thing_type = ot.type
    WHERE oh.alive
  ) o ON o.ntic = z.ntic AND o.thing_id <> z.thing_id
    AND POWER(o.x - t.spawn_x, 2) + POWER(o.y - t.spawn_y, 2) < POWER(o.radius + md.radius, 2)
  WHERE p.skill = 4
    AND p.level_tics - z.death_tic >= ${MONSTER_RESPAWN_TICS}
    AND (p.level_tics & 31) = 0
    AND PRANDOM(z.thing_id, p.level_tics, 40) <= 4
),
T5r AS (
  SELECT t.ntic, t.id, t.map_id,
    CASE WHEN r.thing_id IS NULL THEN t.x ELSE CAST(t.spawn_x AS FLOAT) END AS x,
    CASE WHEN r.thing_id IS NULL THEN t.y ELSE CAST(t.spawn_y AS FLOAT) END AS y,
    t.z,
    CASE WHEN r.thing_id IS NULL THEN t.angle ELSE CAST(t.spawn_angle AS FLOAT) END AS angle,
    t.spawn_x, t.spawn_y, t.spawn_angle, t.mom_x, t.mom_y, t.type, t.flags
  FROM T5 t LEFT JOIN mo_respawns r ON r.ntic = t.ntic AND r.thing_id = t.id
),
H5 AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN r.thing_id IS NULL THEN h.health ELSE h.max_health END AS health, h.max_health,
    CASE WHEN r.thing_id IS NULL THEN h.alive ELSE TRUE END AS alive
  FROM H4 h LEFT JOIN mo_respawns r ON r.ntic = h.ntic AND r.thing_id = h.thing_id
),
N3 AS (
  SELECT rt.ntic, rt.map_id, rt.thing_id,
    CASE WHEN r.thing_id IS NOT NULL AND rt.spawn_sector_id IS NOT NULL THEN rt.spawn_sector_id ELSE rt.sector_id END AS sector_id,
    rt.spawn_sector_id, rt.sprite, rt.frame, rt.fullbright, rt.spawn_ceiling, rt.thing_height
  FROM N2 rt LEFT JOIN mo_respawns r ON r.ntic = rt.ntic AND r.thing_id = rt.thing_id
),
I11 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    CASE WHEN r.thing_id IS NULL THEN ai.state ELSE 'stand' END AS state,
    CASE WHEN r.thing_id IS NULL THEN ai.state_tics ELSE -1 END AS state_tics,
    CASE WHEN r.thing_id IS NULL THEN ai.seq_index ELSE 0 END AS seq_index,
    CASE WHEN r.thing_id IS NULL THEN ai.sector_id ELSE rt.sector_id END AS sector_id,
    CASE WHEN r.thing_id IS NULL THEN ai.attack_cooldown ELSE 18 END AS attack_cooldown,
    CASE WHEN r.thing_id IS NULL THEN ai.fired_this_tick ELSE FALSE END AS fired_this_tick,
    ai.target_thing_id, ai.charge_tics, ai.movedir, ai.movecount
  FROM I10 ai
  LEFT JOIN mo_respawns r ON r.ntic = ai.ntic AND r.thing_id = ai.thing_id
  LEFT JOIN N3 rt ON rt.ntic = ai.ntic AND rt.thing_id = ai.thing_id
),
X4 AS (
  -- The teleport fog at the corpse (k = 0) and at the spawn spot (k = 1).
  -- One branch each: DataFusion's eliminate_cross_join drops an equi-join key
  -- that spans two relations, such as `s.id = CASE k.k ... END` over a cross
  -- join with the k values (apache/datafusion#26058).
  SELECT * FROM X3
  UNION ALL
  SELECT q.* FROM (
    SELECT r.ntic, ${map_id} AS map_id,
      CAST(${MONSTER_RESPAWN_EFFECT_ID_BASE} AS BIGINT) + CAST(r.thing_id AS BIGINT) * ${EFFECT_ID_TIC_SPAN} * 2
        + (p.level_tics % ${EFFECT_ID_TIC_SPAN}) * 2 + 0 AS effect_id,
      'tfog' AS effect_type, r.old_x AS x, r.old_y AS y, CAST(s.floor_height AS FLOAT) AS z,
      rt.sector_id, 0 AS age
    FROM mo_respawns r
    JOIN N2 rt ON rt.ntic = r.ntic AND rt.thing_id = r.thing_id
    JOIN mo_player p ON p.ntic = r.ntic
    JOIN S2 s ON s.ntic = r.ntic AND s.id = rt.sector_id
    UNION ALL
    SELECT r.ntic, ${map_id} AS map_id,
      CAST(${MONSTER_RESPAWN_EFFECT_ID_BASE} AS BIGINT) + CAST(r.thing_id AS BIGINT) * ${EFFECT_ID_TIC_SPAN} * 2
        + (p.level_tics % ${EFFECT_ID_TIC_SPAN}) * 2 + 1 AS effect_id,
      'tfog' AS effect_type, CAST(t.spawn_x AS FLOAT) AS x, CAST(t.spawn_y AS FLOAT) AS y,
      CAST(s.floor_height AS FLOAT) AS z, rt.spawn_sector_id AS sector_id, 0 AS age
    FROM mo_respawns r
    JOIN T5 t ON t.ntic = r.ntic AND t.id = r.thing_id
    JOIN N2 rt ON rt.ntic = r.ntic AND rt.thing_id = r.thing_id
    JOIN mo_player p ON p.ntic = r.ntic
    JOIN S2 s ON s.ntic = r.ntic AND s.id = COALESCE(rt.spawn_sector_id, rt.sector_id)
  ) q
  LEFT ANTI JOIN X3 x ON x.ntic = q.ntic AND x.effect_id = q.effect_id
),
Z2 AS (
  SELECT z.* FROM Z1 z LEFT ANTI JOIN mo_respawns r ON r.ntic = z.ntic AND r.thing_id = z.thing_id
),
-- ---------------------------------------------------------------- 28_cs_sector_fx
P8 AS (
  -- An E1M8-style sector takes god mode away; damaging floors hurt every 32 tics.
  SELECT p.tic, p.map_id, p.player_thing_id,
    CASE WHEN f.amount IS NOT NULL THEN GREATEST(0, p.health - (f.amount - f.saved)) ELSE p.health END AS health,
    CASE WHEN f.amount IS NOT NULL THEN (p.health - (f.amount - f.saved)) > 0 ELSE p.alive END AS alive,
    p.level_tics, p.previous_x, p.previous_y, p.position_x, p.position_y, p.base_z, p.view_z, p.view_angle,
    p.momentum_x, p.momentum_y, p.bob_strength, p.previous_view_z, p.previous_view_angle, p.sector_id,
    CASE WHEN f.amount IS NOT NULL THEN 12 ELSE p.pain_face_tics END AS pain_face_tics,
    CASE WHEN f.amount IS NOT NULL THEN p.armor - f.saved ELSE p.armor END AS armor,
    CASE WHEN f.amount IS NOT NULL AND p.armor - f.saved <= 0 THEN 0 ELSE p.armor_class END AS armor_class,
    p.backpack, p.ammo_bullets, p.ammo_shells, p.ammo_rockets, p.ammo_cells,
    p.key_blue, p.key_yellow, p.key_red, p.radsuit_tics, p.invis_tics, p.momentum_z,
    CASE WHEN f.amount IS NOT NULL THEN LEAST(100, p.damage_count + (f.amount - f.saved)) ELSE p.damage_count END AS damage_count,
    p.bonus_count, p.light_amp_tics, p.power_map, p.god_mode2 AS god_mode, p.noclip, p.invuln_tics,
    p.berserk, p.message, p.message_tics, p.frags, p.death_tics,
    CASE WHEN f.amount IS NOT NULL AND (p.health - (f.amount - f.saved)) <= 0 THEN -1 ELSE p.killer_id END AS killer_id,
    p.sprite_frame, p.t_x, p.t_y, p.t_z, p.t_angle, p.last_mode
  FROM (
    SELECT p.*,
           CASE WHEN gm.id IS NOT NULL THEN FALSE ELSE p.god_mode END AS god_mode2
    FROM P7 p
    LEFT JOIN (SELECT s.ntic, s.id FROM S2 s JOIN sector_special_defs sd ON sd.special = s.special
               AND sd.ends_level_at_low_health) gm ON gm.ntic = p.tic AND gm.id = p.sector_id
  ) p
  LEFT JOIN (
    SELECT k.ntic, k.sector_id, k.amount,
           LEAST(k.armor, CASE k.armor_class WHEN 2 THEN CAST(FLOOR(k.amount / 2.0D) AS INT)
                                             WHEN 1 THEN CAST(FLOOR(k.amount / 3.0D) AS INT) ELSE 0 END) AS saved
    FROM (
    SELECT s.ntic, s.id AS sector_id, p2.armor, p2.armor_class,
           sd.damage_per_hit >> CASE WHEN mp.skill = 0 THEN 1 ELSE 0 END AS amount
    FROM S2 s
    JOIN sector_special_defs sd ON sd.special = s.special AND sd.damage_per_hit IS NOT NULL
    JOIN mo_player mp ON mp.ntic = s.ntic
    JOIN P7 p2 ON p2.tic = s.ntic
    ) k
  ) f ON f.ntic = p.tic AND f.sector_id = p.sector_id
    AND p.alive AND p.radsuit_tics <= 0 AND NOT p.god_mode2 AND p.invuln_tics <= 0
    AND (p.level_tics % ${DAMAGE_FLOOR_INTERVAL}) = 0
),
-- ---------------------------------------------------------------- 29_cs_thing_physics
ph_moving AS (
  SELECT t.ntic, t.id, CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y,
         CAST(t.mom_x AS DOUBLE) AS mx, CAST(t.mom_y AS DOUBLE) AS my,
         CAST(cd.radius AS DOUBLE) AS radius, cd.skull_fly AS skull,
         cd.floats AND COALESCE(h.alive, FALSE) AND t.z > sec.floor_height AS airborne
  FROM T5r t
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN N3 rt ON rt.ntic = t.ntic AND rt.thing_id = t.id
  LEFT JOIN H5 h ON h.ntic = t.ntic AND h.thing_id = t.id
  LEFT JOIN I11 ai ON ai.ntic = t.ntic AND ai.thing_id = t.id
  JOIN S2 sec ON sec.ntic = t.ntic AND sec.id = COALESCE(ai.sector_id, rt.sector_id)
  WHERE (ABS(t.mom_x) > ${STOPSPEED} OR ABS(t.mom_y) > ${STOPSPEED}) AND t.id <> ${player}
),
ph_step AS (
  SELECT m.*, COALESCE(w.hit, FALSE) OR COALESCE(th.hit, FALSE) AS blocked
  FROM ph_moving m
  LEFT JOIN (
    SELECT m2.ntic, m2.id, TRUE AS hit
    FROM ph_moving m2
    JOIN linedef_geom ld ON ld.map_id = ${map_id}
    LEFT JOIN S2 fr ON fr.ntic = m2.ntic AND fr.id = ld.fsec
    LEFT JOIN S2 bk ON bk.ntic = m2.ntic AND bk.id = ld.bsec
    WHERE (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0
        OR (NOT m2.skull AND fr.floor_height IS NOT NULL AND bk.floor_height IS NOT NULL
            AND ABS(fr.floor_height - bk.floor_height) > ${MAXSTEP}))
      AND LEAST(ld.x1, ld.x2) <= GREATEST(m2.x, m2.x + m2.mx) + m2.radius
      AND GREATEST(ld.x1, ld.x2) >= LEAST(m2.x, m2.x + m2.mx) - m2.radius
      AND LEAST(ld.y1, ld.y2) <= GREATEST(m2.y, m2.y + m2.my) + m2.radius
      AND GREATEST(ld.y1, ld.y2) >= LEAST(m2.y, m2.y + m2.my) - m2.radius
      AND ((m2.x + m2.mx - ld.x1) * (ld.y2 - ld.y1) - (m2.y + m2.my - ld.y1) * (ld.x2 - ld.x1))
        * ((m2.x - ld.x1) * (ld.y2 - ld.y1) - (m2.y - ld.y1) * (ld.x2 - ld.x1)) < 0
      AND ((ld.x1 - m2.x) * m2.my - (ld.y1 - m2.y) * m2.mx)
        * ((ld.x2 - m2.x) * m2.my - (ld.y2 - m2.y) * m2.mx) < 0
    GROUP BY m2.ntic, m2.id
  ) w ON w.ntic = m.ntic AND w.id = m.id
  LEFT JOIN (
    SELECT m3.ntic, m3.id, TRUE AS hit
    FROM ph_moving m3
    JOIN T5r o ON o.ntic = m3.ntic AND o.id <> m3.id
    JOIN thing_combat_defs od ON od.thing_type = o.type
    JOIN H5 oh ON oh.ntic = o.ntic AND oh.thing_id = o.id AND oh.alive
    WHERE ABS(o.x - (m3.x + m3.mx)) < od.radius + m3.radius
      AND ABS(o.y - (m3.y + m3.my)) < od.radius + m3.radius
    GROUP BY m3.ntic, m3.id
  ) th ON th.ntic = m.ntic AND th.id = m.id
),
T6 AS (
  SELECT t.ntic, t.id, t.map_id,
    CASE WHEN s.id IS NULL OR s.blocked THEN t.x ELSE t.x + t.mom_x END AS x,
    CASE WHEN s.id IS NULL OR s.blocked THEN t.y ELSE t.y + t.mom_y END AS y,
    t.z, t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN s.id IS NULL THEN t.mom_x WHEN s.blocked THEN CAST(0 AS FLOAT)
         WHEN s.skull OR s.airborne THEN t.mom_x ELSE CAST(t.mom_x * ${FRICTION} AS FLOAT) END AS mom_x,
    CASE WHEN s.id IS NULL THEN t.mom_y WHEN s.blocked THEN CAST(0 AS FLOAT)
         WHEN s.skull OR s.airborne THEN t.mom_y ELSE CAST(t.mom_y * ${FRICTION} AS FLOAT) END AS mom_y,
    t.type, t.flags
  FROM T5r t LEFT JOIN ph_step s ON s.ntic = t.ntic AND s.id = t.id
),
T7 AS (
  -- Anything below STOPSPEED stands still.
  SELECT t.ntic, t.id, t.map_id, t.x, t.y, t.z, t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN ABS(t.mom_x) <= ${STOPSPEED} AND ABS(t.mom_y) <= ${STOPSPEED} THEN CAST(0 AS FLOAT) ELSE t.mom_x END AS mom_x,
    CASE WHEN ABS(t.mom_x) <= ${STOPSPEED} AND ABS(t.mom_y) <= ${STOPSPEED} THEN CAST(0 AS FLOAT) ELSE t.mom_y END AS mom_y,
    t.type, t.flags
  FROM T6 t
),
-- ---------------------------------------------------------------- 35_cs_boss
M3 AS (
  -- A_BossDeath for E1M8: once every boss is dead, tag 666 lowers to its
  -- lowest neighbouring floor. (E2M8's and E3M8's exits are the level flow's.)
  SELECT * FROM M2
  UNION ALL
  SELECT q.* FROM (
    SELECT s.ntic, ${map_id} AS map_id, s.id AS sector_id, CAST(NULL AS INT) AS source_line_id,
           'floor_lower' AS mover_type, 'floor' AS plane, -1 AS direction,
           MIN(o.floor_height) AS bottom_height, s.floor_height AS top_height, 1.0D AS speed, 0.0D AS move_carry,
           0 AS wait_tics, 0 AS countdown, CAST(NULL AS INT) AS next_ceiling, CAST(NULL AS INT) AS next_floor,
           CAST(NULL AS STRING) AS target_floor_tex, FALSE AS moved_this_tick, FALSE AS crush
    FROM (
      SELECT h.ntic FROM boss_actions ba
      JOIN maps m ON m.name = ba.map_name AND m.map_id = ${map_id}
      JOIN T7 t ON t.type = ba.boss_type
      JOIN H5 h ON h.ntic = t.ntic AND h.thing_id = t.id
      WHERE ba.action = 'lower_666'
      GROUP BY h.ntic, ba.map_name
      HAVING SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) = 0
    ) ready
    JOIN S2 s ON s.ntic = ready.ntic AND s.tag = 666
    JOIN sector_adjacency a ON a.map_id = ${map_id} AND a.sector_id = s.id AND a.other_id <> a.sector_id
    JOIN S2 o ON o.ntic = s.ntic AND o.id = a.other_id
    GROUP BY s.ntic, s.id, s.floor_height
    HAVING MIN(o.floor_height) < s.floor_height
  ) q
  LEFT ANTI JOIN M2 m ON m.ntic = q.ntic AND m.sector_id = q.sector_id
),
