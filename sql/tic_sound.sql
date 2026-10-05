-- The sound stage and the tic's stage trace. Follows tic_projectiles.sql and
-- precedes tic_monsters.sql, where 40_run_game_tic runs 25_cs_sound.
--
-- sound_due is 10_cs_plan's bit 128 as doom_run_tic_core accumulates it: an
-- OR over the plans taken after the clock, after the movement, after the
-- pickups (when the player moved), after the weapon, and after the
-- projectiles. When it is set the stage queues this tic's sound events and
-- clears every monster's fired_this_tick (the think stage then sets it again
-- for the monsters it advances).
PI1 AS (
  -- projectile_impacts after the projectile stage: this tic's, or what the
  -- table held when the stage did not run.
  SELECT i.* FROM PI0 i LEFT ANTI JOIN pj_due d ON d.ntic = i.ntic
  UNION ALL
  SELECT i.ntic, ${map_id} AS map_id, i.projectile_id, i.projectile_type, i.owner_thing_id, i.x, i.y, i.z,
         i.target_player, i.target_thing_id, i.target_player_thing_id
  FROM projectile_impacts i
),
sound_weapon AS (
  SELECT w.ntic, w.fired_this_tick AS fired0, w.state AS state0, wd0.idle_loop_sound AS idle0,
         w1.fired_this_tick AS fired1, w1.state AS state1, wd1.idle_loop_sound AS idle1
  FROM W0 w
  JOIN weapon_defs wd0 ON wd0.weapon_id = w.current_weapon
  JOIN W1 w1 ON w1.ntic = w.ntic AND w1.player_thing_id = w.player_thing_id
  JOIN weapon_defs wd1 ON wd1.weapon_id = w1.current_weapon
  WHERE w.player_thing_id = ${player}
),
sound_plan AS (
  SELECT c.ntic,
    -- after the clock
    (g.use_requested OR sw.fired0 OR COALESCE(mf0.f, FALSE) OR COALESCE(pi0.f, FALSE) OR COALESCE(mv0.f, FALSE)
     OR (sw.idle0 IS NOT NULL AND sw.state0 <> 'down') OR COALESCE(aw0.f, FALSE)
     OR NOT c.alive OR c.c_pain_face_tics > 0) AS due_clock,
    -- after the movement and the death stage
    (g.use_requested OR sw.fired0 OR COALESCE(mf0.f, FALSE) OR COALESCE(pi0.f, FALSE) OR COALESCE(mv2.f, FALSE)
     OR (sw.idle0 IS NOT NULL AND sw.state0 <> 'down') OR COALESCE(aw0.f, FALSE)
     OR NOT n.alive OR n.pain_face_tics > 0) AS due_move,
    -- after the pickups (planned again only when the player moved)
    (pm.tic IS NOT NULL AND (g.use_requested OR sw.fired0 OR COALESCE(pt.f, FALSE) OR COALESCE(mf0.f, FALSE)
     OR COALESCE(pi0.f, FALSE) OR COALESCE(mv2.f, FALSE) OR (sw.idle0 IS NOT NULL AND sw.state0 <> 'down')
     OR COALESCE(aw0.f, FALSE) OR NOT n.alive OR n.pain_face_tics > 0)) AS due_pickup,
    -- after the weapon stage (when it ran)
    (wdue.ntic IS NOT NULL AND (g.use_requested OR sw.fired1 OR COALESCE(pt.f, FALSE) OR COALESCE(mf0.f, FALSE)
     OR COALESCE(pi0.f, FALSE) OR COALESCE(mv2.f, FALSE) OR (sw.idle1 IS NOT NULL AND sw.state1 <> 'down')
     OR COALESCE(aw0.f, FALSE) OR NOT p5.alive OR p5.pain_face_tics > 0)) AS due_weapon,
    -- after the projectile stage (when it ran)
    (pjd.ntic IS NOT NULL AND (g.use_requested OR sw.fired1 OR COALESCE(pt.f, FALSE) OR COALESCE(mf2.f, FALSE)
     OR COALESCE(pi1.f, FALSE) OR COALESCE(mv2.f, FALSE) OR (sw.idle1 IS NOT NULL AND sw.state1 <> 'down')
     OR COALESCE(aw2.f, FALSE) OR NOT p6.alive OR p6.pain_face_tics > 0)) AS due_projectile
  FROM clocked0 c
  JOIN cmd g ON g.tic = c.ntic
  JOIN next_world n ON n.tic = c.ntic
  JOIN P5 p5 ON p5.tic = c.ntic
  JOIN P6 p6 ON p6.tic = c.ntic
  JOIN sound_weapon sw ON sw.ntic = c.ntic
  LEFT JOIN player_moved pm ON pm.tic = c.ntic
  LEFT JOIN weapon_due wdue ON wdue.ntic = c.ntic
  LEFT JOIN pj_due pjd ON pjd.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM I0 WHERE fired_this_tick GROUP BY ntic) mf0 ON mf0.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM I2 WHERE fired_this_tick GROUP BY ntic) mf2 ON mf2.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM I0 WHERE state <> 'stand' GROUP BY ntic) aw0 ON aw0.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM I2 WHERE state <> 'stand' GROUP BY ntic) aw2 ON aw2.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM PI0 GROUP BY ntic) pi0 ON pi0.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM PI1 GROUP BY ntic) pi1 ON pi1.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM M0 WHERE direction IN (-1, 1) GROUP BY ntic) mv0 ON mv0.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM M2 WHERE direction IN (-1, 1) GROUP BY ntic) mv2 ON mv2.ntic = c.ntic
  LEFT JOIN (SELECT ntic, TRUE AS f FROM pickup_touches GROUP BY ntic) pt ON pt.ntic = c.ntic
),
sound_due AS (
  SELECT ntic FROM sound_plan
  WHERE due_clock OR due_move OR due_pickup OR due_weapon OR due_projectile
),
I2s AS (
  -- 25_cs_sound: monster firing flags are consumed.
  SELECT ai.ntic, ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.sector_id,
    ai.attack_cooldown,
    CASE WHEN sd.ntic IS NOT NULL THEN FALSE ELSE ai.fired_this_tick END AS fired_this_tick,
    ai.target_thing_id, ai.charge_tics, ai.movedir, ai.movecount
  FROM I2 ai LEFT JOIN sound_due sd ON sd.ntic = ai.ntic
),
use_result AS (
  -- 11_cs_use's verdict on the line the use trace hit (line_use_results).
  SELECT h.ntic, ${map_id} AS map_id, h.player_thing_id, h.id AS line_id, h.special,
    COALESCE((d.key_required = 'red' AND NOT h.key_red) OR (d.key_required = 'blue' AND NOT h.key_blue)
             OR (d.key_required = 'yellow' AND NOT h.key_yellow), FALSE) AS locked,
    (h.from_front AND COALESCE(d.use_activated, FALSE))
      AND NOT COALESCE((d.key_required = 'red' AND NOT h.key_red) OR (d.key_required = 'blue' AND NOT h.key_blue)
                       OR (d.key_required = 'yellow' AND NOT h.key_yellow), FALSE)
      AND NOT (COALESCE(d.use_once, FALSE) AND a.line_id IS NOT NULL) AS eligible,
    h.from_front
  FROM use_hit h
  LEFT JOIN line_special_defs d ON d.special = h.special
  LEFT JOIN A0 a ON a.ntic = h.ntic AND a.line_id = h.id
),
sound_pos AS (
  SELECT p.tic AS ntic, p.player_thing_id, p.level_tics AS level_tic, t.x AS px, t.y AS py,
         g.use_requested, pt.ntic IS NOT NULL AS pickup_changed, pg.ntic IS NOT NULL AS weapon_granted
  FROM P6 p
  JOIN T2 t ON t.ntic = p.tic AND t.id = p.player_thing_id
  JOIN cmd g ON g.tic = p.tic
  JOIN sound_due sd ON sd.ntic = p.tic
  LEFT JOIN (SELECT DISTINCT ntic FROM pickup_touches) pt ON pt.ntic = p.tic
  LEFT JOIN (SELECT DISTINCT ntic FROM pickup_grants) pg ON pg.ntic = p.tic
),
sound_pick AS (
  SELECT d.thing_type, d.cue, d.variant, d.sound_name, COUNT(*) OVER (PARTITION BY d.thing_type, d.cue) AS n
  FROM thing_sound_defs d
),
sound_candidates AS (
  SELECT p.ntic, 1 AS branch, concat('player-fire:', p.player_thing_id, ':', w.shot_serial) AS event_key, p.level_tic,
    CASE w.current_weapon WHEN 1 THEN 'DSPUNCH' WHEN 2 THEN 'DSPISTOL' WHEN 3 THEN 'DSSHOTGN' WHEN 4 THEN 'DSPISTOL'
         WHEN 5 THEN 'DSRLAUNC' WHEN 6 THEN 'DSPLASMA' WHEN 7 THEN 'DSBFG' END AS sound_name,
    p.player_thing_id AS source_thing_id, p.px AS source_x, p.py AS source_y, CAST(0 AS BIGINT) AS sub
  FROM sound_pos p JOIN W1 w ON w.ntic = p.ntic AND w.player_thing_id = p.player_thing_id
  WHERE w.fired_this_tick
  UNION ALL
  SELECT p.ntic, 2, concat('pickup:', p.player_thing_id, ':', p.level_tic), p.level_tic,
    CASE WHEN p.weapon_granted THEN 'DSWPNUP' ELSE 'DSITEMUP' END, p.player_thing_id, p.px, p.py, 0
  FROM sound_pos p WHERE p.pickup_changed
  UNION ALL
  SELECT p.ntic, 3, concat('use:', p.player_thing_id, ':', p.level_tic), p.level_tic,
    CASE WHEN COALESCE(r.locked, FALSE) THEN 'DSOOF'
         WHEN COALESCE(r.eligible, FALSE) AND r.special IN (1, 26, 27, 28, 31, 32, 33, 34, 117, 118) THEN 'DSDOROPN'
         WHEN COALESCE(r.eligible, FALSE) THEN 'DSSWTCHN' ELSE 'DSNOWAY' END,
    p.player_thing_id, p.px, p.py, 0
  FROM sound_pos p
  LEFT JOIN use_result r ON r.ntic = p.ntic AND r.player_thing_id = p.player_thing_id
  WHERE p.use_requested
  UNION ALL
  SELECT p.ntic, 4, concat('monster-fire:', ai.thing_id, ':', p.level_tic), p.level_tic,
    CASE WHEN d.attack_sound IS NOT NULL THEN d.attack_sound
         WHEN d.missile_type IS NOT NULL AND NOT (d.melee_mult IS NOT NULL AND FHYPOT(t.x - p.px, t.y - p.py) <= 64.0)
           THEN 'DSFIRSHT'
         ELSE 'DSCLAW' END,
    ai.thing_id, t.x, t.y, ai.thing_id
  FROM sound_pos p
  JOIN I2 ai ON ai.ntic = p.ntic AND ai.fired_this_tick
  JOIN T2 t ON t.ntic = p.ntic AND t.id = ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type
  UNION ALL
  SELECT p.ntic, 5, concat('impact:', i.projectile_id), p.level_tic,
    CASE i.projectile_type WHEN 'rocket' THEN 'DSRXPLOD' ELSE 'DSFIRXPL' END, i.owner_thing_id, i.x, i.y, i.projectile_id
  FROM sound_pos p JOIN PI1 i ON i.ntic = p.ntic
  UNION ALL
  SELECT p.ntic, 6, concat('mon-sight:', ai.thing_id), p.level_tic, sp.sound_name, ai.thing_id, t.x, t.y, ai.thing_id
  FROM sound_pos p
  JOIN I2 ai ON ai.ntic = p.ntic AND ai.state <> 'stand'
  JOIN T2 t ON t.ntic = p.ntic AND t.id = ai.thing_id
  JOIN H2 h ON h.ntic = p.ntic AND h.thing_id = ai.thing_id AND h.alive
  JOIN sound_pick sp ON sp.thing_type = t.type AND sp.cue = 'sight'
    AND sp.variant = PRANDOM(ai.thing_id, 0, 60) % sp.n
  UNION ALL
  SELECT p.ntic, 7, concat('mon-death:', ai.thing_id), p.level_tic, sp.sound_name, ai.thing_id, t.x, t.y, ai.thing_id
  FROM sound_pos p
  JOIN I2 ai ON ai.ntic = p.ntic
  JOIN T2 t ON t.ntic = p.ntic AND t.id = ai.thing_id
  JOIN H2 h ON h.ntic = p.ntic AND h.thing_id = ai.thing_id AND NOT h.alive
  JOIN thing_combat_defs cdx ON cdx.thing_type = t.type
  JOIN sound_pick sp ON sp.thing_type = t.type
    AND sp.cue = CASE WHEN h.health < -h.max_health AND cdx.xdeath_frame IS NOT NULL THEN 'xdeath' ELSE 'death' END
    AND sp.variant = PRANDOM(ai.thing_id, 0, 60) % sp.n
  UNION ALL
  SELECT p.ntic, 8, concat('mon-pain:', ai.thing_id, ':', p.level_tic), p.level_tic, sp.sound_name,
    ai.thing_id, t.x, t.y, ai.thing_id
  FROM sound_pos p
  JOIN I2 ai ON ai.ntic = p.ntic AND ai.state = 'pain'
  JOIN T2 t ON t.ntic = p.ntic AND t.id = ai.thing_id
  JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = 'pain' AND f.seq_index = ai.seq_index
    AND ai.state_tics = f.tics
  JOIN sound_pick sp ON sp.thing_type = t.type AND sp.cue = 'pain'
    AND sp.variant = PRANDOM(ai.thing_id, 0, 60) % sp.n
  UNION ALL
  SELECT p.ntic, 9, concat('mon-act:', ai.thing_id, ':', p.level_tic), p.level_tic, sp.sound_name,
    ai.thing_id, t.x, t.y, ai.thing_id
  FROM sound_pos p
  JOIN I2 ai ON ai.ntic = p.ntic AND ai.state = 'see'
  JOIN T2 t ON t.ntic = p.ntic AND t.id = ai.thing_id
  JOIN H2 h ON h.ntic = p.ntic AND h.thing_id = ai.thing_id AND h.alive
  JOIN sound_pick sp ON sp.thing_type = t.type AND sp.cue = 'active'
    AND sp.variant = PRANDOM(ai.thing_id, 0, 60) % sp.n
  WHERE (PRANDOM(ai.thing_id, p.level_tic, 61) * 256 + PRANDOM(ai.thing_id, p.level_tic, 62)) % ${ACTIVE_SOUND_ODDS} = 0
  UNION ALL
  SELECT p.ntic, 10, concat('plr-pain:', p.player_thing_id, ':', p.level_tic - (12 - ps.pain_face_tics)), p.level_tic,
    sp.sound_name, p.player_thing_id, p.px, p.py, 0
  FROM sound_pos p
  JOIN P6 ps ON ps.tic = p.ntic AND ps.alive AND ps.pain_face_tics > 0
  JOIN sound_pick sp ON sp.thing_type = 1 AND sp.cue = 'pain' AND sp.variant = 0
  UNION ALL
  SELECT p.ntic, 11, concat('plr-death:', p.player_thing_id), p.level_tic, sp.sound_name,
    p.player_thing_id, p.px, p.py, 0
  FROM sound_pos p
  JOIN P6 ps ON ps.tic = p.ntic AND NOT ps.alive
  JOIN sound_pick sp ON sp.thing_type = 1 AND sp.cue = 'death' AND sp.variant = 0
),
