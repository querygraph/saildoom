"""The world as one relation, for WITH RECURSIVE.

A recursive CTE yields one relation, and SQLDoom's tic updates many tables. The
world relation holds them all: (tic, kind, p, s, m, e, a, b, d, r), where `kind`
says which table a row belongs to and the matching struct column holds the
row, the others NULL. The tables' columns are those of the recorded run's
snapshots (reference/record_run.py), so the struct types are read from there.

`unpack_ctes` turns the relation `prev` into one CTE per table, keyed by the
tic being computed (`ntic`); `pack_select` turns a CTE of one table back into
world rows.
"""

from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

# kind -> (struct column, recorded table)
KINDS = {
    "P": ("p", "player_state"),
    "S": ("s", "sectors"),
    "M": ("m", "sector_movers"),
    "E": ("e", "line_special_events"),
    "A": ("a", "line_activations"),
    "B": ("b", "line_buttons"),
    "D": ("d", "sidedefs"),
    "R": ("r", "render_segs"),
    "T": ("t", "things"),
    "H": ("h", "thing_health"),
    "I": ("i", "monster_ai"),
    "N": ("n", "render_things"),
    "X": ("x", "world_effects"),
    "W": ("w", "player_weapons"),
    "O": ("o", "player_weapon_owned"),
    "U": ("u", "picked_up_items"),
    "L": ("l", "level_secret_discoveries"),
    "Y": ("y", "mapped_lines"),
    "Q": ("q", "monster_projectiles"),
    "Z": ("z", "monster_deaths"),
    "F": ("f", "sector_light_fx"),
    "PI": ("pi", "projectile_impacts"),
}

# The player row also carries the player Thing and the last movement mode.
PLAYER_EXTRA = [("t_x", "FLOAT"), ("t_y", "FLOAT"), ("t_z", "FLOAT"),
                ("t_angle", "FLOAT"), ("last_mode", "STRING")]


def _sql_type(t: pa.DataType) -> str:
    if pa.types.is_int32(t):
        return "INT"
    if pa.types.is_int64(t):
        return "BIGINT"
    if pa.types.is_float32(t):
        return "FLOAT"
    if pa.types.is_float64(t):
        return "DOUBLE"
    if pa.types.is_boolean(t):
        return "BOOLEAN"
    if pa.types.is_string(t):
        return "STRING"
    if pa.types.is_timestamp(t):
        return "TIMESTAMP"
    if pa.types.is_int16(t) or pa.types.is_int8(t):
        return "INT"
    raise TypeError(t)


# What the API backend's tic also carries: SQLDoom's per-tic staging tables,
# which keep their rows until the stage that writes them runs again.
TRANSIENT_KINDS = {
    "GC": ("gc", "game_tic_commands"),
    "LU": ("lu", "line_use_results"),
    "PT": ("pt", "pickup_touches"),
    "PG": ("pg", "pickup_grants"),
    "MS": ("ms", "monster_steps"),
    "MA": ("ma", "monster_attack_damage"),
    "MT": ("mt", "monster_teleports"),
    "MR": ("mr", "monster_respawns"),
    "PD": ("pd", "projectile_damage"),
    "HH": ("hh", "hitscan_hits"),
    "SE": ("se", "sound_events"),
    "TT": ("tt", "tic_trace"),
    "SQ": ("sq", "_sound_attempts"),
}


class World:
    """The world's kinds and their columns. `state_dir` holds a recorded run's
    snapshots (each table with a leading tic column); `schemas` is the
    alternative, {table: pyarrow schema} without one."""

    def __init__(self, state_dir=None, schemas=None, kinds=None):
        self.kinds = dict(kinds or KINDS)
        self.fields = {}
        for kind, (_, table) in self.kinds.items():
            if schemas is not None:
                schema = schemas[table]
            else:
                schema = pq.read_schema(Path(state_dir) / f"{table}.parquet")
            fields = [(f.name, _sql_type(f.type)) for f in schema if f.name != "tic"]
            if kind == "P":
                fields += PLAYER_EXTRA
            self.fields[kind] = fields

    def struct_type(self, kind):
        return "STRUCT<" + ", ".join(f"{n}: {t}" for n, t in self.fields[kind]) + ">"

    def unpack_ctes(self, source="prev"):
        """One CTE per kind: P0, S0, ... with ntic (the tic being computed)."""
        out = []
        for kind, (col, _) in self.kinds.items():
            out.append(f"{kind}0 AS (SELECT tic + 1 AS ntic, {col}.* "
                       f"FROM {source} WHERE kind = '{kind}')")
        return ",\n".join(out)

    def pack_select(self, kind, relation, tic="ntic"):
        """World rows for `relation`, a CTE holding kind's columns and `tic`."""
        cols = []
        for k, (col, _) in self.kinds.items():
            if k == kind:
                parts = ", ".join(f"'{n}', CAST(rr.{n} AS {t})" for n, t in self.fields[k])
                cols.append(f"named_struct({parts}) AS {col}")
            else:
                cols.append(f"CAST(NULL AS {self.struct_type(k)}) AS {col}")
        return (f"SELECT rr.{tic} AS tic, '{kind}' AS kind, " + ", ".join(cols)
                + f" FROM {relation} rr")

    def recorded_rows(self, kind, where, player_join=False):
        """World rows of one kind from the recorded rec_* tables."""
        col, table = self.kinds[kind]
        if kind == "P":
            relation = (f"(SELECT ps.*, t.x AS t_x, t.y AS t_y, t.z AS t_z, t.angle AS t_angle, "
                        f"CAST(NULL AS STRING) AS last_mode FROM rec_player_state ps "
                        f"JOIN rec_things t ON t.tic = ps.tic AND t.map_id = ps.map_id "
                        f"AND t.id = ps.player_thing_id WHERE ps.map_id = ${{map_id}} "
                        f"AND ps.player_thing_id = ${{player}} AND {where.replace('tic', 'ps.tic')})")
        else:
            relation = f"(SELECT * FROM rec_{table} WHERE map_id = ${{map_id}} AND {where})"
        return self.pack_select(kind, relation, tic="tic")
