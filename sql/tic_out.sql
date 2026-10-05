-- The tic's output: one relation per kind of world row, keyed by ntic.
--
-- The stages not ported yet (24_cs_projectiles, 26_cs_monsters,
-- 28_cs_sector_fx, 29_cs_thing_physics, 35_cs_boss) run after everything
-- here; what they write is taken from the recorded run at the end of the tic:
-- monster_ai and render_things whole, every Thing but the player's, the
-- health of Things no hitscan touched this tic, the effects they spawned,
-- and the line events the monsters queued.
P_out AS (SELECT * FROM next_world2),
S_out AS (SELECT * FROM S2),
M_out AS (SELECT * FROM M2),
E_out AS (
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM cross_events
  UNION ALL
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM shoot_events
  UNION ALL
  SELECT e.tic AS ntic, e.map_id, e.player_thing_id, e.line_id, e.trigger_type, e.from_front
  FROM rec_line_special_events e
  JOIN (SELECT DISTINCT ntic FROM P0) t ON t.ntic = e.tic
  WHERE e.map_id = ${map_id}
    AND NOT (e.player_thing_id = ${player} AND e.trigger_type IN ('cross', 'use', 'shoot'))
),
A_out AS (SELECT * FROM A1),
B_out AS (SELECT * FROM B2),
D_out AS (SELECT * FROM D2),
R_out AS (SELECT * FROM R2),
tics_out AS (SELECT DISTINCT ntic FROM P0),
T_out AS (
  SELECT t.ntic, t.id, t.map_id,
    CASE WHEN t.id = ${player} THEN p.t_x ELSE t.x END AS x,
    CASE WHEN t.id = ${player} THEN p.t_y ELSE t.y END AS y,
    CASE WHEN t.id = ${player} THEN p.t_z ELSE t.z END AS z,
    CASE WHEN t.id = ${player} THEN p.t_angle ELSE t.angle END AS angle,
    t.spawn_x, t.spawn_y, t.spawn_angle, t.mom_x, t.mom_y, t.type, t.flags
  FROM (SELECT r.tic AS ntic, r.* FROM rec_things r JOIN tics_out o ON o.ntic = r.tic
        WHERE r.map_id = ${map_id}) t
  LEFT JOIN next_world2 p ON p.tic = t.ntic
),
H_out AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN d.thing_id IS NOT NULL THEN h.health ELSE r.health END AS health,
    COALESCE(r.max_health, h.max_health) AS max_health,
    CASE WHEN d.thing_id IS NOT NULL THEN h.alive ELSE r.alive END AS alive
  FROM H1 h
  LEFT JOIN hit_damage d ON d.ntic = h.ntic AND d.thing_id = h.thing_id
  LEFT JOIN rec_thing_health r ON r.tic = h.ntic AND r.map_id = h.map_id AND r.thing_id = h.thing_id
),
I_out AS (
  SELECT r.tic AS ntic, r.* FROM rec_monster_ai r JOIN tics_out o ON o.ntic = r.tic WHERE r.map_id = ${map_id}
),
N_out AS (
  SELECT r.tic AS ntic, r.* FROM rec_render_things r JOIN tics_out o ON o.ntic = r.tic WHERE r.map_id = ${map_id}
),
X_out AS (
  SELECT * FROM X2
  UNION ALL
  SELECT r.tic AS ntic, r.map_id, r.effect_id, r.effect_type, r.x, r.y, r.z, r.sector_id, r.age
  FROM rec_world_effects r
  JOIN tics_out o ON o.ntic = r.tic
  LEFT ANTI JOIN X2 x ON x.ntic = r.tic AND x.effect_id = r.effect_id
  WHERE r.map_id = ${map_id} AND r.age = 0
),
W_out AS (SELECT * FROM W1),
O_out AS (SELECT * FROM O1),
U_out AS (SELECT * FROM U1),
L_out AS (SELECT * FROM L1),
Y_out AS (SELECT * FROM Y1)
