"""The game tic on Sail: running SQLDoom's tic as Spark SQL.

`sql/tic_step.sql` advances the world by one tic. It runs two ways:

- `step_all`: every recorded tic t of a run -> t + 1, in one query. Each tic
  starts from CedarDB's recorded state, so one step is checked in isolation.
- `simulate`: the whole run as one `WITH RECURSIVE` query from tic 0, each tic
  starting from the one before. This needs a Sail with recursive CTEs.

Stages that are not ported yet read the recorded run (`rec_*` views).
"""

import json
import os
from dataclasses import dataclass
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

from . import engine
from .sqlmacro import expand, strip_comments

ROOT = Path(__file__).resolve().parents[1]

# doom_constants, as the tic reads them (double precision).
CONSTANTS = {
    "VIEWHEIGHT": "41.0D", "FORWARDMOVE": "25.0D", "FORWARDMOVE_RUN": "50.0D",
    "SIDEMOVE": "24.0D", "SIDEMOVE_RUN": "40.0D", "THRUST_UNIT": "0.03125D",
    "MAXMOVE": "30.0D", "PLAYER_RADIUS": "16.0D", "PLAYER_HEIGHT": "56.0D",
    "MAXSTEP": "24.0D", "BLOCK_MARGIN": "2.0D", "GRAVITY": "1.0D",
    "BOB_FACTOR": "4.0D", "MAXBOB": "16.0D", "POS_EPSILON": "1e-7D",
    "BOB_PERIOD_TICS": "20.0D", "STOPSPEED": "0.0625D", "FRICTION": "0.90625D",
}

STATIC_TABLES = ("linedef_geom", "thing_blocking_defs", "thing_combat_defs",
                 "node_path_steps", "nodes", "render_segs")


@dataclass
class Run:
    map_id: int
    player: int
    skill: int
    tics: int


def connect():
    return engine.connect(os.environ.get("SAIL_REMOTE", "sc://localhost:50052"))


def load_run_for_tics(spark, data, run_dir):
    """Static map tables, the recorded run as rec_* views, and its commands as cmd."""
    run = json.loads((Path(run_dir) / "run.json").read_text())
    map_id = run["map_id"]
    for name in STATIC_TABLES:
        df = spark.read.parquet(str(Path(data) / f"{name}.parquet"))
        if "map_id" in df.columns:
            df = df.filter(f"map_id = {map_id}")
        df.createOrReplaceTempView(name)
    for path in sorted((Path(run_dir) / "state").glob("*.parquet")):
        spark.read.parquet(str(path)).createOrReplaceTempView("rec_" + path.stem)
    commands = json.loads((Path(run_dir) / "commands.json").read_text())
    skill = lambda c: c[0]
    table = pa.table({
        "tic": pa.array([c["tic"] for c in commands], pa.int32()),
        "skill": pa.array([skill(c["command"]) for c in commands], pa.int32()),
        "skill_bit": pa.array([1 if skill(c["command"]) <= 1 else 2 if skill(c["command"]) == 2 else 4
                               for c in commands], pa.int32()),
        "move_fwd": pa.array([c["command"][1] for c in commands], pa.float32()),
        "move_strafe": pa.array([c["command"][2] for c in commands], pa.float32()),
        "running": pa.array([bool(c["command"][3]) for c in commands], pa.bool_()),
        "turn_degrees": pa.array([c["command"][4] for c in commands], pa.float32()),
        "attack_held": pa.array([bool(c["command"][5]) for c in commands], pa.bool_()),
        "weapon_switch_to": pa.array([c["command"][6] for c in commands], pa.int32()),
        "use_requested": pa.array([bool(c["command"][7]) for c in commands], pa.bool_()),
    })
    path = ROOT / "data" / "commands.parquet"
    pq.write_table(table, path)
    spark.read.parquet(str(path)).createOrReplaceTempView("cmd")
    return Run(map_id, run["player_thing_id"], run["skill"], run["tics"])


def _params(run):
    return dict(CONSTANTS, map_id=run.map_id, player=run.player)


def _step_sql():
    return strip_comments((ROOT / "sql" / "tic_step.sql").read_text())


PREV = """prev AS (
  SELECT ps.*, t.x AS t_x, t.y AS t_y, t.z AS t_z, t.angle AS t_angle
  FROM rec_player_state ps
  JOIN rec_things t ON t.tic = ps.tic AND t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.map_id = ${map_id} AND ps.player_thing_id = ${player} AND {where}
)"""


def step_all(spark, run, tics):
    sql = ("WITH " + PREV.replace("{where}", f"ps.tic < {tics}") + ",\n"
           + _step_sql() + "\nSELECT * FROM next_world ORDER BY tic")
    return spark.sql(expand(sql, _params(run))).toArrow()


WORLD_COLUMNS = (
    "tic, map_id, player_thing_id, health, alive, level_tics, previous_x, previous_y, "
    "position_x, position_y, base_z, view_z, view_angle, momentum_x, momentum_y, "
    "bob_strength, previous_view_z, previous_view_angle, sector_id, pain_face_tics, armor, "
    "armor_class, backpack, ammo_bullets, ammo_shells, ammo_rockets, ammo_cells, key_blue, "
    "key_yellow, key_red, radsuit_tics, invis_tics, momentum_z, damage_count, bonus_count, "
    "light_amp_tics, power_map, god_mode, noclip, invuln_tics, berserk, message, "
    "message_tics, frags, death_tics, killer_id, sprite_frame, t_x, t_y, t_z, t_angle, last_mode")


def simulate(spark, run, tics):
    """The run as one recursive query: tic 0 from the recording, then tic_step."""
    start = PREV.replace("{where}", "ps.tic = 0")
    start = start[start.index("(") + 1:start.rindex(")")]
    sql = f"""WITH RECURSIVE world AS (
  SELECT {WORLD_COLUMNS} FROM (SELECT *, CAST(NULL AS STRING) AS last_mode FROM ({start}) s00) s0
  UNION ALL
  SELECT * FROM (
    WITH prev AS (SELECT * FROM world),
{_step_sql()}
    SELECT {WORLD_COLUMNS} FROM next_world
  ) step
  WHERE step.tic <= {tics}
)
SELECT * FROM world ORDER BY tic"""
    return spark.sql(expand(sql, _params(run))).toArrow()


def recorded_players(spark, run, tics):
    sql = ("WITH " + PREV.replace("{where}", f"ps.tic <= {tics}")
           + "\nSELECT * FROM prev ORDER BY tic")
    return spark.sql(expand(sql, _params(run))).toArrow()
