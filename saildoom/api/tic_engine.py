"""The game tic planned once and run every tic.

The tic is one large query (sql/tic_*.sql); on Sail, planning it takes
seconds and running it milliseconds. The querygraph/sail fork can keep a
query's physical plan and run it again (spark.sail.planCache), and can hold a
view's rows in a slot that a kept plan reads afresh each time
(spark.sail.slotViews). So the tic runs in a Spark session of its own, where
every input that changes from tic to tic is a slot: the world's tables (cut to
the map), the commands, render_segs, and tic_params for the one value folded
into the SQL that changes (the next sound event id). The SQL text is the same
every tic of a level, so only the first tic of a level is planned.

The definition tables the tic reads are plain views. They do not change while
a game runs; if one does, it is registered again and the cache is cleared.
"""

import os
import re
import time
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc

from .. import engine, game
from ..sqlmacro import expand, strip_comments

FILES = game.TIC_FILES[:-1] + ("tic_out.sql", "tic_staging.sql")
# The level's geometry, cut to the map: slots too, refilled on a new level.
STATIC_BY_MAP = ("linedef_geom", "node_path_steps", "nodes", "linedefs", "sector_adjacency",
                 "vertexes", "maps", "node_children", "segs", "ssectors")
SKIP_FIELDS = ("t_x", "t_y", "t_z", "t_angle", "last_mode")


def tic_tables():
    """The tables the tic SQL reads by name, other than its CTEs."""
    text = "\n".join(strip_comments((game.ROOT / "sql" / f).read_text()) for f in FILES)
    ctes = set(re.findall(r"^\s*(\w+) AS \(", text, re.M))
    return set(re.findall(r"\b(?:FROM|JOIN)\s+(\w+)", text, re.I)) - ctes


class TicEngine:
    def __init__(self, store, world):
        from pyspark.sql import SparkSession
        url = os.environ.get("SAIL_REMOTE", "sc://localhost:50051")
        self.spark = SparkSession.builder.remote(url).create()
        for key, value in engine.CLIENT_CONFIGS.items():
            self.spark.conf.set(key, value)
        self.store = store
        self.world = world
        self.kind_tables = {t for _, t in world.kinds.values()}
        read = tic_tables()
        self.static = sorted(t for t in read if t in store.paths and t not in self.kind_tables
                             and t not in STATIC_BY_MAP and t != "render_segs")
        slots = ["rec_" + t for t in sorted(self.kind_tables)] + ["cmd", "tic_params", "render_segs"]
        slots += list(STATIC_BY_MAP)
        self.spark.conf.set("spark.sail.slotViews", ",".join(slots))
        self.spark.conf.set("spark.sail.planCache", "true")
        partitions = os.environ.get("SAILDOOM_TIC_PARTITIONS")
        if partitions:
            self.spark.conf.set("spark.sql.shuffle.partitions", partitions)
        self.loaded = {}
        self.map_id = None
        self.sql = {}

    def _slot(self, name, sql):
        self.spark.sql(sql).createOrReplaceTempView(name)

    def _clear_cache(self):
        self.spark.conf.set("spark.sail.planCache", "false")
        self.spark.sql("SELECT 1").collect()
        self.spark.conf.set("spark.sail.planCache", "true")

    def _refresh(self, map_id, player, cmd_sql, se_next):
        s = self.store
        changed_static = False
        for name in self.static:
            if self.loaded.get(name) != s.paths[name]:
                self.spark.read.parquet(s.paths[name]).createOrReplaceTempView(name)
                changed_static = changed_static or name in self.loaded
                self.loaded[name] = s.paths[name]
        if changed_static:
            self._clear_cache()
        if map_id != self.map_id:
            for name in STATIC_BY_MAP:
                self._slot(name, f"SELECT * FROM parquet.`{s.paths[name]}` WHERE map_id = {map_id}")
            self.map_id = map_id
            for name in [n for n in self.loaded if n.startswith("rec_") or n == "render_segs"]:
                del self.loaded[name]
        views = [("rec_" + t, t, "0 AS tic, *") for t in self.kind_tables] + [("render_segs", "render_segs", "*")]
        for name, table, cols in views:
            key = (s.paths[table], map_id)
            if self.loaded.get(name) != key:
                self._slot(name, f"SELECT {cols} FROM parquet.`{s.paths[table]}` WHERE map_id = {map_id}")
                self.loaded[name] = key
        self._slot("cmd", cmd_sql)
        self._slot("tic_params", f"SELECT CAST({int(se_next)} AS BIGINT) AS se_next")

    def run(self, map_id, player, skill, cmd_sql, se_next):
        """One tic: the world rows of the next tic, as an Arrow table."""
        started = time.perf_counter()
        self._refresh(map_id, player, cmd_sql, se_next)
        refreshed = time.perf_counter()
        key = (map_id, player, skill)
        if key not in self.sql:
            w = self.world
            prev = "\n  UNION ALL\n  ".join(w.recorded_rows(k, "tic = 0") for k in w.kinds)
            step = game._step_sql(w, FILES)
            params = dict(game.CONSTANTS, map_id=map_id, player=player, skill=skill,
                          se_next="(SELECT se_next FROM tic_params)")
            # One DataFrame per level, run every tic: the server keys its plan
            # cache by the relation, plan id included, and spark.sql() would
            # also send the SQL to be parsed as a command each time.
            self.sql[key] = self.spark.sql(expand(strip_comments(
                f"WITH RECURSIVE prev AS (\n  {prev}\n),\n{step}\nSELECT * FROM step"), params))
        df = self.sql[key]
        sent = time.perf_counter()
        out = df.toArrow()
        if os.environ.get("SAILDOOM_TIC_TIMING"):
            print(f"tic engine: refresh {refreshed - started:.3f}s, sql {sent - refreshed:.3f}s, "
                  f"run {time.perf_counter() - sent:.3f}s", flush=True)
        return out


def write_kinds(store, world, out, map_id, player):
    """Every kind's table: the other maps' rows (other players' for the
    player) and this tic's rows of the kind, in the types the tic computed."""
    for kind, (col, table) in world.kinds.items():
        names = [n for n, _ in world.fields[kind] if n not in SKIP_FIELDS]
        rows = out.filter(pc.equal(out["kind"], kind)).column(col)
        rows = rows.combine_chunks() if isinstance(rows, pa.ChunkedArray) else rows
        new = pa.table({n: rows.field(n) for n in names}) if len(rows) else None
        old = store.arrow(table).select(names)
        if kind == "P":
            keep = pc.invert(pc.and_(pc.equal(old["map_id"], map_id), pc.equal(old["player_thing_id"], player)))
        else:
            keep = pc.not_equal(old["map_id"], map_id)
        old = old.filter(keep)
        schema = new.schema if new is not None else pa.schema(
            [pa.field(n, rows.type.field(n).type) for n in names])
        old = old.cast(schema)
        store.write_arrow(table, pa.concat_tables([old, new]) if new is not None else old)
