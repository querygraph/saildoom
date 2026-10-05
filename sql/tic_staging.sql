-- SQLDoom's per-tic staging tables, for the API backend (saildoom/api/game.py),
-- which keeps every table SQLDoom has. Each is what this tic's stage wrote
-- when the stage ran, else what the table held before: SQLDoom clears a
-- staging table only in the stage that refills it.
GC_out AS (
  -- 14_cs_movement_mode records which movement ran.
  SELECT g.ntic, g.map_id, g.player_thing_id, g.command_serial, g.skill, g.skill_bit, g.move_fwd,
         g.move_strafe, g.running, g.turn_degrees, g.attack_held, g.weapon_switch_to, g.use_requested,
         COALESCE(m.mode, g.movement_mode) AS movement_mode
  FROM GC0 g LEFT JOIN moded m ON m.ntic = g.ntic AND g.player_thing_id = ${player}
),
use_ran AS (SELECT DISTINCT tic AS ntic FROM cmd WHERE use_requested),
LU_out AS (
  -- 11_cs_use's verdict on the line the use trace hit.
  SELECT l.* FROM LU0 l LEFT ANTI JOIN use_ran u ON u.ntic = l.ntic AND l.player_thing_id = ${player}
  UNION ALL
  SELECT * FROM use_result
),
PT_out AS (
  -- cs_begin clears the player's touches; 19_cs_pickups stages this tic's.
  SELECT * FROM PT0 WHERE player_thing_id <> ${player}
  UNION ALL
  SELECT t.ntic, ${map_id} AS map_id, t.player_thing_id, t.thing_id, t.kind, t.amount, t.cap,
         t.is_set_min, t.weapon_id, t.armor_class
  FROM pickup_touches t
),
PG_out AS (
  SELECT * FROM PG0 WHERE player_thing_id <> ${player}
  UNION ALL
  SELECT g.ntic, ${map_id} AS map_id, g.player_thing_id, g.weapon_id FROM pickup_grants g
),
MS_out AS (
  -- The monster stage clears last tic's steps whether or not anyone steps.
  SELECT s.ntic, ${map_id} AS map_id, s.thing_id, s.old_x, s.old_y, s.new_x, s.new_y, s.face_angle,
         s.movedir, s.movecount
  FROM monster_steps s
),
MA_out AS (
  SELECT m.* FROM MA0 m LEFT ANTI JOIN (SELECT ntic FROM mo_plan WHERE attacking_due) a ON a.ntic = m.ntic
  UNION ALL
  SELECT d.ntic, ${map_id} AS map_id, d.attacker_id, d.victim_id, d.victim_player, d.dmg, d.mx, d.my
  FROM monster_attack_damage d
),
mo_stepped AS (SELECT DISTINCT ntic FROM mo_moved),
MT_out AS (
  SELECT m.* FROM MT0 m LEFT ANTI JOIN mo_stepped s ON s.ntic = m.ntic
  UNION ALL
  SELECT t.ntic, ${map_id} AS map_id, t.thing_id, t.dest_x, t.dest_y, t.dest_angle, t.sector_id
  FROM mo_teleports t
),
MR_out AS (
  SELECT r.ntic, ${map_id} AS map_id, r.thing_id, r.old_x, r.old_y FROM mo_respawns r
),
PD_out AS (
  SELECT d.* FROM PD0 d LEFT ANTI JOIN pj_due p ON p.ntic = d.ntic
  UNION ALL
  SELECT d.ntic, ${map_id} AS map_id, d.projectile_id, d.damage_kind, d.hit_index, d.thing_id, d.damage
  FROM projectile_damage d
),
HH_out AS (
  -- 23_cs_hitscan_apply retires the shot's traces once applied.
  SELECT h.* FROM HH0 h
  LEFT ANTI JOIN (SELECT DISTINCT ntic, shot_serial FROM hitscan_hits) s
    ON s.ntic = h.ntic AND h.player_thing_id = ${player} AND s.shot_serial = h.shot_serial
),
SE_out AS (
  -- 25_cs_sound's INSERT ... ON CONFLICT (map_id, event_key) DO NOTHING, with
  -- event_id from the sequence the backend keeps (${se_next} is its next value).
  SELECT * FROM SE0
  UNION ALL
  SELECT q.ntic, ${se_next} + ROW_NUMBER() OVER (ORDER BY q.branch, q.sub, q.event_key) - 1 AS event_id,
         ${map_id} AS map_id, q.event_key, CAST(q.level_tic AS BIGINT) AS level_tic, q.sound_name,
         q.source_thing_id, CAST(q.source_x AS FLOAT) AS source_x, CAST(q.source_y AS FLOAT) AS source_y
  FROM (
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.event_key ORDER BY c.branch, c.sub) AS rn
    FROM sound_candidates c WHERE c.sound_name IS NOT NULL
  ) q
  LEFT ANTI JOIN SE0 e ON e.ntic = q.ntic AND e.event_key = q.event_key
  WHERE q.rn = 1
),
TT_out AS (
  -- doom_run_tic_core's stage trace.
  SELECT t.* FROM TT0 t WHERE t.player_thing_id <> ${player}
  UNION ALL
  SELECT c.ntic, ${map_id} AS map_id, ${player} AS player_thing_id,
    CAST(1 + 2 + 4
      + CASE WHEN g.use_requested THEN 8 ELSE 0 END
      + CASE WHEN ar.ntic IS NOT NULL THEN 16 ELSE 0 END
      + CASE WHEN dr.ntic IS NOT NULL THEN 32 ELSE 0 END
      + CASE m.mode WHEN 'full' THEN 128 WHEN 'turn' THEN 256 ELSE 0 END
      + CASE WHEN pm.tic IS NOT NULL THEN 512 + 1024 + 2048 ELSE 0 END
      + CASE WHEN wd.ntic IS NOT NULL THEN 4096 ELSE 0 END
      + CASE WHEN (wd.ntic IS NOT NULL AND sh.ntic IS NOT NULL)
               OR (wd.ntic IS NULL AND w0.fired_this_tick AND d0.pellet_count > 0) THEN 8192 + 16384 ELSE 0 END
      + CASE WHEN pj.ntic IS NOT NULL THEN 32768 ELSE 0 END
      + CASE WHEN sd.ntic IS NOT NULL THEN 65536 ELSE 0 END
      + 131072 + 262144 + 524288 AS BIGINT) AS stages
  FROM clocked0 c
  JOIN cmd g ON g.tic = c.ntic
  JOIN moded m ON m.ntic = c.ntic
  JOIN W0 w0 ON w0.ntic = c.ntic AND w0.player_thing_id = ${player}
  JOIN weapon_defs d0 ON d0.weapon_id = w0.current_weapon
  LEFT JOIN activate_ran ar ON ar.ntic = c.ntic
  LEFT JOIN doors_run dr ON dr.ntic = c.ntic
  LEFT JOIN player_moved pm ON pm.tic = c.ntic
  LEFT JOIN weapon_due wd ON wd.ntic = c.ntic
  LEFT JOIN (SELECT DISTINCT ntic FROM shooter) sh ON sh.ntic = c.ntic
  LEFT JOIN pj_due pj ON pj.ntic = c.ntic
  LEFT JOIN sound_due sd ON sd.ntic = c.ntic
)
