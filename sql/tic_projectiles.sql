-- The rest of the hitscan shot, and the missiles. Follows tic_combat.sql.
--
-- Ported from cedardb/sqldoom sql/runtime/functions: what 23_cs_hitscan_apply
-- does to Things (the shove, the drops) and monster_ai (pain), and
-- 24_cs_projectiles, gated as 40_run_game_tic gates it (plan bit 64).
--
-- SQLDoom keeps positions, momenta and velocities in `real` columns, and
-- CedarDB keeps arithmetic on them in single precision: real with an integer
-- or a decimal literal is real, and so are POWER and SQRT of a real (FHYPOT).
-- Only a double operand promotes. Casts to integer truncate, and ROUND of a
-- double rounds half away from zero.
player_c AS (
  -- The player after tic_combat, in player_state's columns.
  SELECT p.tic, p.map_id, p.player_thing_id, p.p_health AS health, p.alive, p.level_tics,
    p.previous_x, p.previous_y, p.position_x, p.position_y, p.base_z, p.view_z, p.view_angle,
    p.momentum_x, p.momentum_y, p.bob_strength, p.previous_view_z, p.previous_view_angle,
    p.sector_id, p.pain_face_tics, p.p_armor AS armor, p.p_armor_class AS armor_class,
    p.p_backpack AS backpack, p.q_ammo_bullets AS ammo_bullets, p.q_ammo_shells AS ammo_shells,
    p.q_ammo_rockets AS ammo_rockets, p.q_ammo_cells AS ammo_cells,
    p.p_key_blue AS key_blue, p.p_key_yellow AS key_yellow, p.p_key_red AS key_red,
    p.p_radsuit_tics AS radsuit_tics, p.p_invis_tics AS invis_tics, p.momentum_z,
    p.damage_count, p.p_bonus_count AS bonus_count, p.p_light_amp_tics AS light_amp_tics,
    p.p_power_map AS power_map, p.god_mode, p.noclip, p.p_invuln_tics AS invuln_tics,
    p.berserk, p.p_message AS message, p.p_message_tics AS message_tics, p.frags,
    p.death_tics, p.killer_id, p.sprite_frame, p.t_x, p.t_y, p.t_z, p.t_angle, p.last_mode
  FROM P5 p
),
-- ---------------------------------------------------------------- 23_cs_hitscan_apply, cont.
hs_shooter AS (
  SELECT DISTINCT h.ntic, h.shot_serial, w.current_weapon
  FROM hitscan_hits h JOIN W1 w ON w.ntic = h.ntic
),
hs_shove AS (
  -- P_DamageMobj's thrust from the player's bullets (not the chainsaw's).
  SELECT q.ntic, q.thing_id,
    SUM(q.damage) * 12.5D / GREATEST(1, q.mass) AS push, q.dx, q.dy, q.dist
  FROM (
    SELECT h.ntic, h.thing_id, h.damage, cd.mass,
      CAST(v.x - CAST(p.t_x AS FLOAT) AS DOUBLE) AS dx, CAST(v.y - CAST(p.t_y AS FLOAT) AS DOUBLE) AS dy,
      CAST(NULLIF(FHYPOT(v.x - p.t_x, v.y - p.t_y), CAST(0 AS FLOAT)) AS DOUBLE) AS dist
    FROM hitscan_hits h
    JOIN T0 v ON v.ntic = h.ntic AND v.id = h.thing_id
    JOIN thing_combat_defs cd ON cd.thing_type = v.type
    JOIN player_c p ON p.tic = h.ntic
    JOIN hs_shooter s ON s.ntic = h.ntic
    WHERE h.hit_kind = 'target' AND h.damage > 0 AND s.current_weapon <> 8
      AND h.thing_id <> ${player}
  ) q
  GROUP BY q.ntic, q.thing_id, q.mass, q.dx, q.dy, q.dist
),
hs_died AS (
  SELECT DISTINCT h.ntic, h.thing_id
  FROM hitscan_hits h JOIN H1 th ON th.ntic = h.ntic AND th.thing_id = h.thing_id
  WHERE h.hit_kind = 'target' AND NOT th.alive
),
hs_drops AS (
  SELECT d.ntic, d.thing_id AS source_thing_id, t.x, t.y, t.angle, cd.drops_thing_type AS drop_type,
         COALESCE(ai.sector_id, rt.sector_id) AS sector_id
  FROM hs_died d
  JOIN T0 t ON t.ntic = d.ntic AND t.id = d.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.drops_thing_type IS NOT NULL
  LEFT JOIN I0 ai ON ai.ntic = d.ntic AND ai.thing_id = d.thing_id
  LEFT JOIN N0 rt ON rt.ntic = d.ntic AND rt.thing_id = d.thing_id
),
T1 AS (
  -- Things after the player's move and the shot: the player's Thing mirrors
  -- the player; a hit monster is shoved; a dead zombieman drops its clip.
  SELECT t.ntic, t.id, t.map_id,
    CASE WHEN t.id = ${player} THEN p.t_x ELSE t.x END AS x,
    CASE WHEN t.id = ${player} THEN p.t_y ELSE t.y END AS y,
    CASE WHEN t.id = ${player} THEN p.t_z ELSE t.z END AS z,
    CASE WHEN t.id = ${player} THEN p.t_angle ELSE t.angle END AS angle,
    t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN s.thing_id IS NOT NULL AND s.dist IS NOT NULL
         THEN CAST(t.mom_x + s.push * s.dx / s.dist AS FLOAT) ELSE t.mom_x END AS mom_x,
    CASE WHEN s.thing_id IS NOT NULL AND s.dist IS NOT NULL
         THEN CAST(t.mom_y + s.push * s.dy / s.dist AS FLOAT) ELSE t.mom_y END AS mom_y,
    t.type, t.flags
  FROM T0 t
  JOIN player_c p ON p.tic = t.ntic
  LEFT JOIN hs_shove s ON s.ntic = t.ntic AND s.thing_id = t.id
  UNION ALL
  SELECT d.ntic, ${DROPPED_THING_ID_BASE} + d.source_thing_id AS id, ${map_id} AS map_id,
    d.x, d.y, CAST(41 AS FLOAT) AS z, d.angle,
    CAST(d.x AS INT) AS spawn_x, CAST(d.y AS INT) AS spawn_y, CAST(d.angle AS INT) AS spawn_angle,
    CAST(0 AS FLOAT) AS mom_x, CAST(0 AS FLOAT) AS mom_y, d.drop_type AS type, 7 AS flags
  FROM hs_drops d
  LEFT ANTI JOIN T0 t ON t.ntic = d.ntic AND t.id = ${DROPPED_THING_ID_BASE} + d.source_thing_id
),
N1 AS (
  SELECT ntic, map_id, thing_id, sector_id, spawn_sector_id, sprite, frame, fullbright,
         spawn_ceiling, thing_height FROM N0
  UNION ALL
  SELECT d.ntic, ${map_id} AS map_id, ${DROPPED_THING_ID_BASE} + d.source_thing_id AS thing_id,
         d.sector_id, CAST(NULL AS INT) AS spawn_sector_id, ts.sprite, ts.frame, ts.fullbright,
         ts.spawn_ceiling, ts.thing_height
  FROM hs_drops d
  JOIN thing_sprite_defs ts ON ts.thing_type = d.drop_type
  LEFT ANTI JOIN N0 n ON n.ntic = d.ntic AND n.thing_id = ${DROPPED_THING_ID_BASE} + d.source_thing_id
  WHERE d.sector_id IS NOT NULL
),
hs_pain AS (
  SELECT h.ntic, h.thing_id, t.type,
         bool_or(PRANDOM(h.thing_id, h.shot_serial, 1) < cd.pain_chance) AS flinches
  FROM hitscan_hits h
  JOIN T0 t ON t.ntic = h.ntic AND t.id = h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  WHERE h.hit_kind = 'target' AND h.damage > 0
  GROUP BY h.ntic, h.thing_id, t.type
),
I1 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    CASE WHEN x.thing_id IS NULL THEN ai.state WHEN x.flinches THEN 'pain' ELSE 'see' END AS state,
    CASE WHEN x.thing_id IS NULL THEN ai.state_tics
         WHEN x.flinches THEN COALESCE(fp.tics, ai.state_tics) ELSE COALESCE(fs.tics, ai.state_tics) END AS state_tics,
    CASE WHEN x.thing_id IS NOT NULL AND x.flinches THEN 0 ELSE ai.seq_index END AS seq_index,
    ai.sector_id, ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id, ai.charge_tics,
    ai.movedir, ai.movecount
  FROM I0 ai
  LEFT JOIN (
    SELECT hp.* FROM hs_pain hp
    JOIN H1 h ON h.ntic = hp.ntic AND h.thing_id = hp.thing_id AND h.alive
    JOIN I0 a ON a.ntic = hp.ntic AND a.thing_id = hp.thing_id
    LEFT ANTI JOIN thing_combat_defs bd ON bd.thing_type = hp.type AND bd.explodes
    WHERE a.state NOT IN ('die', 'dead') AND (hp.flinches OR a.state = 'stand')
  ) x ON x.ntic = ai.ntic AND x.thing_id = ai.thing_id
  LEFT JOIN thing_ai_frames fp ON fp.thing_type = x.type AND fp.state = 'pain' AND fp.seq_index = 0
  LEFT JOIN thing_ai_frames fs ON fs.thing_type = x.type AND fs.state = 'see' AND fs.seq_index = 0
),
-- ---------------------------------------------------------------- 24_cs_projectiles
pj_due AS (
  -- Plan bit 64, as planned after the weapon stage.
  SELECT DISTINCT ntic FROM Q0
  UNION SELECT w.ntic FROM W1 w JOIN weapon_defs wd ON wd.weapon_id = w.current_weapon
    WHERE w.fired_this_tick AND wd.projectile_type IS NOT NULL
  UNION SELECT ai.ntic FROM I0 ai JOIN T0 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type
    WHERE ai.fired_this_tick AND d.missile_type IS NOT NULL
),
pj_level AS (
  SELECT p.tic AS ntic, p.level_tics, p.invis_tics > 0 AS shadowed, g.skill
  FROM player_c p JOIN pj_due d ON d.ntic = p.tic JOIN cmd g ON g.tic = p.tic
),
pj_monster_source AS (
  -- Imp fireballs: a monster on its attack frame with a missile, unless it
  -- is in melee range and has a bite.
  SELECT ai.ntic, ai.thing_id, CAST(t.x AS DOUBLE) AS sx, CAST(t.y AS DOUBLE) AS sy,
    CAST(CASE WHEN d.floats THEN t.z ELSE s.floor_height END + ${MISSILE_SPAWN_Z} AS DOUBLE) AS sz,
    CAST(pt.x AS DOUBLE) AS tx, CAST(pt.y AS DOUBLE) AS ty,
    CAST(pt.z - (${VIEWHEIGHT} - ${PLAYER_HEIGHT} / 2.0D) AS DOUBLE) AS tz,
    COALESCE(ai.sector_id, rt.sector_id) AS sector_id,
    d.missile_type, d.missile_speed, d.missile_dice, pd.dmg_dice_count
  FROM I1 ai
  JOIN pj_due due ON due.ntic = ai.ntic
  JOIN T1 t ON t.ntic = ai.ntic AND t.id = ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type AND d.missile_type IS NOT NULL
  JOIN projectile_defs pd ON pd.projectile_type = d.missile_type
  JOIN T1 pt ON pt.ntic = ai.ntic AND pt.id = COALESCE(ai.target_thing_id, ${player})
  LEFT JOIN N1 rt ON rt.ntic = ai.ntic AND rt.thing_id = ai.thing_id
  JOIN S2 s ON s.ntic = ai.ntic AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  WHERE ai.fired_this_tick
    AND (d.melee_mult IS NULL OR FHYPOT(pt.x - t.x, pt.y - t.y) > ${MELEE_REACH})
),
pj_monster_new AS (
  SELECT v.ntic, ${map_id} AS map_id,
    COALESCE(m.max_id, 0) + ROW_NUMBER() OVER (PARTITION BY v.ntic ORDER BY v.thing_id) AS projectile_id,
    v.thing_id AS owner_thing_id, v.missile_type AS projectile_type,
    CAST(v.sx + ${MISSILE_SPAWN_AHEAD} * v.dx / NULLIF(v.hlen, 0.0D) AS FLOAT) AS x,
    CAST(v.sy + ${MISSILE_SPAWN_AHEAD} * v.dy / NULLIF(v.hlen, 0.0D) AS FLOAT) AS y,
    CAST(v.sz AS FLOAT) AS z,
    CAST(v.speed * v.dx / NULLIF(v.hlen, 0.0D) AS FLOAT) AS vx,
    CAST(v.speed * v.dy / NULLIF(v.hlen, 0.0D) AS FLOAT) AS vy,
    CAST(v.speed * v.dz / NULLIF(v.hlen, 0.0D) AS FLOAT) AS vz,
    v.sector_id, 'fly' AS state, 0 AS age,
    v.missile_dice * (PRANDOM(v.thing_id, v.level_tics, 7) % v.dmg_dice_count + 1) AS damage,
    FALSE AS impact_player
  FROM (
    SELECT s.*, l.level_tics,
      CAST(CASE WHEN l.skill = 4 THEN ${NIGHTMARE_MISSILE_SPEED} ELSE s.missile_speed END AS DOUBLE) AS speed,
      (s.tx - s.sx) * COS(k.err) - (s.ty - s.sy) * SIN(k.err) AS dx,
      (s.tx - s.sx) * SIN(k.err) + (s.ty - s.sy) * COS(k.err) AS dy,
      s.tz - s.sz AS dz,
      SQRT(POWER(s.tx - s.sx, 2) + POWER(s.ty - s.sy, 2)) AS hlen
    FROM pj_monster_source s
    JOIN pj_level l ON l.ntic = s.ntic
    JOIN (
      SELECT s2.ntic, s2.thing_id,
        CASE WHEN l2.shadowed
             THEN RADIANS((PRANDOM(s2.thing_id, l2.level_tics, 5) - PRANDOM(s2.thing_id, l2.level_tics, 6))
                          * 360.0D / ${SHADOW_SPREAD_UNITS})
             ELSE 0.0D END AS err
      FROM pj_monster_source s2 JOIN pj_level l2 ON l2.ntic = s2.ntic
    ) k ON k.ntic = s.ntic AND k.thing_id = s.thing_id
  ) v
  LEFT JOIN (SELECT ntic, MAX(projectile_id) AS max_id FROM Q0 GROUP BY ntic) m ON m.ntic = v.ntic
  WHERE v.hlen > 0
),
Q0b AS (
  SELECT ntic, map_id, projectile_id, owner_thing_id, projectile_type, x, y, z, vx, vy, vz,
         sector_id, state, age, damage, impact_player FROM Q0
  UNION ALL
  SELECT * FROM pj_monster_new
),
pj_player_source AS (
  SELECT w.ntic, w.player_thing_id, CAST(t.x AS DOUBLE) AS sx, CAST(t.y AS DOUBLE) AS sy,
    CAST(t.z - (${VIEWHEIGHT} - ${MISSILE_SPAWN_Z}) AS DOUBLE) AS sz,
    RADIANS(CAST(t.angle AS DOUBLE)) AS angle, wd.projectile_type,
    CAST(pd.speed AS DOUBLE) AS speed,
    pd.dmg_dice_mult * (PRANDOM(w.shot_serial, w.player_thing_id, pd.dmg_random_id) % pd.dmg_dice_count + 1) AS damage,
    rt.sector_id
  FROM W1 w
  JOIN pj_due due ON due.ntic = w.ntic
  JOIN weapon_defs wd ON wd.weapon_id = w.current_weapon AND wd.projectile_type IS NOT NULL
  JOIN projectile_defs pd ON pd.projectile_type = wd.projectile_type
  JOIN T1 t ON t.ntic = w.ntic AND t.id = w.player_thing_id
  LEFT JOIN N1 rt ON rt.ntic = w.ntic AND rt.thing_id = t.id
  WHERE w.fired_this_tick
),
pj_player_aim AS (
  SELECT r.ntic, r.player_thing_id, r.tz, r.along FROM (
    SELECT g.*, ROW_NUMBER() OVER (PARTITION BY g.ntic, g.player_thing_id
      ORDER BY ABS(g.lateral_offset) / NULLIF(g.along, 0.0D), g.along, g.target_id) AS rn
    FROM (
      SELECT s.ntic, s.player_thing_id, mt.id AS target_id,
        CAST(sec.floor_height + rt.thing_height / 2.0D AS DOUBLE) AS tz,
        CAST(cd.radius AS DOUBLE) AS radius,
        (CAST(mt.x AS DOUBLE) - s.sx) * COS(s.angle) + (CAST(mt.y AS DOUBLE) - s.sy) * SIN(s.angle) AS along,
        -(CAST(mt.x AS DOUBLE) - s.sx) * SIN(s.angle) + (CAST(mt.y AS DOUBLE) - s.sy) * COS(s.angle) AS lateral_offset
      FROM pj_player_source s
      JOIN H1 h ON h.ntic = s.ntic AND h.alive
      JOIN T1 mt ON mt.ntic = s.ntic AND mt.id = h.thing_id
      JOIN thing_combat_defs cd ON cd.thing_type = mt.type
      JOIN N1 rt ON rt.ntic = s.ntic AND rt.thing_id = mt.id
      LEFT JOIN I1 ai ON ai.ntic = s.ntic AND ai.thing_id = mt.id
      JOIN S2 sec ON sec.ntic = s.ntic AND sec.id = COALESCE(ai.sector_id, rt.sector_id)
    ) g
    WHERE g.along > 0 AND ABS(g.lateral_offset) <= g.radius + g.along * TAN(RADIANS(${AIM_SPREAD_DEGREES}))
  ) r WHERE r.rn = 1
),
pj_player_new AS (
  SELECT s.ntic, ${map_id} AS map_id,
    COALESCE(m.max_id, 0) + ROW_NUMBER() OVER (PARTITION BY s.ntic ORDER BY s.player_thing_id) AS projectile_id,
    s.player_thing_id AS owner_thing_id, s.projectile_type,
    CAST(s.sx AS FLOAT) AS x, CAST(s.sy AS FLOAT) AS y, CAST(s.sz AS FLOAT) AS z,
    CAST(s.speed * COS(s.angle) AS FLOAT) AS vx, CAST(s.speed * SIN(s.angle) AS FLOAT) AS vy,
    CAST(s.speed * COALESCE((a.tz - s.sz) / NULLIF(a.along, 0.0D), 0.0D) AS FLOAT) AS vz,
    s.sector_id, 'fly' AS state, 0 AS age, s.damage, FALSE AS impact_player
  FROM pj_player_source s
  LEFT JOIN pj_player_aim a ON a.ntic = s.ntic AND a.player_thing_id = s.player_thing_id
  LEFT JOIN (SELECT ntic, MAX(projectile_id) AS max_id FROM Q0b GROUP BY ntic) m ON m.ntic = s.ntic
),
Q1 AS (
  SELECT * FROM Q0b
  UNION ALL
  SELECT * FROM pj_player_new
),
pj_flying AS (
  SELECT q.*, CAST(pd.radius AS DOUBLE) AS radius
  FROM Q1 q
  JOIN pj_due due ON due.ntic = q.ntic
  JOIN projectile_defs pd ON pd.projectile_type = q.projectile_type
  WHERE q.state = 'fly'
),
pj_actor_targets AS (
  SELECT h.ntic, h.thing_id, t.type AS thing_type, CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y,
         CAST(cd.radius AS DOUBLE) AS radius, CAST(sec.floor_height AS DOUBLE) AS base_z,
         CAST(rt.thing_height AS DOUBLE) AS height
  FROM H1 h
  JOIN pj_due due ON due.ntic = h.ntic
  JOIN T1 t ON t.ntic = h.ntic AND t.id = h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN N1 rt ON rt.ntic = h.ntic AND rt.thing_id = t.id
  LEFT JOIN I1 ai ON ai.ntic = h.ntic AND ai.thing_id = t.id
  JOIN S2 sec ON sec.ntic = h.ntic AND sec.id = COALESCE(ai.sector_id, rt.sector_id)
  WHERE h.alive
),
pj_candidates AS (
  -- Swept collision: the player, other actors, walls.
  SELECT q.ntic, q.projectile_id, q.t, TRUE AS target_player, q.target_thing_id, 0 AS priority
  FROM (
    SELECT f.ntic, f.projectile_id, f.x, f.y, f.z, f.vx, f.vy, f.vz, f.radius,
      p.player_thing_id AS target_thing_id, CAST(p.t_x AS DOUBLE) AS px, CAST(p.t_y AS DOUBLE) AS py,
      CAST(p.base_z - ${VIEWHEIGHT} AS DOUBLE) AS pz,
      LEAST(1.0D, GREATEST(0.0D,
        ((CAST(p.t_x AS DOUBLE) - f.x) * f.vx + (CAST(p.t_y AS DOUBLE) - f.y) * f.vy)
        / NULLIF(f.vx * f.vx + f.vy * f.vy, CAST(0 AS FLOAT)))) AS t
    FROM pj_flying f
    JOIN player_c p ON p.tic = f.ntic AND p.alive AND p.player_thing_id <> f.owner_thing_id
  ) q
  WHERE POWER(q.x + q.t * q.vx - q.px, 2) + POWER(q.y + q.t * q.vy - q.py, 2) <= POWER(q.radius + ${PLAYER_RADIUS}, 2)
    AND q.z + q.t * q.vz BETWEEN q.pz AND q.pz + ${PLAYER_HEIGHT}
  UNION ALL
  SELECT r.ntic, r.projectile_id, r.t, FALSE, r.thing_id, 0 FROM (
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.ntic, c.projectile_id ORDER BY c.t, c.thing_id) AS rn
    FROM (
      SELECT q.ntic, q.projectile_id, q.thing_id, q.t
      FROM (
        SELECT f.*, a.thing_id, a.thing_type, a.x AS ax, a.y AS ay, a.radius AS aradius, a.base_z, a.height,
          ot.type AS owner_type,
          LEAST(1.0D, GREATEST(0.0D, ((a.x - f.x) * f.vx + (a.y - f.y) * f.vy)
            / NULLIF(f.vx * f.vx + f.vy * f.vy, CAST(0 AS FLOAT)))) AS t
        FROM pj_flying f
        JOIN pj_actor_targets a ON a.ntic = f.ntic
        LEFT JOIN T1 ot ON ot.ntic = f.ntic AND ot.id = f.owner_thing_id
      ) q
      WHERE (q.projectile_type IN ('rocket', 'plasma', 'bfg')
             OR (q.projectile_type IN ('imp_fireball', 'baron_fireball', 'caco_fireball')
                 AND (q.owner_type IS NULL OR q.owner_type <> q.thing_type)))
        AND q.thing_id <> q.owner_thing_id
        AND POWER(q.x + q.t * q.vx - q.ax, 2) + POWER(q.y + q.t * q.vy - q.ay, 2) <= POWER(q.radius + q.aradius, 2)
        AND q.z + q.t * q.vz BETWEEN q.base_z AND q.base_z + q.height
    ) c
  ) r WHERE r.rn = 1
  UNION ALL
  SELECT w.ntic, w.projectile_id, MIN(w.t) AS t, FALSE, CAST(NULL AS INT), 1
  FROM (
    SELECT q.ntic, q.projectile_id, q.t
    FROM (
      SELECT f.ntic, f.projectile_id, f.z, f.vz, ld.left_sd_id, ld.right_sd_id,
        fr.id AS fr_id, bk.id AS bk_id, fr.floor_height AS fr_floor, bk.floor_height AS bk_floor,
        fr.ceil_height AS fr_ceil, bk.ceil_height AS bk_ceil,
        f.vx * (ld.y2 - ld.y1) - f.vy * (ld.x2 - ld.x1) AS denom,
        ((ld.x1 - f.x) * (ld.y2 - ld.y1) - (ld.y1 - f.y) * (ld.x2 - ld.x1))
          / NULLIF(f.vx * (ld.y2 - ld.y1) - f.vy * (ld.x2 - ld.x1), CAST(0 AS FLOAT)) AS t,
        ((ld.x1 - f.x) * f.vy - (ld.y1 - f.y) * f.vx)
          / NULLIF(f.vx * (ld.y2 - ld.y1) - f.vy * (ld.x2 - ld.x1), CAST(0 AS FLOAT)) AS u
      FROM pj_flying f
      JOIN linedef_geom ld ON ld.map_id = ${map_id}
      LEFT JOIN S2 fr ON fr.ntic = f.ntic AND fr.id = ld.fsec
      LEFT JOIN S2 bk ON bk.ntic = f.ntic AND bk.id = ld.bsec
    ) q
    WHERE ABS(q.denom) > 1e-9D AND q.t BETWEEN 0.0D AND 1.0D AND q.u BETWEEN 0.0D AND 1.0D
      AND (q.left_sd_id = -1 OR q.right_sd_id = -1 OR q.fr_id IS NULL OR q.bk_id IS NULL
        OR q.z + q.t * q.vz <= GREATEST(q.fr_floor, q.bk_floor)
        OR q.z + q.t * q.vz >= LEAST(q.fr_ceil, q.bk_ceil))
  ) w
  GROUP BY w.ntic, w.projectile_id
),
projectile_impacts AS (
  SELECT f.ntic, f.projectile_id, f.projectile_type, f.owner_thing_id,
    CAST(f.x + n.t * f.vx AS FLOAT) AS x, CAST(f.y + n.t * f.vy AS FLOAT) AS y,
    CAST(f.z + n.t * f.vz AS FLOAT) AS z,
    n.target_player, n.target_thing_id,
    CASE WHEN n.target_player THEN n.target_thing_id END AS target_player_thing_id
  FROM (
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.ntic, c.projectile_id
      ORDER BY c.t, c.priority, COALESCE(c.target_thing_id, -1)) AS rn
    FROM pj_candidates c
  ) n
  JOIN pj_flying f ON f.ntic = n.ntic AND f.projectile_id = n.projectile_id
  WHERE n.rn = 1
),
pj_blocking AS (
  SELECT d.ntic, CAST(ld.x1 AS DOUBLE) AS x1, CAST(ld.y1 AS DOUBLE) AS y1,
         CAST(ld.x2 AS DOUBLE) AS x2, CAST(ld.y2 AS DOUBLE) AS y2
  FROM pj_due d
  JOIN linedef_geom ld ON ld.map_id = ${map_id}
  LEFT JOIN S2 fr ON fr.ntic = d.ntic AND fr.id = ld.fsec
  LEFT JOIN S2 bk ON bk.ntic = d.ntic AND bk.id = ld.bsec
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height, bk.ceil_height) <= GREATEST(fr.floor_height, bk.floor_height)
),
pj_victims AS (
  SELECT h.ntic, h.thing_id, CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y, CAST(cd.radius AS DOUBLE) AS radius
  FROM H1 h JOIN pj_due d ON d.ntic = h.ntic
  JOIN T1 t ON t.ntic = h.ntic AND t.id = h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  WHERE h.alive
  UNION ALL
  SELECT p.tic, p.player_thing_id, CAST(t.x AS DOUBLE), CAST(t.y AS DOUBLE), ${PLAYER_RADIUS}
  FROM player_c p JOIN pj_due d ON d.ntic = p.tic
  JOIN T1 t ON t.ntic = p.tic AND t.id = p.player_thing_id
  WHERE p.alive
),
pj_splash AS (
  -- P_RadiusAttack, for whatever has a blast radius (the rocket).
  SELECT q.ntic, q.projectile_id, 'splash' AS damage_kind, q.thing_id AS hit_index, q.thing_id,
         CAST(q.damage AS INT) AS damage
  FROM (
    SELECT e.ntic, e.projectile_id, v.thing_id, e.x AS ex, e.y AS ey, v.x AS vx, v.y AS vy,
      GREATEST(CAST(0 AS FLOAT), pd.blast_radius - GREATEST(0, CAST(FLOOR(GREATEST(ABS(v.x - e.x), ABS(v.y - e.y)) - v.radius) AS INT))) AS damage
    FROM projectile_impacts e
    JOIN projectile_defs pd ON pd.projectile_type = e.projectile_type AND pd.blast_radius IS NOT NULL
    JOIN pj_victims v ON v.ntic = e.ntic
    WHERE GREATEST(ABS(v.x - e.x), ABS(v.y - e.y)) - v.radius < pd.blast_radius
  ) q
  LEFT ANTI JOIN pj_blocking b ON b.ntic = q.ntic
    AND ((q.ex - b.x1) * (b.y2 - b.y1) - (q.ey - b.y1) * (b.x2 - b.x1))
      * ((q.vx - b.x1) * (b.y2 - b.y1) - (q.vy - b.y1) * (b.x2 - b.x1)) < 0
    AND ((b.x1 - q.ex) * (q.vy - q.ey) - (b.y1 - q.ey) * (q.vx - q.ex))
      * ((b.x2 - q.ex) * (q.vy - q.ey) - (b.y2 - q.ey) * (q.vx - q.ex)) < 0
  WHERE q.damage > 0
),
pj_bfg_hits AS (
  -- A_BFGSpray: spray_rays rays across spray_arc_degrees, the nearest visible
  -- target on each.
  SELECT r.* FROM (
    SELECT i.*, ROW_NUMBER() OVER (PARTITION BY i.ntic, i.projectile_id, i.ray_index ORDER BY i.distance, i.thing_id) AS rn
    FROM (
      SELECT g.*, g.along - SQRT(GREATEST(0.0D, g.radius * g.radius - g.perp2)) AS distance
      FROM (
        SELECT y.*, v.thing_id, v.x, v.y, v.radius,
          (v.x - y.ox) * COS(y.ray_angle) + (v.y - y.oy) * SIN(y.ray_angle) AS along,
          POWER(-(v.x - y.ox) * SIN(y.ray_angle) + (v.y - y.oy) * COS(y.ray_angle), 2) AS perp2
        FROM (
          SELECT b.*, ATAN2(b.vy, b.vx) + RADIANS(-b.spray_arc_degrees / 2.0D
                 + (b.spray_arc_degrees / b.spray_rays) * b.ray_index) AS ray_angle
          FROM (
            SELECT q.ntic, q.projectile_id, q.owner_thing_id, q.vx, q.vy,
                   CAST(t.x AS DOUBLE) AS ox, CAST(t.y AS DOUBLE) AS oy,
                   pd.spray_rays, pd.spray_arc_degrees, pd.spray_range, pd.spray_dice,
                   pd.spray_random_base, pd.dmg_dice_count,
                   explode(sequence(0, pd.spray_rays - 1)) AS ray_index
            FROM Q1 q
            JOIN pj_due d ON d.ntic = q.ntic
            JOIN T1 t ON t.ntic = q.ntic AND t.id = q.owner_thing_id
            JOIN projectile_defs pd ON pd.projectile_type = q.projectile_type
            WHERE q.state = 'explode' AND pd.spray_at_tic IS NOT NULL AND q.age = pd.spray_at_tic
          ) b
        ) y
        JOIN pj_victims v ON v.ntic = y.ntic AND v.thing_id <> y.owner_thing_id
      ) g
      WHERE g.along > 0 AND g.along <= g.spray_range + g.radius AND g.perp2 <= g.radius * g.radius
    ) i
    LEFT ANTI JOIN pj_blocking b ON b.ntic = i.ntic
      AND ((i.ox - b.x1) * (b.y2 - b.y1) - (i.oy - b.y1) * (b.x2 - b.x1))
        * ((i.x - b.x1) * (b.y2 - b.y1) - (i.y - b.y1) * (b.x2 - b.x1)) < 0
      AND ((b.x1 - i.ox) * (i.y - i.oy) - (b.y1 - i.oy) * (i.x - i.ox))
        * ((b.x2 - i.ox) * (i.y - i.oy) - (b.y2 - i.oy) * (i.x - i.ox)) < 0
    WHERE i.distance > 0 AND i.distance <= i.spray_range
  ) r WHERE r.rn = 1
),
projectile_damage AS (
  SELECT i.ntic, i.projectile_id, 'direct' AS damage_kind, -1 AS hit_index, i.target_thing_id AS thing_id,
         q.damage
  FROM projectile_impacts i
  JOIN Q1 q ON q.ntic = i.ntic AND q.projectile_id = i.projectile_id
  WHERE i.target_thing_id IS NOT NULL
    AND i.projectile_type IN ('rocket', 'plasma', 'bfg', 'imp_fireball', 'baron_fireball', 'caco_fireball')
  UNION ALL
  SELECT ntic, projectile_id, damage_kind, hit_index, thing_id, damage FROM pj_splash
  UNION ALL
  SELECT h.ntic, h.projectile_id, 'bfg_spray', h.ray_index, h.thing_id,
         CAST(aggregate(transform(sequence(0, h.spray_dice - 1),
           k -> PRANDOM(h.thing_id, h.projectile_id * 64 + h.ray_index, h.spray_random_base + k) % h.dmg_dice_count + 1),
           0, (acc, v) -> acc + v) AS INT)
  FROM pj_bfg_hits h
),
pj_actor_damage AS (
  SELECT ntic, thing_id, CAST(SUM(damage) AS INT) AS damage FROM projectile_damage GROUP BY ntic, thing_id
),
H2 AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN d.thing_id IS NULL THEN h.health ELSE h.health - d.damage END AS health, h.max_health,
    CASE WHEN d.thing_id IS NULL THEN h.alive ELSE h.health - d.damage > 0 END AS alive
  FROM H1 h LEFT JOIN pj_actor_damage d ON d.ntic = h.ntic AND d.thing_id = h.thing_id
),
pj_thrust AS (
  SELECT q.ntic, q.thing_id,
    SUM(ROUND(q.push * q.dx / q.dist * 65536)) / 65536.0D AS ddx,
    SUM(ROUND(q.push * q.dy / q.dist * 65536)) / 65536.0D AS ddy
  FROM (
    SELECT pd.ntic, pd.thing_id, pd.damage * 12.5D / GREATEST(1, cd.mass) AS push,
      CAST(v.x - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.x ELSE i.x END AS DOUBLE) AS dx,
      CAST(v.y - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.y ELSE i.y END AS DOUBLE) AS dy,
      CAST(NULLIF(FHYPOT(v.x - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.x ELSE i.x END,
                         v.y - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.y ELSE i.y END),
                  CAST(0 AS FLOAT)) AS DOUBLE) AS dist
    FROM projectile_damage pd
    JOIN T1 v ON v.ntic = pd.ntic AND v.id = pd.thing_id
    JOIN thing_combat_defs cd ON cd.thing_type = v.type
    JOIN T1 pl ON pl.ntic = pd.ntic AND pl.id = ${player}
    LEFT JOIN projectile_impacts i ON i.ntic = pd.ntic AND i.projectile_id = pd.projectile_id
    WHERE pd.damage > 0 AND pd.thing_id <> ${player}
  ) q
  WHERE q.dist IS NOT NULL
  GROUP BY q.ntic, q.thing_id
),
T2 AS (
  SELECT t.ntic, t.id, t.map_id, t.x, t.y, t.z, t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
    CASE WHEN s.thing_id IS NULL THEN t.mom_x ELSE CAST(t.mom_x + s.ddx AS FLOAT) END AS mom_x,
    CASE WHEN s.thing_id IS NULL THEN t.mom_y ELSE CAST(t.mom_y + s.ddy AS FLOAT) END AS mom_y,
    t.type, t.flags
  FROM T1 t LEFT JOIN pj_thrust s ON s.ntic = t.ntic AND s.thing_id = t.id
),
pj_retarget AS (
  -- A hurt monster turns on whatever hit it.
  SELECT d.ntic, d.thing_id, max_by(i.owner_thing_id, i.projectile_id) AS owner_thing_id
  FROM projectile_damage d
  JOIN projectile_impacts i ON i.ntic = d.ntic AND i.projectile_id = d.projectile_id
  LEFT JOIN I1 mo ON mo.ntic = i.ntic AND mo.thing_id = i.owner_thing_id
  WHERE (i.projectile_type IN ('imp_fireball', 'baron_fireball', 'caco_fireball') OR mo.thing_id IS NOT NULL)
    AND i.owner_thing_id IS NOT NULL
  GROUP BY d.ntic, d.thing_id
),
I2a AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    CASE WHEN r.thing_id IS NOT NULL AND ai.state = 'stand' THEN 'see' ELSE ai.state END AS state,
    CASE WHEN r.thing_id IS NOT NULL AND ai.state = 'stand' THEN 0 ELSE ai.state_tics END AS state_tics,
    CASE WHEN r.thing_id IS NOT NULL AND ai.state = 'stand' THEN 0 ELSE ai.seq_index END AS seq_index,
    ai.sector_id, ai.attack_cooldown, ai.fired_this_tick,
    CASE WHEN r.thing_id IS NOT NULL THEN r.owner_thing_id ELSE ai.target_thing_id END AS target_thing_id,
    ai.charge_tics, ai.movedir, ai.movecount
  FROM I1 ai
  LEFT JOIN pj_retarget r ON r.ntic = ai.ntic AND r.thing_id = ai.thing_id
    AND ai.thing_id <> r.owner_thing_id
    AND (ai.target_thing_id IS NULL OR ai.target_thing_id <> r.owner_thing_id)
),
pj_pain AS (
  SELECT d.ntic, d.thing_id, t.type,
         bool_or(PRANDOM(d.thing_id, d.projectile_id, 11) < cd.pain_chance) AS flinches
  FROM projectile_damage d
  JOIN T2 t ON t.ntic = d.ntic AND t.id = d.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  WHERE d.damage > 0
  GROUP BY d.ntic, d.thing_id, t.type
),
I2 AS (
  SELECT ai.ntic, ai.map_id, ai.thing_id,
    CASE WHEN x.thing_id IS NULL THEN ai.state WHEN x.flinches THEN 'pain' ELSE 'see' END AS state,
    CASE WHEN x.thing_id IS NULL THEN ai.state_tics
         WHEN x.flinches THEN COALESCE(fp.tics, ai.state_tics) ELSE COALESCE(fs.tics, ai.state_tics) END AS state_tics,
    CASE WHEN x.thing_id IS NOT NULL AND x.flinches THEN 0 ELSE ai.seq_index END AS seq_index,
    ai.sector_id, ai.attack_cooldown, ai.fired_this_tick, ai.target_thing_id, ai.charge_tics,
    ai.movedir, ai.movecount
  FROM I2a ai
  LEFT JOIN (
    SELECT pp.* FROM pj_pain pp
    JOIN H2 h ON h.ntic = pp.ntic AND h.thing_id = pp.thing_id AND h.alive
    JOIN I2a a ON a.ntic = pp.ntic AND a.thing_id = pp.thing_id
    LEFT ANTI JOIN thing_combat_defs bd ON bd.thing_type = pp.type AND bd.explodes
    WHERE a.state NOT IN ('die', 'dead') AND (pp.flinches OR a.state = 'stand')
  ) x ON x.ntic = ai.ntic AND x.thing_id = ai.thing_id
  LEFT JOIN thing_ai_frames fp ON fp.thing_type = x.type AND fp.state = 'pain' AND fp.seq_index = 0
  LEFT JOIN thing_ai_frames fs ON fs.thing_type = x.type AND fs.state = 'see' AND fs.seq_index = 0
),
X3 AS (
  -- The BFG spray's explosions.
  SELECT * FROM X2
  UNION ALL
  SELECT q.* FROM (
    SELECT d.ntic, ${map_id} AS map_id,
      CAST(${PROJECTILE_EFFECT_ID_BASE} AS BIGINT) + d.projectile_id * 100 + d.hit_index AS effect_id,
      'bfg_spray' AS effect_type, t.x, t.y,
      CAST(sec.floor_height + rt.thing_height / 4.0D AS FLOAT) AS z,
      COALESCE(ai.sector_id, rt.sector_id) AS sector_id, 0 AS age
    FROM projectile_damage d
    JOIN T2 t ON t.ntic = d.ntic AND t.id = d.thing_id
    JOIN N1 rt ON rt.ntic = d.ntic AND rt.thing_id = t.id
    LEFT JOIN I2 ai ON ai.ntic = d.ntic AND ai.thing_id = t.id
    JOIN S2 sec ON sec.ntic = d.ntic AND sec.id = COALESCE(ai.sector_id, rt.sector_id)
    WHERE d.damage_kind = 'bfg_spray'
  ) q
  LEFT ANTI JOIN X2 x ON x.ntic = q.ntic AND x.effect_id = q.effect_id
),
pj_player_hurt AS (
  SELECT t.* FROM (
    SELECT s.ntic, CAST(SUM(s.dmg) AS INT) AS dmg,
           CAST(SUM(FLOOR(s.dmg / 3.0D)) AS INT) AS green_saved,
           CAST(SUM(FLOOR(s.dmg / 2.0D)) AS INT) AS blue_saved,
           max_by(s.source_id, CAST(s.dmg AS BIGINT) * 1000000 + s.source_id) AS source_id,
           SUM(ROUND(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * (s.vx - s.ix) / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_x,
           SUM(ROUND(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * (s.vy - s.iy) / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_y
    FROM (
      SELECT r.*, SQRT(POWER(r.vx - r.ix, 2) + POWER(r.vy - r.iy, 2)) AS dist FROM (
        SELECT pd.ntic, pd.damage >> CASE WHEN g.skill = 0 THEN 1 ELSE 0 END AS dmg,
               CAST(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.x ELSE i.x END AS DOUBLE) AS ix,
               CAST(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.y ELSE i.y END AS DOUBLE) AS iy,
               CASE WHEN q.owner_thing_id = ${player} THEN ${player} ELSE -1 END AS source_id,
               CAST(vt.x AS DOUBLE) AS vx, CAST(vt.y AS DOUBLE) AS vy
        FROM projectile_damage pd
        JOIN player_c p ON p.tic = pd.ntic AND p.player_thing_id = pd.thing_id
        JOIN cmd g ON g.tic = pd.ntic
        JOIN T2 vt ON vt.ntic = pd.ntic AND vt.id = pd.thing_id
        JOIN Q1 q ON q.ntic = pd.ntic AND q.projectile_id = pd.projectile_id
        LEFT JOIN projectile_impacts i ON i.ntic = pd.ntic AND i.projectile_id = pd.projectile_id
        LEFT JOIN T2 ot ON ot.ntic = pd.ntic AND ot.id = q.owner_thing_id
        WHERE pd.damage > 0
      ) r
    ) s
    GROUP BY s.ntic
  ) t
),
P6 AS (
  -- 24_cs_projectiles' P_DamageMobj on the player.
  SELECT q.tic, q.map_id, q.player_thing_id,
    CASE WHEN q.ntic IS NULL THEN q.health ELSE GREATEST(0, q.health - q.took) END AS health,
    CASE WHEN q.ntic IS NULL THEN q.alive ELSE GREATEST(0, q.health - q.took) > 0 END AS alive,
    q.level_tics, q.previous_x, q.previous_y, q.position_x, q.position_y, q.base_z, q.view_z, q.view_angle,
    CASE WHEN q.ntic IS NULL THEN q.momentum_x ELSE CAST(q.momentum_x + q.thrust_x AS FLOAT) END AS momentum_x,
    CASE WHEN q.ntic IS NULL THEN q.momentum_y ELSE CAST(q.momentum_y + q.thrust_y AS FLOAT) END AS momentum_y,
    q.bob_strength, q.previous_view_z, q.previous_view_angle, q.sector_id,
    CASE WHEN q.took > 0 THEN 12 ELSE q.pain_face_tics END AS pain_face_tics,
    q.armor - q.saved AS armor,
    CASE WHEN q.ntic IS NOT NULL AND q.armor - q.saved <= 0 THEN 0 ELSE q.armor_class END AS armor_class,
    q.backpack, q.ammo_bullets, q.ammo_shells, q.ammo_rockets, q.ammo_cells,
    q.key_blue, q.key_yellow, q.key_red, q.radsuit_tics, q.invis_tics, q.momentum_z,
    CASE WHEN q.ntic IS NULL THEN q.damage_count ELSE LEAST(100, q.damage_count + q.took) END AS damage_count,
    q.bonus_count, q.light_amp_tics, q.power_map, q.god_mode, q.noclip, q.invuln_tics,
    q.berserk, q.message, q.message_tics, q.frags, q.death_tics,
    CASE WHEN q.ntic IS NOT NULL AND q.alive AND q.health - q.took <= 0 THEN q.source_id ELSE q.killer_id END AS killer_id,
    q.sprite_frame, q.t_x, q.t_y, q.t_z, q.t_angle, q.last_mode
  FROM (
    SELECT p.*, h.ntic, h.source_id, h.thrust_x, h.thrust_y,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE LEAST(p.armor, CASE p.armor_class WHEN 2 THEN h.blue_saved
                                                           WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS saved,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE h.dmg - LEAST(p.armor, CASE p.armor_class WHEN 2 THEN h.blue_saved
                                                                   WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS took
    FROM player_c p LEFT JOIN pj_player_hurt h ON h.ntic = p.tic
  ) q
),
Q2 AS (
  -- Impacts explode, the rest fly on; explosions age; finished ones go.
  SELECT q.ntic, q.map_id, q.projectile_id, q.owner_thing_id, q.projectile_type,
    CASE WHEN i.projectile_id IS NOT NULL AND q.state = 'fly' THEN i.x
         WHEN q.state = 'fly' THEN q.x + q.vx ELSE q.x END AS x,
    CASE WHEN i.projectile_id IS NOT NULL AND q.state = 'fly' THEN i.y
         WHEN q.state = 'fly' THEN q.y + q.vy ELSE q.y END AS y,
    CASE WHEN i.projectile_id IS NOT NULL AND q.state = 'fly' THEN i.z
         WHEN q.state = 'fly' THEN q.z + q.vz ELSE q.z END AS z,
    q.vx, q.vy, q.vz, q.sector_id,
    CASE WHEN i.projectile_id IS NOT NULL AND q.state = 'fly' THEN 'explode' ELSE q.state END AS state,
    CASE WHEN i.projectile_id IS NOT NULL AND q.state = 'fly' THEN 1
         ELSE q.age + 1 END AS age,
    q.damage, FALSE AS impact_player,
    pd.explode_tics, pd.fly_timeout
  FROM Q1 q
  JOIN projectile_defs pd ON pd.projectile_type = q.projectile_type
  LEFT JOIN projectile_impacts i ON i.ntic = q.ntic AND i.projectile_id = q.projectile_id
),
Q3 AS (
  SELECT q.ntic, q.map_id, q.projectile_id, q.owner_thing_id, q.projectile_type, q.x, q.y, q.z,
         q.vx, q.vy, q.vz, q.sector_id, q.state, q.age, q.damage, q.impact_player
  FROM Q1 q LEFT ANTI JOIN pj_due d ON d.ntic = q.ntic
  UNION ALL
  SELECT q.ntic, q.map_id, q.projectile_id, q.owner_thing_id, q.projectile_type, q.x, q.y, q.z,
         q.vx, q.vy, q.vz, q.sector_id, q.state, q.age, q.damage, q.impact_player
  FROM Q2 q JOIN pj_due d ON d.ntic = q.ntic
  WHERE NOT ((q.state = 'explode' AND q.age >= q.explode_tics) OR (q.state = 'fly' AND q.age >= q.fly_timeout))
),
