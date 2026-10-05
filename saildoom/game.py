"""The game tic on Sail: running SQLDoom's tic as Spark SQL.

The world is one relation (saildoom/world.py): the player, sectors, sector
movers, queued line events, one-shot activations, switch buttons, sidedefs and
render_segs, one kind of row each. `sql/tic_doors.sql` then `sql/tic_step.sql`
advance it by one tic. It runs two ways:

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
from .world import KINDS, World

ROOT = Path(__file__).resolve().parents[1]

# doom_constants, as the tic reads them (double precision).
CONSTANTS = {
    "VIEWHEIGHT": "41.0D", "FORWARDMOVE": "25.0D", "FORWARDMOVE_RUN": "50.0D",
    "SIDEMOVE": "24.0D", "SIDEMOVE_RUN": "40.0D", "THRUST_UNIT": "0.03125D",
    "MAXMOVE": "30.0D", "PLAYER_RADIUS": "16.0D", "PLAYER_HEIGHT": "56.0D",
    "MAXSTEP": "24.0D", "BLOCK_MARGIN": "2.0D", "GRAVITY": "1.0D",
    "BOB_FACTOR": "4.0D", "MAXBOB": "16.0D", "POS_EPSILON": "1e-7D",
    "BOB_PERIOD_TICS": "20.0D", "STOPSPEED": "0.0625D", "FRICTION": "0.90625D",
    "USERANGE": "64.0D",
}

STATIC_TABLES = ("linedef_geom", "thing_blocking_defs", "thing_combat_defs",
                 "node_path_steps", "nodes", "render_segs", "linedefs",
                 "line_special_defs", "sector_adjacency")


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


def _world(run_dir):
    return World(Path(run_dir) / "state")


def _step_sql(world):
    """The tic: CTEs from `prev` (world rows at tic t) to `step`, world rows at t + 1."""
    body = "\n".join(strip_comments((ROOT / "sql" / name).read_text()).strip().rstrip(",") + ","
                     for name in ("tic_doors.sql", "tic_step.sql"))
    packed = "\n  UNION ALL\n  ".join(
        world.pack_select(kind, f"{kind}_out", tic="tic" if kind == "P" else "ntic")
        for kind in KINDS)
    return (world.unpack_ctes("prev") + ",\n" + body
            + f"\nstep AS (\n  {packed}\n)")


def _recorded(world, where):
    return "\n  UNION ALL\n  ".join(world.recorded_rows(kind, where) for kind in KINDS)


def step_all(spark, run, tics, run_dir):
    """Every recorded tic t < tics advanced one tic, each from CedarDB's state."""
    world = _world(run_dir)
    sql = (f"WITH prev AS (\n  {_recorded(world, f'tic < {tics}')}\n),\n"
           + _step_sql(world) + "\nSELECT * FROM step")
    return split(spark.sql(expand(sql, _params(run))).toArrow())


def simulate(spark, run, tics, run_dir):
    """The run as one recursive query: tic 0 from the recording, then the tic."""
    world = _world(run_dir)
    sql = f"""WITH RECURSIVE world AS (
  {_recorded(world, "tic = 0")}
  UNION ALL
  SELECT * FROM (
    WITH prev AS (SELECT * FROM world),
{_step_sql(world)}
    SELECT * FROM step
  ) s
  WHERE s.tic <= {tics}
)
SELECT * FROM world"""
    return split(spark.sql(expand(sql, _params(run))).toArrow())


def recorded(spark, run, tics, run_dir):
    world = _world(run_dir)
    sql = f"SELECT * FROM ({_recorded(world, f'tic <= {tics}')}) w"
    return split(spark.sql(expand(sql, _params(run))).toArrow())


def split(table):
    """World rows -> {kind: [row dict with tic]}."""
    out = {kind: [] for kind in KINDS}
    for kind, col in ((k, c) for k, (c, _) in KINDS.items()):
        rows = table.filter(pc.equal(table["kind"], kind))
        for tic, row in zip(rows["tic"].to_pylist(), rows[col].to_pylist()):
            out[kind].append(dict(row, tic=tic))
    return out
