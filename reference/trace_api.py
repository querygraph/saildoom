"""Record a trace of SQLDoom's database API on CedarDB, for checking the Sail
backend (saildoom/backend.py) call by call.

A scenario is a sequence of doom_sql.py calls -- the ones SQLDoom's client
makes. Every prepared statement the scenario executes is recorded with its
parameters and the rows it returned, and after it every mutable table that
changed is snapshotted (map-keyed tables only for the scenario's maps). The
tables at the start go to <out>/initial/, so the backend can start from the
same state.

  trace_api.py --sqldoom ../sqldoom --dsn ... --scenario menus --out reference/trace-menus
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

import psycopg2
import pyarrow as pa
import pyarrow.parquet as pq

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from export_cedar import OID_TYPES  # noqa: E402
import scenarios  # noqa: E402

# Tables a game never writes: the WAD's geometry and art, and the game's
# definitions. Everything else is snapshotted.
STATIC = {
    "wads", "maps", "vertexes", "linedefs", "segs", "sector_sound_origins", "ssectors", "nodes",
    "node_children", "reject_lumps", "blockmaps", "colormap_rgb", "walltex_meta", "flat_textures",
    "sprite_frames", "sprite_lumps", "ui_patches", "ui_patch_pixels", "sound_assets",
    "music_assets", "map_music", "thing_sprite_defs", "pickup_messages", "chase_dir_defs",
    "thing_role_defs", "thing_blocking_defs", "projectile_defs", "thing_combat_defs",
    "weapon_defs", "weapon_frames", "doom_constants", "thing_ai_frames", "effect_sprite_defs",
    "ammo_defs", "pickup_defs", "menu_items", "menu_decor", "level_pars", "boss_actions",
    "finale_defs", "line_special_defs", "sector_special_defs", "thing_sound_defs",
}


def mutable_tables(cur):
    cur.execute("""SELECT table_name FROM information_schema.tables
                   WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
                   ORDER BY table_name""")
    return [t for (t,) in cur.fetchall() if t not in STATIC]


def has_map_id(cur, table):
    cur.execute("""SELECT 1 FROM information_schema.columns
                   WHERE table_name = %s AND column_name = 'map_id'""", (table,))
    return cur.fetchone() is not None


def snapshot(cur, table, maps=None):
    where = "" if maps is None else f" WHERE map_id IN ({','.join(map(str, maps or [-1]))})"
    cur.execute(f'SELECT * FROM "{table}"{where}')
    rows = cur.fetchall()
    fields = [pa.field(d.name, OID_TYPES.get(d.type_code, pa.string())) for d in cur.description]
    cols = list(zip(*rows)) if rows else [[] for _ in fields]
    arrays = []
    for col, f in zip(cols, fields):
        values = [None if v is None else (str(v) if f.type == pa.string() else
                  float(v) if f.type == pa.float64() else bytes(v) if f.type == pa.binary() else v)
                  for v in col]
        arrays.append(pa.array(values, f.type))
    table = pa.Table.from_arrays(arrays, schema=pa.schema(fields))
    # CedarDB returns rows in no fixed order; compare and store them sorted.
    keys = [(f.name, "ascending") for f in fields if not pa.types.is_binary(f.type)]
    return table.sort_by(keys) if keys and table.num_rows else table


class Recorder:
    def __init__(self, cur, out, maps):
        self.cur, self.out, self.maps = cur, Path(out), maps
        self.tables = mutable_tables(cur)
        self.keyed = {t for t in self.tables if has_map_id(cur, t)}
        self.last = {}
        self.calls = []
        (self.out / "initial").mkdir(parents=True, exist_ok=True)
        for t in self.tables:
            table = snapshot(cur, t)
            pq.write_table(table, self.out / "initial" / f"{t}.parquet")
            self.last[t] = self._view(t, table)
        cur.execute("SELECT 'sound_events_event_id_seq' AS name, last_value FROM sound_events_event_id_seq")
        name, value = cur.fetchone()
        pq.write_table(pa.table({"name": [name], "last_value": [int(value)]}),
                       self.out / "initial" / "_sequences.parquet")

    def _view(self, t, table):
        if t in self.keyed:
            import pyarrow.compute as pc
            table = table.filter(pc.is_in(table["map_id"], pa.array(self.maps, pa.int32())))
        return table

    def value(self, n, v):
        """A value as Python source. A bytea (a rendered frame) is stored beside
        calls.json and recorded as its digest, which check_api.py compares."""
        if isinstance(v, (memoryview, bytes, bytearray)):
            v = bytes(v)
            digest = hashlib.sha256(v).hexdigest()
            (self.out / "bytes").mkdir(exist_ok=True)
            (self.out / "bytes" / f"{n:05d}-{digest[:12]}.bin").write_bytes(v)
            return repr(f"sha256:{digest}:{len(v)}")
        return repr(v)

    def record(self, name, params, rows):
        n = len(self.calls)
        changed = []
        for t in self.tables:
            table = snapshot(self.cur, t, self.maps if t in self.keyed else None)
            if not table.equals(self.last[t]):
                pq.write_table(table, self.out / f"{n:05d}-{t}.parquet")
                self.last[t] = table
                changed.append(t)
        self.calls.append({"n": n, "name": name, "params": [repr(p) for p in params],
                           "rows": [[self.value(n, v) for v in r] for r in rows], "changed": changed})
        print(f"{n:5d} {name}{tuple(params)} -> {len(rows)} rows, changed {changed}", flush=True)
        if n % 50 == 0:
            self.save()

    def save(self):
        (self.out / "calls.json").write_text(json.dumps(self.calls, indent=0))
        (self.out / "trace.json").write_text(json.dumps({"maps": self.maps}))


class Proxy:
    """The cursor the scenario sees: every statement, prepared or raw, runs
    on CedarDB and is recorded; its rows are handed back from the record."""

    def __init__(self, cur, rec):
        self.cur, self.rec, self.rows = cur, rec, None

    def execute(self, query, params=None):
        self.cur.execute(query, params)
        rows = [tuple(r) for r in self.cur.fetchall()] if self.cur.description else []
        self.rec.record("SQL " + " ".join(query.split()), params or (), rows)
        self.rows = list(rows)

    @property
    def description(self):
        return self.cur.description

    def fetchone(self):
        if self.rows is None:
            return self.cur.fetchone()
        return self.rows.pop(0) if self.rows else None

    def fetchall(self):
        if self.rows is None:
            return self.cur.fetchall()
        rows, self.rows = self.rows, []
        return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sqldoom", required=True, type=Path)
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--scenario", required=True, choices=sorted(scenarios.SCENARIOS))
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    sys.path.insert(0, str(args.sqldoom))
    import doom_sql as sql

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    scenario = scenarios.SCENARIOS[args.scenario]
    rec = Recorder(cur, args.out, scenario.maps(cur, sql))

    real = sql.execute_prepared
    proxy = Proxy(cur, rec)

    def traced(c, name, params=()):
        real(c.cur, name, params)
        rows = [tuple(r) for r in c.cur.fetchall()] if c.cur.description else []
        rec.record(name, params, rows)
        c.rows = list(rows)

    sql.execute_prepared = traced
    try:
        scenario.run(proxy, sql)
    finally:
        rec.save()


if __name__ == "__main__":
    main()
