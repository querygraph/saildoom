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
import shutil
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
    "USERANGE": "64.0D", "PSPRITE_EPSILON": "0.001D", "PSPRITE_REST_X": "1.0D",
    "PSPRITE_REST_Y": "32.0D", "ATTACK_Z_OFFSET": "8.0D", "AIM_SPREAD_DEGREES": "5.625D",
    "AUTOAIM_SLOPE": "0.625D", "SLOPE_UNBOUNDED": "1000000.0D", "GUNSHOT_SPREAD_UNITS": "16384.0D",
    "DROPPED_THING_ID_BASE": "100000", "PICKUP_REACH": "36.0D", "BONUSADD": "6",
    "MESSAGE_TICS": "140", "MISSILE_SPAWN_Z": "32.0D", "SHADOW_SPREAD_UNITS": "4096.0D",
    "PROJECTILE_EFFECT_ID_BASE": "3000000000000", "MISSILE_SPAWN_AHEAD": "20.0D",
    "NIGHTMARE_MISSILE_SPEED": "20.0D", "MELEE_REACH": "68.0D", "DEFAULT_ATTACK_RANGE": "2048.0D",
    "SIGHT_RANGE": "1200.0D", "MIN_WALK_OPENING": "56.0D", "MONSTER_STEP": "8.0D",
    "CHASE_AXIS_DEADBAND": "10.0D", "CHASE_SWAP_CHANCE": "200.0D", "CHASE_MOVECOUNT_MASK": "15",
    "SKULL_CHARGE_SPEED": "20.0D", "SKULL_HIT_REACH": "36.0D", "TICRATE": "35",
    "MONSTER_RESPAWN_TICS": "420", "MONSTER_RESPAWN_EFFECT_ID_BASE": "4100000000",
    "EFFECT_ID_TIC_SPAN": "4096", "HITSCAN_SPREAD_UNITS": "4096.0D", "SHADOW_MISS_UNITS": "2048.0D", "DAMAGE_FLOOR_INTERVAL": "32",
}

STATIC_TABLES = ("linedef_geom", "thing_blocking_defs", "thing_combat_defs",
                 "node_path_steps", "nodes", "render_segs", "linedefs",
                 "line_special_defs", "sector_adjacency", "sector_special_defs",
                 "pickup_defs", "pickup_messages", "ammo_defs", "weapon_defs", "weapon_frames",
                 "projectile_defs", "chase_dir_defs", "thing_role_defs", "thing_ai_frames",
                 "thing_sprite_defs", "vertexes", "walltex_meta",
                 "boss_actions", "maps")


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
    # The commands as CedarDB stored them (game_tic_commands, real columns):
    # the bot's floats went in as decimal text, which rounds to real directly,
    # not through a double.
    spark.sql(f"""SELECT tic, skill, skill_bit, move_fwd, move_strafe, running, turn_degrees,
                         attack_held, weapon_switch_to, use_requested
                  FROM rec_game_tic_commands
                  WHERE map_id = {map_id} AND player_thing_id = {run["player_thing_id"]}"""
              ).createOrReplaceTempView("cmd")
    return Run(map_id, run["player_thing_id"], run["skill"], run["tics"])


def _params(run):
    return dict(CONSTANTS, map_id=run.map_id, player=run.player)


def _world(run_dir):
    return World(Path(run_dir) / "state")


def _step_sql(world):
    """The tic: CTEs from `prev` (world rows at tic t) to `step`, world rows at t + 1."""
    body = "\n".join(strip_comments((ROOT / "sql" / name).read_text()).strip().rstrip(",") + ","
                     for name in ("tic_doors.sql", "tic_step.sql", "tic_combat.sql",
                                  "tic_projectiles.sql", "tic_monsters.sql", "tic_out.sql"))
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
    sql = (f"WITH RECURSIVE prev AS (\n  {_recorded(world, f'tic < {tics}')}\n),\n"
           + _step_sql(world) + "\nSELECT * FROM step")
    return _fetch(spark, expand(sql, _params(run)))


def simulate(spark, run, tics, run_dir, data=None):
    """The run as one recursive query: tic 0 from the recording, or with
    `data` (the map's tables) from Sail's own level start; then the tic."""
    world = _world(run_dir)
    params = _params(run)
    if data is not None:
        start, flags = _level_start_sql(spark, data, run, run_dir)
        anchor = f"SELECT * FROM (\n{start}\n) level_start"
        params.update(skill=run.skill, **flags)
    else:
        anchor = _recorded(world, "tic = 0")
    sql = f"""WITH RECURSIVE world AS (
  {anchor}
  UNION ALL
  SELECT * FROM (
    WITH RECURSIVE prev AS (SELECT * FROM world),
{_step_sql(world)}
    SELECT * FROM step
  ) s
  WHERE s.tic <= {tics}
)
SELECT * FROM world"""
    return _fetch(spark, expand(sql, params))


MAP_TABLES = ("sectors", "sidedefs", "render_segs", "things", "render_things", "line_buttons")


def run_cheats(run_dir):
    """The cheats reference/record_run.py typed before tic 1."""
    meta = json.loads((Path(run_dir) / "run.json").read_text())
    tour = meta.get("tour", (Path(run_dir) / "tour.json").exists())
    return {"god": not meta.get("mortal", False), "noclip": bool(tour),
            "arsenal": True, "keys": True}


def _level_start_sql(spark, data, run, run_dir, cheats=None):
    for name in MAP_TABLES:
        df = spark.read.parquet(str(Path(data) / f"{name}.parquet")).filter(f"map_id = {run.map_id}")
        df.createOrReplaceTempView("map_" + name)
    world = _world(run_dir)
    cheats = cheats or run_cheats(run_dir)
    body = strip_comments((ROOT / "sql" / "level_start.sql").read_text())
    packed = "\n  UNION ALL\n  ".join(
        world.pack_select(kind, f"{kind}_out", tic="tic" if kind == "P" else "ntic") for kind in KINDS)
    sql = (f"WITH RECURSIVE prev AS (\n  {_recorded(world, 'tic < 0')}\n),\n"
           + world.unpack_ctes("prev") + ",\n" + body.strip().rstrip(",") + ","
           + f"\nstep AS (\n  {packed}\n)\nSELECT * FROM step")
    return sql, {k: str(v).upper() for k, v in cheats.items()}


def level_start(spark, data, run, run_dir, cheats=None):
    """The world at tic 0, computed on Sail from the map's tables
    (sql/level_start.sql), as {kind: [rows]}."""
    sql, flags = _level_start_sql(spark, data, run, run_dir, cheats)
    return _fetch(spark, expand(sql, dict(_params(run), skill=run.skill, **flags)))


def recorded(spark, run, tics, run_dir):
    world = _world(run_dir)
    sql = f"SELECT * FROM ({_recorded(world, f'tic <= {tics}')}) w"
    return _fetch(spark, expand(sql, _params(run)))


def _fetch(spark, sql):
    """Run `sql`, the server writing the rows to Parquet here (a whole run's
    world is more than one gRPC message), and split them by kind."""
    out = ROOT / "data" / "world-out"
    shutil.rmtree(out, ignore_errors=True)
    spark.sql(sql).write.parquet(str(out))
    return split(pq.read_table(out))


def split(table):
    """World rows -> {kind: [row dict with tic]}."""
    out = {kind: [] for kind in KINDS}
    for kind, col in ((k, c) for k, (c, _) in KINDS.items()):
        rows = table.filter(pc.equal(table["kind"], kind))
        for tic, row in zip(rows["tic"].to_pylist(), rows[col].to_pylist()):
            out[kind].append(dict(row, tic=tic))
    return out
