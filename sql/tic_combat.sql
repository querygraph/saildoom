-- The player's tic after movement: secrets, automap, pickups, the weapon
-- and hitscan shots. Follows tic_step.sql (`next_world` is the moved player,
-- keyed by `tic`, the tic being computed).
--
-- Ported from cedardb/sqldoom sql/runtime/functions: 17_cs_secret,
-- 37_cs_discover, 19_cs_pickups, 03_weapon_decision, 20_cs_weapon_state,
-- 21_cs_weapon, 22_cs_hitscan_fire and 23_cs_hitscan_apply, gated as
-- 40_run_game_tic gates them (plan bits 8, 16 and 32), and 00_prandom.
--
-- Not ported yet, and taken from the recorded run instead: what hitscan does
-- to Things (the shove, the drops) and to monster_ai (pain), which the
-- monster stage that follows rewrites, and a deathmatch's other players.
ammo_caps AS (
  SELECT MAX(CASE WHEN ammo_type = 'bullets' THEN cap END) AS bullets_cap,
         MAX(CASE WHEN ammo_type = 'bullets' THEN backpack_cap END) AS bullets_bcap,
         MAX(CASE WHEN ammo_type = 'bullets' THEN backpack_gives END) AS bullets_gives,
         MAX(CASE WHEN ammo_type = 'shells' THEN cap END) AS shells_cap,
         MAX(CASE WHEN ammo_type = 'shells' THEN backpack_cap END) AS shells_bcap,
         MAX(CASE WHEN ammo_type = 'shells' THEN backpack_gives END) AS shells_gives,
         MAX(CASE WHEN ammo_type = 'rockets' THEN cap END) AS rockets_cap,
         MAX(CASE WHEN ammo_type = 'rockets' THEN backpack_cap END) AS rockets_bcap,
         MAX(CASE WHEN ammo_type = 'rockets' THEN backpack_gives END) AS rockets_gives,
         MAX(CASE WHEN ammo_type = 'cells' THEN cap END) AS cells_cap,
         MAX(CASE WHEN ammo_type = 'cells' THEN backpack_cap END) AS cells_bcap,
         MAX(CASE WHEN ammo_type = 'cells' THEN backpack_gives END) AS cells_gives
  FROM ammo_defs
),
player_moved AS (
  -- Plan bit 8: the accepted move changed the player's position.
  SELECT n.tic, n.player_thing_id, n.sector_id,
         CAST(n.position_x AS DOUBLE) AS px, CAST(n.position_y AS DOUBLE) AS py
  FROM next_world n
  WHERE ABS(n.position_x - n.previous_x) > ${POS_EPSILON}
     OR ABS(n.position_y - n.previous_y) > ${POS_EPSILON}
),
-- ---------------------------------------------------------------- 17_cs_secret
L1 AS (
  SELECT ntic, map_id, player_thing_id, sector_id FROM L0
  UNION
  SELECT m.tic AS ntic, ${map_id} AS map_id, m.player_thing_id, m.sector_id
  FROM player_moved m
  JOIN S2 s ON s.ntic = m.tic AND s.id = m.sector_id
  JOIN sector_special_defs sd ON sd.special = s.special AND sd.is_secret
),
-- ---------------------------------------------------------------- 37_cs_discover
Y1 AS (
  SELECT ntic, map_id, line_id FROM Y0
  UNION
  SELECT m.tic AS ntic, ${map_id} AS map_id, ld.id AS line_id
  FROM player_moved m
  JOIN linedefs ld ON ld.map_id = ${map_id}
  LEFT JOIN D2 rs ON rs.ntic = m.tic AND rs.id = ld.right_sd_id
  LEFT JOIN D2 ls ON ls.ntic = m.tic AND ls.id = ld.left_sd_id
  WHERE m.sector_id IS NOT NULL
    AND (rs.sector_id = m.sector_id OR ls.sector_id = m.sector_id)
),
-- ---------------------------------------------------------------- 19_cs_pickups
pickup_eligible AS (
  SELECT m.tic AS ntic, m.player_thing_id, t.id AS thing_id, t.type AS thing_type, d.kind,
         SQRT(POWER(CAST(t.x AS DOUBLE) - m.px, 2) + POWER(CAST(t.y AS DOUBLE) - m.py, 2)) AS dist
  FROM player_moved m
  JOIN cmd g ON g.tic = m.tic
  JOIN next_world ps ON ps.tic = m.tic
  JOIN T0 t ON t.ntic = m.tic
  JOIN pickup_defs d ON d.thing_type = t.type
  LEFT JOIN U0 pu ON pu.ntic = m.tic AND pu.thing_id = t.id
  LEFT JOIN ammo_defs ad ON ad.ammo_type = d.kind
  LEFT JOIN O0 own ON own.ntic = m.tic AND own.player_thing_id = m.player_thing_id
    AND own.weapon_id = d.weapon_id
  WHERE (t.flags & g.skill_bit) <> 0 AND (t.flags & 16) = 0
    AND SQRT(POWER(CAST(t.x AS DOUBLE) - m.px, 2) + POWER(CAST(t.y AS DOUBLE) - m.py, 2)) <= ${PICKUP_REACH}
    AND pu.thing_id IS NULL
    AND CASE
      WHEN d.kind = 'health' THEN NOT d.only_when_below_cap OR ps.health < d.cap
      WHEN d.kind = 'armor' THEN NOT d.is_set_min OR ps.armor < d.amount
      WHEN d.kind IN ('bullets', 'shells', 'rockets', 'cells') THEN
        CASE d.kind WHEN 'bullets' THEN ps.ammo_bullets WHEN 'shells' THEN ps.ammo_shells
                    WHEN 'rockets' THEN ps.ammo_rockets ELSE ps.ammo_cells END
        < CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END
      WHEN d.kind = 'weapon' THEN own.weapon_id IS NULL
      WHEN d.kind IN ('backpack', 'key_blue', 'key_yellow', 'key_red',
                      'radsuit', 'invis', 'lightamp', 'powermap', 'invuln') THEN TRUE
      ELSE FALSE
    END
),
pickup_touches AS (
  SELECT s.ntic, s.player_thing_id, s.thing_id, s.thing_type, d.kind,
    CASE WHEN d.kind IN ('bullets', 'shells', 'rockets', 'cells') THEN
           COALESCE(CASE WHEN s.thing_id >= ${DROPPED_THING_ID_BASE} THEN d.dropped_amount END, d.amount)
           * CASE WHEN g.skill IN (0, 4) THEN 2 ELSE 1 END
         WHEN d.kind = 'backpack' THEN CASE WHEN g.skill IN (0, 4) THEN 2 ELSE 1 END
         ELSE d.amount END AS amount,
    d.cap, d.is_set_min, d.weapon_id, d.armor_class
  FROM (
    SELECT DISTINCT q.ntic, q.player_thing_id, q.thing_id, q.thing_type FROM (
      SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.ntic, e.kind ORDER BY e.dist, e.thing_id) AS rn
      FROM pickup_eligible e
    ) q WHERE q.rn = 1
  ) s
  JOIN pickup_defs d ON d.thing_type = s.thing_type
  JOIN cmd g ON g.tic = s.ntic
),
pickup_staged AS (
  SELECT pt.ntic,
    MAX(CASE WHEN pt.kind = 'health' AND pt.is_set_min THEN pt.amount END) AS health_min,
    SUM(CASE WHEN pt.kind = 'health' AND NOT pt.is_set_min THEN pt.amount END) AS health_add,
    MIN(CASE WHEN pt.kind = 'health' AND NOT pt.is_set_min THEN pt.cap END) AS health_cap,
    MAX(CASE WHEN pt.kind = 'armor' AND pt.is_set_min THEN pt.amount END) AS armor_set,
    SUM(CASE WHEN pt.kind = 'armor' AND NOT pt.is_set_min THEN pt.amount END) AS armor_add,
    MIN(CASE WHEN pt.kind = 'armor' AND NOT pt.is_set_min THEN pt.cap END) AS armor_cap,
    MAX(CASE WHEN pt.kind = 'armor' AND pt.is_set_min THEN pt.armor_class END) AS set_class,
    bool_or(pt.kind = 'armor' AND NOT pt.is_set_min) AS got_armor_bonus,
    bool_or(pt.kind = 'backpack') AS got_backpack,
    bool_or(pt.kind = 'key_blue') AS got_blue,
    bool_or(pt.kind = 'key_yellow') AS got_yellow,
    bool_or(pt.kind = 'key_red') AS got_red,
    MAX(CASE WHEN pt.kind = 'radsuit' THEN pt.amount END) AS got_radsuit,
    MAX(CASE WHEN pt.kind = 'invis' THEN pt.amount END) AS got_invis,
    MAX(CASE WHEN pt.kind = 'lightamp' THEN pt.amount END) AS got_lightamp,
    MAX(CASE WHEN pt.kind = 'powermap' THEN pt.amount END) AS got_powermap,
    MAX(CASE WHEN pt.kind = 'invuln' THEN pt.amount END) AS got_invuln,
    COUNT(*) AS taken,
    MIN(pm.message) AS message,
    SUM(CASE WHEN pt.kind = 'bullets' THEN pt.amount WHEN pt.kind = 'backpack'
             THEN pt.amount * ac.bullets_gives END) AS gain_bullets,
    SUM(CASE WHEN pt.kind = 'shells' THEN pt.amount WHEN pt.kind = 'backpack'
             THEN pt.amount * ac.shells_gives END) AS gain_shells,
    SUM(CASE WHEN pt.kind = 'rockets' THEN pt.amount WHEN pt.kind = 'backpack'
             THEN pt.amount * ac.rockets_gives END) AS gain_rockets,
    SUM(CASE WHEN pt.kind = 'cells' THEN pt.amount WHEN pt.kind = 'backpack'
             THEN pt.amount * ac.cells_gives END) AS gain_cells
  FROM pickup_touches pt
  CROSS JOIN ammo_caps ac
  LEFT JOIN pickup_messages pm ON pm.thing_type = pt.thing_type
  GROUP BY pt.ntic
),
P3 AS (
  -- player_state after the pickups (the UPDATEs are no-ops without a touch).
  SELECT p.*,
    CASE WHEN s.ntic IS NULL THEN p.bonus_count
         ELSE LEAST(100, p.bonus_count + CAST(${BONUSADD} AS INT) * CAST(s.taken AS INT)) END AS p_bonus_count,
    CASE WHEN s.health_min IS NOT NULL THEN GREATEST(p.health, s.health_min)
         WHEN s.health_add IS NOT NULL THEN LEAST(s.health_cap, p.health + s.health_add)
         ELSE p.health END AS p_health,
    CASE WHEN s.armor_set IS NOT NULL THEN s.armor_set
         WHEN s.armor_add IS NOT NULL THEN LEAST(s.armor_cap, p.armor + s.armor_add)
         ELSE p.armor END AS p_armor,
    CASE WHEN s.set_class IS NOT NULL THEN s.set_class
         WHEN s.got_armor_bonus AND p.armor_class = 0 THEN 1
         ELSE p.armor_class END AS p_armor_class,
    p.backpack OR COALESCE(s.got_backpack, FALSE) AS p_backpack,
    p.key_blue OR COALESCE(s.got_blue, FALSE) AS p_key_blue,
    p.key_yellow OR COALESCE(s.got_yellow, FALSE) AS p_key_yellow,
    p.key_red OR COALESCE(s.got_red, FALSE) AS p_key_red,
    GREATEST(p.radsuit_tics, COALESCE(s.got_radsuit, 0)) AS p_radsuit_tics,
    GREATEST(p.invis_tics, COALESCE(s.got_invis, 0)) AS p_invis_tics,
    GREATEST(p.light_amp_tics, COALESCE(s.got_lightamp, 0)) AS p_light_amp_tics,
    p.power_map OR COALESCE(s.got_powermap, 0) > 0 AS p_power_map,
    GREATEST(p.invuln_tics, COALESCE(s.got_invuln, 0)) AS p_invuln_tics,
    COALESCE(s.message, p.message) AS p_message,
    CASE WHEN s.message IS NOT NULL THEN CAST(${MESSAGE_TICS} AS INT) ELSE p.message_tics END AS p_message_tics,
    s.gain_bullets, s.gain_shells, s.gain_rockets, s.gain_cells
  FROM next_world p
  LEFT JOIN pickup_staged s ON s.ntic = p.tic
),
P4 AS (
  -- The ammo UPDATE reads the backpack the first UPDATE just set.
  SELECT p.*,
    CASE WHEN p.gain_bullets IS NULL THEN p.ammo_bullets ELSE LEAST(
      CASE WHEN p.p_backpack THEN ac.bullets_bcap ELSE ac.bullets_cap END,
      p.ammo_bullets + CAST(p.gain_bullets AS INT)) END AS p_ammo_bullets,
    CASE WHEN p.gain_shells IS NULL THEN p.ammo_shells ELSE LEAST(
      CASE WHEN p.p_backpack THEN ac.shells_bcap ELSE ac.shells_cap END,
      p.ammo_shells + CAST(p.gain_shells AS INT)) END AS p_ammo_shells,
    CASE WHEN p.gain_rockets IS NULL THEN p.ammo_rockets ELSE LEAST(
      CASE WHEN p.p_backpack THEN ac.rockets_bcap ELSE ac.rockets_cap END,
      p.ammo_rockets + CAST(p.gain_rockets AS INT)) END AS p_ammo_rockets,
    CASE WHEN p.gain_cells IS NULL THEN p.ammo_cells ELSE LEAST(
      CASE WHEN p.p_backpack THEN ac.cells_bcap ELSE ac.cells_cap END,
      p.ammo_cells + CAST(p.gain_cells AS INT)) END AS p_ammo_cells
  FROM P3 p CROSS JOIN ammo_caps ac
),
U1 AS (
  SELECT ntic, map_id, thing_id FROM U0
  UNION
  SELECT ntic, ${map_id} AS map_id, thing_id FROM pickup_touches
),
pickup_grants AS (
  SELECT DISTINCT pt.ntic, pt.player_thing_id, pt.weapon_id
  FROM pickup_touches pt
  LEFT ANTI JOIN O0 o ON o.ntic = pt.ntic AND o.player_thing_id = pt.player_thing_id
    AND o.weapon_id = pt.weapon_id
  WHERE pt.kind = 'weapon'
),
O1 AS (
  SELECT ntic, map_id, player_thing_id, weapon_id FROM O0
  UNION
  SELECT ntic, ${map_id} AS map_id, player_thing_id, weapon_id FROM pickup_grants
),
-- ---------------------------------------------------------------- 03_weapon_decision
weapon_due AS (
  -- Plan bit 16, planned again after the pickups.
  SELECT w.ntic FROM W0 w
  JOIN cmd g ON g.tic = w.ntic
  JOIN P4 p ON p.tic = w.ntic
  LEFT JOIN (SELECT DISTINCT ntic FROM pickup_grants) pg ON pg.ntic = w.ntic
  LEFT JOIN (SELECT DISTINCT ntic FROM X0) fx ON fx.ntic = w.ntic
  WHERE g.attack_held OR g.weapon_switch_to IS NOT NULL
     OR pg.ntic IS NOT NULL
     OR w.state <> 'ready' OR w.flash_seq_index IS NOT NULL
     OR p.bob_strength > ${PSPRITE_EPSILON}
     OR ABS(w.sx - ${PSPRITE_REST_X}) > ${PSPRITE_EPSILON}
     OR ABS(w.sy - ${PSPRITE_REST_Y}) > ${PSPRITE_EPSILON}
     OR fx.ntic IS NOT NULL
),
weapon_flags AS (
  SELECT q.*,
    (q.state = 'fire' AND q.tics <= 1) AS advancing,
    (q.state = 'fire' AND q.tics <= 1 AND q.next_seq IS NULL) AS falls_off,
    (q.state = 'fire' AND q.tics <= 1 AND q.next_seq IS NOT NULL
       AND q.next_refire AND q.attack_held AND q.has_ammo) AS refires,
    (q.state = 'ready' AND q.attack_held AND q.has_ammo AND NOT q.switch_requested) AS starts_fire,
    (q.state = 'down' AND q.sy + 6.0D >= 128.0D) AS down_done,
    (q.state = 'up' AND q.sy - 6.0D <= 32.0D) AS up_done,
    (q.flash_seq_index IS NOT NULL AND q.flash_tics <= 1) AS flash_advancing
  FROM (
    SELECT w.*, wd.ammo_type, wd.ammo_per_shot, g.attack_held,
      COALESCE(g.weapon_switch_to, pg.weapon_id) AS switch_to,
      CAST(p.bob_strength AS DOUBLE) AS bob, p.level_tics AS level_tic,
      CASE wd.ammo_type WHEN 'bullets' THEN p.p_ammo_bullets WHEN 'shells' THEN p.p_ammo_shells
                        WHEN 'rockets' THEN p.p_ammo_rockets WHEN 'cells' THEN p.p_ammo_cells
                        ELSE 999999 END >= wd.ammo_per_shot AS has_ammo,
      (COALESCE(g.weapon_switch_to, pg.weapon_id) IS NOT NULL
       AND COALESCE(g.weapon_switch_to, pg.weapon_id) <> w.current_weapon
       AND own.weapon_id IS NOT NULL) AS switch_requested,
      ready0.tics AS ready_tics, fire0.tics AS fire0_tics, fire0.is_attack_frame AS fire0_attack,
      nextf.seq_index AS next_seq, nextf.tics AS next_tics,
      nextf.is_attack_frame AS next_attack, nextf.refire_check AS next_refire,
      flash0.tics AS flash0_tics, flashnext.seq_index AS flashnext_seq, flashnext.tics AS flashnext_tics
    FROM W0 w
    JOIN weapon_due due ON due.ntic = w.ntic
    JOIN cmd g ON g.tic = w.ntic
    JOIN P4 p ON p.tic = w.ntic
    JOIN weapon_defs wd ON wd.weapon_id = w.current_weapon
    LEFT JOIN (SELECT ntic, player_thing_id, MIN(weapon_id) AS weapon_id FROM pickup_grants
               GROUP BY ntic, player_thing_id) pg ON pg.ntic = w.ntic AND pg.player_thing_id = w.player_thing_id
    LEFT JOIN O1 own ON own.ntic = w.ntic AND own.player_thing_id = w.player_thing_id
      AND own.weapon_id = COALESCE(g.weapon_switch_to, pg.weapon_id)
    LEFT JOIN weapon_frames ready0 ON ready0.weapon_id = w.current_weapon AND ready0.state = 'ready' AND ready0.seq_index = 0
    LEFT JOIN weapon_frames fire0 ON fire0.weapon_id = w.current_weapon AND fire0.state = 'fire' AND fire0.seq_index = 0
    LEFT JOIN weapon_frames nextf ON nextf.weapon_id = w.current_weapon AND nextf.state = 'fire'
      AND nextf.seq_index = w.seq_index + 1
    LEFT JOIN weapon_frames flash0 ON flash0.weapon_id = w.current_weapon AND flash0.state = 'flash' AND flash0.seq_index = 0
    LEFT JOIN weapon_frames flashnext ON flashnext.weapon_id = w.current_weapon AND flashnext.state = 'flash'
      AND flashnext.seq_index = w.flash_seq_index + 1
  ) q
),
weapon_decision AS (
  SELECT d.*,
    CASE WHEN d.n_state = 'ready' THEN 1.0D + d.bob * COS(2.0D * PI() * (d.level_tic % 64) / 64.0D)
         ELSE CAST(d.sx AS DOUBLE) END AS n_sx,
    CASE WHEN d.n_state = 'ready' THEN 32.0D + d.bob * SIN(2.0D * PI() * (d.level_tic % 32) / 64.0D)
         WHEN d.n_state = 'down' THEN LEAST(128.0D, d.sy + 6.0D)
         WHEN d.n_state = 'up' THEN GREATEST(32.0D, d.sy - 6.0D)
         ELSE CAST(d.sy AS DOUBLE) END AS n_sy,
    CASE WHEN d.fires_now THEN CASE WHEN d.flash0_tics IS NOT NULL THEN 0 END
         WHEN d.flash_seq_index IS NULL THEN CAST(NULL AS INT)
         WHEN NOT d.flash_advancing THEN d.flash_seq_index
         ELSE d.flashnext_seq END AS n_flash_seq,
    CASE WHEN d.fires_now THEN COALESCE(d.flash0_tics, 0)
         WHEN d.flash_seq_index IS NULL THEN 0
         WHEN NOT d.flash_advancing THEN d.flash_tics - 1
         ELSE COALESCE(d.flashnext_tics, 0) END AS n_flash_tics
  FROM (
    SELECT f.*,
      CASE WHEN f.switch_requested THEN 'down'
           WHEN f.state = 'down' THEN CASE WHEN f.down_done THEN 'up' ELSE 'down' END
           WHEN f.state = 'up' THEN CASE WHEN f.up_done THEN 'ready' ELSE 'up' END
           WHEN f.state = 'ready' THEN CASE WHEN f.starts_fire THEN 'fire' ELSE 'ready' END
           WHEN f.state = 'fire' AND f.advancing AND f.falls_off THEN 'ready'
           ELSE f.state END AS n_state,
      CASE WHEN f.switch_requested THEN f.seq_index
           WHEN f.state = 'up' AND f.up_done THEN 0
           WHEN f.state = 'ready' THEN 0
           WHEN f.state = 'fire' AND f.advancing THEN
             CASE WHEN f.falls_off OR f.refires THEN 0 ELSE f.next_seq END
           ELSE f.seq_index END AS n_seq,
      CASE WHEN f.switch_requested THEN f.tics
           WHEN f.state = 'up' THEN CASE WHEN f.up_done THEN f.ready_tics ELSE f.tics END
           WHEN f.state = 'ready' THEN CASE WHEN f.starts_fire THEN f.fire0_tics ELSE f.tics END
           WHEN f.state = 'fire' AND f.advancing THEN
             CASE WHEN f.falls_off THEN f.ready_tics WHEN f.refires THEN f.fire0_tics ELSE f.next_tics END
           WHEN f.state = 'fire' THEN f.tics - 1
           ELSE f.tics END AS n_tics,
      ((f.state = 'ready' AND f.starts_fire AND f.fire0_attack IS TRUE)
        OR (f.state = 'fire' AND f.advancing AND NOT f.falls_off AND NOT f.refires AND f.next_attack IS TRUE)
        OR (f.state = 'fire' AND f.advancing AND f.refires AND f.fire0_attack IS TRUE)) AS fires_now,
      CASE WHEN f.state = 'down' AND f.down_done AND NOT f.switch_requested
           THEN f.pending_weapon ELSE f.current_weapon END AS n_current_weapon,
      CASE WHEN f.switch_requested THEN f.switch_to
           WHEN f.state = 'down' AND f.down_done THEN CAST(NULL AS INT)
           ELSE f.pending_weapon END AS n_pending_weapon
    FROM weapon_flags f
  ) d
),
W1 AS (
  SELECT w.ntic, w.map_id, w.player_thing_id,
    CASE WHEN d.ntic IS NULL THEN w.current_weapon ELSE d.n_current_weapon END AS current_weapon,
    CASE WHEN d.ntic IS NULL THEN w.pending_weapon ELSE d.n_pending_weapon END AS pending_weapon,
    CASE WHEN d.ntic IS NULL THEN w.state ELSE d.n_state END AS state,
    CASE WHEN d.ntic IS NULL THEN w.seq_index ELSE d.n_seq END AS seq_index,
    CASE WHEN d.ntic IS NULL THEN w.tics ELSE d.n_tics END AS tics,
    CASE WHEN d.ntic IS NULL THEN w.flash_seq_index ELSE d.n_flash_seq END AS flash_seq_index,
    CASE WHEN d.ntic IS NULL THEN w.flash_tics ELSE d.n_flash_tics END AS flash_tics,
    CASE WHEN d.ntic IS NULL THEN w.sx ELSE CAST(d.n_sx AS FLOAT) END AS sx,
    CASE WHEN d.ntic IS NULL THEN w.sy ELSE CAST(d.n_sy AS FLOAT) END AS sy,
    w.shot_serial + CASE WHEN d.fires_now THEN 1 ELSE 0 END AS shot_serial,
    CASE WHEN d.ntic IS NULL THEN w.fired_this_tick ELSE d.fires_now END AS fired_this_tick
  FROM W0 w LEFT JOIN weapon_decision d ON d.ntic = w.ntic AND d.player_thing_id = w.player_thing_id
),
fired AS (
  SELECT w.ntic, w.player_thing_id, w.shot_serial, wd.ammo_type, wd.ammo_per_shot,
         wd.pellet_count, wd.max_range, wd.dmg_dice_count, wd.dmg_dice_mult
  FROM W1 w
  JOIN weapon_due due ON due.ntic = w.ntic
  JOIN weapon_defs wd ON wd.weapon_id = w.current_weapon
  WHERE w.fired_this_tick
),
P5 AS (
  -- 21_cs_weapon: the shot's ammo.
  SELECT p.*,
    p.p_ammo_bullets - CASE WHEN f.ammo_type = 'bullets' THEN f.ammo_per_shot ELSE 0 END AS q_ammo_bullets,
    p.p_ammo_shells - CASE WHEN f.ammo_type = 'shells' THEN f.ammo_per_shot ELSE 0 END AS q_ammo_shells,
    p.p_ammo_rockets - CASE WHEN f.ammo_type = 'rockets' THEN f.ammo_per_shot ELSE 0 END AS q_ammo_rockets,
    p.p_ammo_cells - CASE WHEN f.ammo_type = 'cells' THEN f.ammo_per_shot ELSE 0 END AS q_ammo_cells
  FROM P4 p LEFT JOIN fired f ON f.ntic = p.tic
),
X1 AS (
  -- 21_cs_weapon: effects age, and the old ones go.
  SELECT x.ntic, x.map_id, x.effect_id, x.effect_type, x.x, x.y, x.z, x.sector_id,
         x.age + CASE WHEN due.ntic IS NOT NULL THEN 1 ELSE 0 END AS age
  FROM X0 x LEFT JOIN weapon_due due ON due.ntic = x.ntic
  WHERE due.ntic IS NULL
     OR x.age + 1 < CASE WHEN x.effect_type = 'blood' THEN 24 WHEN x.effect_type = 'bfg_spray' THEN 32
                         WHEN x.effect_type = 'ifog' THEN 30 WHEN x.effect_type = 'tfog' THEN 72 ELSE 16 END
),
-- ---------------------------------------------------------------- 22_cs_hitscan_fire
shooter AS (
  SELECT f.*, p.player_thing_id AS player_id,
         RADIANS(CAST(p.t_angle AS DOUBLE)) AS view_angle,
         CAST(p.base_z - ${VIEWHEIGHT} + ${PLAYER_HEIGHT} / 2.0D + ${ATTACK_Z_OFFSET} AS DOUBLE) AS shoot_z,
         CAST(p.t_x AS DOUBLE) AS px, CAST(p.t_y AS DOUBLE) AS py
  FROM fired f JOIN P5 p ON p.tic = f.ntic
  WHERE f.pellet_count > 0
),
targets AS (
  SELECT s.ntic, t.id AS thing_id, CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y,
         CAST(d.radius AS DOUBLE) AS radius, CAST(sec.floor_height AS DOUBLE) AS base_z,
         CAST(rt.thing_height AS DOUBLE) AS height, rt.sector_id, d.no_blood
  FROM shooter s
  JOIN H0 h ON h.ntic = s.ntic AND h.alive
  JOIN T0 t ON t.ntic = s.ntic AND t.id = h.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type
  JOIN N0 rt ON rt.ntic = s.ntic AND rt.thing_id = t.id
  JOIN S2 sec ON sec.ntic = s.ntic AND sec.id = rt.sector_id
),
map_lines AS (
  SELECT s.ntic, ld.linedef_id AS line_id,
         CAST(ld.x1 AS DOUBLE) AS x1, CAST(ld.y1 AS DOUBLE) AS y1,
         CAST(ld.x2 AS DOUBLE) AS x2, CAST(ld.y2 AS DOUBLE) AS y2,
         ld.fsec AS right_sector, ld.bsec AS left_sector,
         CAST(GREATEST(rsec.floor_height, lsec.floor_height) AS DOUBLE) AS open_bottom,
         CAST(LEAST(rsec.ceil_height, lsec.ceil_height) AS DOUBLE) AS open_top,
         rsec.floor_height <> lsec.floor_height AS floors_differ,
         rsec.ceil_height <> lsec.ceil_height AS ceils_differ
  FROM shooter s
  JOIN linedef_geom ld ON ld.map_id = ${map_id}
  LEFT JOIN S2 rsec ON rsec.ntic = s.ntic AND rsec.id = ld.fsec
  LEFT JOIN S2 lsec ON lsec.ntic = s.ntic AND lsec.id = ld.bsec
),
aim_target_intersections AS (
  SELECT g.*, g.along - SQRT(GREATEST(0.0D, g.radius * g.radius - g.perp2)) AS distance
  FROM (
    SELECT a.priority, a.angle, t.*, p.max_range,
      (t.x - p.px) * COS(p.view_angle + a.angle) + (t.y - p.py) * SIN(p.view_angle + a.angle) AS along,
      POWER(-(t.x - p.px) * SIN(p.view_angle + a.angle) + (t.y - p.py) * COS(p.view_angle + a.angle), 2) AS perp2
    FROM shooter p
    CROSS JOIN (SELECT 0 AS priority, 0.0D AS angle
                UNION ALL SELECT 1, RADIANS(${AIM_SPREAD_DEGREES})
                UNION ALL SELECT 2, RADIANS(-${AIM_SPREAD_DEGREES})) a
    JOIN targets t ON t.ntic = p.ntic
  ) g
  WHERE g.along > 0 AND g.along <= g.max_range + g.radius AND g.perp2 <= g.radius * g.radius
),
aim_crossings AS (
  -- The lines each aim trace crosses before its target.
  SELECT q.ntic, q.priority, q.thing_id,
    MAX(CASE WHEN q.right_sector IS NULL OR q.left_sector IS NULL OR q.open_bottom >= q.open_top
             THEN 1 ELSE 0 END) = 1 AS solid,
    MAX(CASE WHEN q.floors_differ THEN (q.open_bottom - q.shoot_z) / q.ray_t END) AS max_bottom,
    MIN(CASE WHEN q.ceils_differ THEN (q.open_top - q.shoot_z) / q.ray_t END) AS min_top
  FROM (
    SELECT h.ntic, h.priority, h.thing_id, h.distance, p.shoot_z,
      l.right_sector, l.left_sector, l.open_bottom, l.open_top, l.floors_differ, l.ceils_differ,
      ((l.x1 - p.px) * (l.y2 - l.y1) - (l.y1 - p.py) * (l.x2 - l.x1))
        / NULLIF(COS(p.view_angle + h.angle) * (l.y2 - l.y1) - SIN(p.view_angle + h.angle) * (l.x2 - l.x1), 0.0D) AS ray_t,
      ((l.x1 - p.px) * SIN(p.view_angle + h.angle) - (l.y1 - p.py) * COS(p.view_angle + h.angle))
        / NULLIF(COS(p.view_angle + h.angle) * (l.y2 - l.y1) - SIN(p.view_angle + h.angle) * (l.x2 - l.x1), 0.0D) AS line_u
    FROM aim_target_intersections h
    JOIN shooter p ON p.ntic = h.ntic
    JOIN map_lines l ON l.ntic = h.ntic
  ) q
  WHERE q.ray_t > 0 AND q.ray_t < q.distance AND q.line_u BETWEEN 0 AND 1
  GROUP BY q.ntic, q.priority, q.thing_id
),
aim AS (
  SELECT p.ntic, COALESCE(v.aimslope, 0.0D) AS slope
  FROM shooter p
  LEFT JOIN (
    SELECT r.ntic, r.aimslope FROM (
      SELECT w.ntic, w.aimslope,
        ROW_NUMBER() OVER (PARTITION BY w.ntic ORDER BY w.priority, w.distance, w.thing_id) AS rn
      FROM (
        SELECT b.*, (LEAST(b.thing_top, b.tslope) + GREATEST(b.thing_bot, b.bslope)) / 2.0D AS aimslope
        FROM (
          SELECT h.ntic, h.priority, h.thing_id, h.distance,
            COALESCE(c.solid, FALSE) AS solid,
            GREATEST(-${AUTOAIM_SLOPE}, COALESCE(c.max_bottom, -${SLOPE_UNBOUNDED})) AS bslope,
            LEAST(${AUTOAIM_SLOPE}, COALESCE(c.min_top, ${SLOPE_UNBOUNDED})) AS tslope,
            (h.base_z + h.height - p.shoot_z) / h.distance AS thing_top,
            (h.base_z - p.shoot_z) / h.distance AS thing_bot
          FROM aim_target_intersections h
          JOIN shooter p ON p.ntic = h.ntic
          LEFT JOIN aim_crossings c ON c.ntic = h.ntic AND c.priority = h.priority AND c.thing_id = h.thing_id
          WHERE h.distance > 0 AND h.distance <= p.max_range
        ) b
        WHERE NOT b.solid AND b.tslope > b.bslope
          AND b.thing_top >= b.bslope AND b.thing_bot <= b.tslope
      ) w
    ) r WHERE r.rn = 1
  ) v ON v.ntic = p.ntic
),
pellets AS (
  -- P_GunShot: two draws for the spread and one for the damage, per pellet.
  SELECT q.ntic, q.pellet, a.slope,
    q.dmg_dice_mult * (PRANDOM(q.shot_serial, q.pellet, 4) % q.dmg_dice_count + 1) AS damage,
    q.view_angle + RADIANS((PRANDOM(q.shot_serial, q.pellet, 2) - PRANDOM(q.shot_serial, q.pellet, 3))
                           * 360.0D / ${GUNSHOT_SPREAD_UNITS}) AS angle
  FROM (
    SELECT s.*, explode(sequence(0, s.pellet_count - 1)) AS pellet FROM shooter s
  ) q
  JOIN aim a ON a.ntic = q.ntic
),
pellet_hits AS (
  SELECT g.ntic, g.pellet, g.damage, g.thing_id, g.sector_id, g.no_blood, g.distance, g.angle, g.slope,
         'target' AS hit_kind, CAST(NULL AS INT) AS line_id, CAST(NULL AS BOOLEAN) AS line_from_front
  FROM (
    SELECT q.*, q.along - SQRT(GREATEST(0.0D, q.radius * q.radius - q.perp2)) AS distance
    FROM (
      SELECT b.*, t.thing_id, t.sector_id, t.no_blood, t.radius, t.base_z, t.height, p.max_range, p.shoot_z,
        (t.x - p.px) * COS(b.angle) + (t.y - p.py) * SIN(b.angle) AS along,
        POWER(-(t.x - p.px) * SIN(b.angle) + (t.y - p.py) * COS(b.angle), 2) AS perp2
      FROM pellets b JOIN shooter p ON p.ntic = b.ntic JOIN targets t ON t.ntic = b.ntic
    ) q
    WHERE q.along > 0 AND q.perp2 <= q.radius * q.radius
  ) g
  WHERE g.distance > 0 AND g.distance <= g.max_range
    AND g.shoot_z + g.slope * g.distance BETWEEN g.base_z AND g.base_z + g.height
  UNION ALL
  SELECT q.ntic, q.pellet, q.damage, CAST(NULL AS INT) AS thing_id,
         COALESCE(q.right_sector, q.left_sector) AS sector_id, TRUE AS no_blood,
         q.distance, q.angle, q.slope, 'wall' AS hit_kind, q.line_id,
         ((q.x2 - q.x1) * (q.py - q.y1) - (q.y2 - q.y1) * (q.px - q.x1)) < 0 AS line_from_front
  FROM (
    SELECT b.*, l.line_id, l.x1, l.y1, l.x2, l.y2, l.right_sector, l.left_sector,
      l.open_bottom, l.open_top, p.px, p.py, p.shoot_z, p.max_range,
      ((l.x1 - p.px) * (l.y2 - l.y1) - (l.y1 - p.py) * (l.x2 - l.x1))
        / NULLIF(COS(b.angle) * (l.y2 - l.y1) - SIN(b.angle) * (l.x2 - l.x1), 0.0D) AS distance,
      ((l.x1 - p.px) * SIN(b.angle) - (l.y1 - p.py) * COS(b.angle))
        / NULLIF(COS(b.angle) * (l.y2 - l.y1) - SIN(b.angle) * (l.x2 - l.x1), 0.0D) AS line_u
    FROM pellets b JOIN shooter p ON p.ntic = b.ntic JOIN map_lines l ON l.ntic = b.ntic
  ) q
  WHERE q.distance > 0 AND q.distance <= q.max_range AND q.line_u BETWEEN 0 AND 1
    AND (q.right_sector IS NULL OR q.left_sector IS NULL
      OR q.shoot_z + q.slope * q.distance <= q.open_bottom
      OR q.shoot_z + q.slope * q.distance >= q.open_top)
),
hitscan_hits AS (
  -- hitscan_hits stores the distance and the shooter's position as real.
  SELECT r.ntic, r.pellet, r.damage, r.thing_id, r.sector_id, r.no_blood,
         CAST(CAST(r.distance AS FLOAT) AS DOUBLE) AS distance, r.angle, r.slope, r.hit_kind,
         r.line_id, r.line_from_front, p.player_id, p.shot_serial,
         CAST(CAST(p.px AS FLOAT) AS DOUBLE) AS px, CAST(CAST(p.py AS FLOAT) AS DOUBLE) AS py,
         CAST(CAST(p.shoot_z AS FLOAT) AS DOUBLE) AS shoot_z FROM (
    SELECT h.*, ROW_NUMBER() OVER (PARTITION BY h.ntic, h.pellet ORDER BY h.distance,
      CASE h.hit_kind WHEN 'target' THEN 0 ELSE 1 END, h.thing_id NULLS LAST, h.line_id NULLS LAST) AS rn
    FROM pellet_hits h
  ) r JOIN shooter p ON p.ntic = r.ntic
  WHERE r.rn = 1
),
-- ---------------------------------------------------------------- 23_cs_hitscan_apply
hit_damage AS (
  SELECT ntic, thing_id, CAST(SUM(damage) AS INT) AS damage
  FROM hitscan_hits WHERE hit_kind = 'target' GROUP BY ntic, thing_id
),
H1 AS (
  SELECT h.ntic, h.map_id, h.thing_id,
    CASE WHEN d.thing_id IS NULL THEN h.health ELSE h.health - d.damage END AS health,
    h.max_health,
    CASE WHEN d.thing_id IS NULL THEN h.alive ELSE h.health - d.damage > 0 END AS alive
  FROM H0 h LEFT JOIN hit_damage d ON d.ntic = h.ntic AND d.thing_id = h.thing_id
),
puffs AS (
  SELECT h.ntic, ${map_id} AS map_id, h.shot_serial * 16 + h.pellet AS effect_id,
    CASE WHEN h.hit_kind = 'target' AND NOT h.no_blood THEN 'blood' ELSE 'puff' END AS effect_type,
    CAST(h.px + GREATEST(0.0D, h.distance - CASE WHEN h.hit_kind = 'target' THEN 10 ELSE 4 END) * COS(h.angle) AS FLOAT) AS x,
    CAST(h.py + GREATEST(0.0D, h.distance - CASE WHEN h.hit_kind = 'target' THEN 10 ELSE 4 END) * SIN(h.angle) AS FLOAT) AS y,
    CAST(h.shoot_z + h.slope * GREATEST(0.0D, h.distance - CASE WHEN h.hit_kind = 'target' THEN 10 ELSE 4 END) AS FLOAT) AS z,
    h.sector_id, 0 AS age
  FROM hitscan_hits h
),
X2 AS (
  SELECT x.* FROM X1 x LEFT ANTI JOIN puffs p ON p.ntic = x.ntic AND p.effect_id = x.effect_id
  UNION ALL
  SELECT * FROM puffs
),
shoot_events AS (
  -- Gun-activated linedefs (G1/GR), queued for the next tic's activation.
  SELECT DISTINCT h.ntic, ${map_id} AS map_id, h.player_id AS player_thing_id, h.line_id,
         'shoot' AS trigger_type, COALESCE(h.line_from_front, TRUE) AS from_front
  FROM hitscan_hits h
  JOIN linedefs ld ON ld.map_id = ${map_id} AND ld.id = h.line_id
  JOIN line_special_defs d ON d.special = ld.special AND d.shoot_activated
  WHERE h.hit_kind = 'wall'
),
-- ---------------------------------------------------------------- damage to the player
-- 24_cs_projectiles' and 26_cs_monsters' P_DamageMobj on the player, in that
-- order. Which projectiles and monster attacks land is not ported yet: the
-- recorded projectile_damage and monster_attack_damage of the tic say.
P5b AS (
  SELECT p.*, p.p_health AS health0, p.p_armor AS armor0, p.p_armor_class AS armor_class0,
         p.damage_count AS damage_count0, p.pain_face_tics AS pain_face_tics0,
         p.alive AS alive0, p.killer_id AS killer_id0,
         p.momentum_x AS momentum_x0, p.momentum_y AS momentum_y0
  FROM P5 p
),
projectile_hurt AS (
  SELECT t.ntic, t.dmg, t.green_saved, t.blue_saved, t.source_id, t.thrust_x, t.thrust_y
  FROM (
    SELECT s.ntic, CAST(SUM(s.dmg) AS INT) AS dmg,
           CAST(SUM(FLOOR(s.dmg / 3.0D)) AS INT) AS green_saved,
           CAST(SUM(FLOOR(s.dmg / 2.0D)) AS INT) AS blue_saved,
           max_by(s.source_id, CAST(s.dmg AS BIGINT) * 1000000 + s.source_id) AS source_id,
           SUM(bround(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * (s.vx - s.ix) / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_x,
           SUM(bround(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * (s.vy - s.iy) / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_y
    FROM (
      SELECT pd.tic AS ntic, pd.damage >> CASE WHEN g.skill = 0 THEN 1 ELSE 0 END AS dmg,
             CAST(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.x ELSE i.x END AS DOUBLE) AS ix,
             CAST(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.y ELSE i.y END AS DOUBLE) AS iy,
             CASE WHEN mp.owner_thing_id = ${player} THEN ${player} ELSE -1 END AS source_id,
             CAST(p.t_x AS DOUBLE) AS vx, CAST(p.t_y AS DOUBLE) AS vy,
             SQRT(POWER(CAST(p.t_x AS DOUBLE) - CAST(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.x ELSE i.x END AS DOUBLE), 2)
                + POWER(CAST(p.t_y AS DOUBLE) - CAST(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.y ELSE i.y END AS DOUBLE), 2)) AS dist
      FROM rec_projectile_damage pd
      JOIN P5b p ON p.tic = pd.tic AND p.player_thing_id = pd.thing_id
      JOIN cmd g ON g.tic = pd.tic
      JOIN rec_monster_projectiles mp ON mp.tic = pd.tic AND mp.map_id = pd.map_id AND mp.projectile_id = pd.projectile_id
      LEFT JOIN rec_projectile_impacts i ON i.tic = pd.tic AND i.map_id = pd.map_id AND i.projectile_id = pd.projectile_id
      LEFT JOIN rec_things ot ON ot.tic = pd.tic AND ot.map_id = mp.map_id AND ot.id = mp.owner_thing_id
      WHERE pd.map_id = ${map_id} AND pd.damage > 0
    ) s
    GROUP BY s.ntic
  ) t
),
P6 AS (
  SELECT q.*,
    q.armor0 - q.saved AS armor1,
    CASE WHEN q.ntic IS NOT NULL AND q.armor0 - q.saved <= 0 THEN 0 ELSE q.armor_class0 END AS armor_class1,
    GREATEST(0, q.health0 - q.took) AS health1,
    CASE WHEN q.ntic IS NULL THEN q.damage_count0 ELSE LEAST(100, q.damage_count0 + q.took) END AS damage_count1,
    CASE WHEN q.ntic IS NULL THEN q.alive0 ELSE GREATEST(0, q.health0 - q.took) > 0 END AS alive1,
    CASE WHEN q.took > 0 THEN 12 ELSE q.pain_face_tics0 END AS pain_face_tics1,
    CASE WHEN q.ntic IS NOT NULL AND q.alive0 AND q.health0 - q.took <= 0 THEN q.source_id ELSE q.killer_id0 END AS killer_id1,
    CASE WHEN q.ntic IS NULL THEN q.momentum_x0 ELSE CAST(q.momentum_x0 + q.thrust_x AS FLOAT) END AS momentum_x1,
    CASE WHEN q.ntic IS NULL THEN q.momentum_y0 ELSE CAST(q.momentum_y0 + q.thrust_y AS FLOAT) END AS momentum_y1
  FROM (
    SELECT p.*, h.ntic, h.source_id, h.thrust_x, h.thrust_y,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE LEAST(p.armor0, CASE p.armor_class0 WHEN 2 THEN h.blue_saved
                                                             WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS saved,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE h.dmg - LEAST(p.armor0, CASE p.armor_class0 WHEN 2 THEN h.blue_saved
                                                                     WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS took
    FROM P5b p LEFT JOIN projectile_hurt h ON h.ntic = p.tic
  ) q
),
monster_hurt AS (
  SELECT s.ntic, CAST(SUM(s.dmg) AS INT) AS dmg,
         CAST(SUM(FLOOR(s.dmg / 3.0D)) AS INT) AS green_saved,
         CAST(SUM(FLOOR(s.dmg / 2.0D)) AS INT) AS blue_saved,
         SUM(bround(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * s.ddx / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_x,
         SUM(bround(CASE WHEN s.dist > 0 THEN s.dmg * 0.125D * s.ddy / s.dist ELSE 0.0D END * 65536.0D)) / 65536.0D AS thrust_y
  FROM (
    SELECT d.tic AS ntic, d.dmg >> CASE WHEN g.skill = 0 THEN 1 ELSE 0 END AS dmg,
           CAST(p.t_x AS DOUBLE) - d.mx AS ddx, CAST(p.t_y AS DOUBLE) - d.my AS ddy,
           SQRT(POWER(CAST(p.t_x AS DOUBLE) - d.mx, 2) + POWER(CAST(p.t_y AS DOUBLE) - d.my, 2)) AS dist
    FROM rec_monster_attack_damage d
    -- The attack stage (and its DELETE of the last staging) runs only when a
    -- monster is on an attack frame (doom_cs_monster_plan bit 16).
    JOIN (SELECT DISTINCT tic FROM rec_monster_ai WHERE map_id = ${map_id} AND fired_this_tick) a
      ON a.tic = d.tic
    JOIN P6 p ON p.tic = d.tic AND p.player_thing_id = d.victim_player AND p.alive1
    JOIN cmd g ON g.tic = d.tic
    WHERE d.map_id = ${map_id} AND d.victim_id IS NULL
  ) s
  GROUP BY s.ntic
),
P7 AS (
  SELECT q.*,
    q.armor1 - q.msaved AS armor2,
    CASE WHEN q.mtic IS NOT NULL AND q.armor1 - q.msaved <= 0 THEN 0 ELSE q.armor_class1 END AS armor_class2,
    GREATEST(0, q.health1 - q.mtook) AS health2,
    CASE WHEN q.mtic IS NULL THEN q.damage_count1 ELSE LEAST(100, q.damage_count1 + q.mtook) END AS damage_count2,
    CASE WHEN q.mtic IS NULL THEN q.alive1 ELSE GREATEST(0, q.health1 - q.mtook) > 0 END AS alive2,
    CASE WHEN q.mtook > 0 THEN 12 ELSE q.pain_face_tics1 END AS pain_face_tics2,
    CASE WHEN q.mtic IS NOT NULL AND q.alive1 AND q.health1 - q.mtook <= 0 THEN -1 ELSE q.killer_id1 END AS killer_id2,
    CASE WHEN q.mtic IS NULL THEN q.momentum_x1 ELSE CAST(q.momentum_x1 + q.mthrust_x AS FLOAT) END AS momentum_x2,
    CASE WHEN q.mtic IS NULL THEN q.momentum_y1 ELSE CAST(q.momentum_y1 + q.mthrust_y AS FLOAT) END AS momentum_y2
  FROM (
    SELECT p.*, h.ntic AS mtic, h.thrust_x AS mthrust_x, h.thrust_y AS mthrust_y,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE LEAST(p.armor1, CASE p.armor_class1 WHEN 2 THEN h.blue_saved
                                                             WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS msaved,
      COALESCE(CASE WHEN p.god_mode OR p.invuln_tics > 0 THEN 0
                    ELSE h.dmg - LEAST(p.armor1, CASE p.armor_class1 WHEN 2 THEN h.blue_saved
                                                                     WHEN 1 THEN h.green_saved ELSE 0 END) END, 0) AS mtook
    FROM P6 p LEFT JOIN monster_hurt h ON h.ntic = p.tic
  ) q
),
next_world2 AS (
  -- The player row after this file's stages, in next_world's columns.
  SELECT p.tic, p.map_id, p.player_thing_id, p.health2 AS health, p.alive2 AS alive, p.level_tics,
    p.previous_x, p.previous_y, p.position_x, p.position_y, p.base_z, p.view_z, p.view_angle,
    p.momentum_x2 AS momentum_x, p.momentum_y2 AS momentum_y, p.bob_strength,
    p.previous_view_z, p.previous_view_angle,
    p.sector_id, p.pain_face_tics2 AS pain_face_tics, p.armor2 AS armor, p.armor_class2 AS armor_class,
    p.p_backpack AS backpack, p.q_ammo_bullets AS ammo_bullets, p.q_ammo_shells AS ammo_shells,
    p.q_ammo_rockets AS ammo_rockets, p.q_ammo_cells AS ammo_cells,
    p.p_key_blue AS key_blue, p.p_key_yellow AS key_yellow, p.p_key_red AS key_red,
    p.p_radsuit_tics AS radsuit_tics, p.p_invis_tics AS invis_tics, p.momentum_z,
    p.damage_count2 AS damage_count, p.p_bonus_count AS bonus_count, p.p_light_amp_tics AS light_amp_tics,
    p.p_power_map AS power_map, p.god_mode, p.noclip, p.p_invuln_tics AS invuln_tics,
    p.berserk, p.p_message AS message, p.p_message_tics AS message_tics, p.frags,
    p.death_tics, p.killer_id2 AS killer_id, p.sprite_frame, p.t_x, p.t_y, p.t_z, p.t_angle, p.last_mode
  FROM P7 p
),
