-- The tic's output: one relation per kind of world row, keyed by ntic.
-- Line events are the ones queued after this tic's activation: the player's
-- crossings and shots, and the monsters' crossings and door uses.
P_out AS (SELECT * FROM P8),
S_out AS (SELECT * FROM S2),
M_out AS (SELECT * FROM M3),
E_out AS (
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM cross_events
  UNION ALL
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM shoot_events
  UNION ALL
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM mo_cross_events
  UNION ALL
  SELECT ntic, map_id, player_thing_id, line_id, trigger_type, from_front FROM mo_use_events
),
A_out AS (SELECT * FROM A1),
B_out AS (SELECT * FROM B2),
D_out AS (SELECT * FROM D2),
R_out AS (SELECT * FROM R2),
T_out AS (SELECT * FROM T7),
H_out AS (SELECT * FROM H5),
I_out AS (SELECT * FROM I11),
N_out AS (SELECT * FROM N3),
X_out AS (SELECT * FROM X4),
W_out AS (SELECT * FROM W1),
O_out AS (SELECT * FROM O1),
U_out AS (SELECT * FROM U1),
L_out AS (SELECT * FROM L1),
Y_out AS (SELECT * FROM Y1),
Q_out AS (SELECT * FROM Q3),
Z_out AS (SELECT * FROM Z2),
F_out AS (SELECT * FROM F1),
PI_out AS (SELECT * FROM PI1)
