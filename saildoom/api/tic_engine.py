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

The definition tables the tic reads are slots as well, filled from their
files once: a plain view over a file would be read again on every run.
"""

import os
import re
import time
from concurrent.futures import ThreadPoolExecutor
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
CMD_COLUMNS = ("skill", "skill_bit", "move_fwd", "move_strafe", "running", "turn_degrees",
               "attack_held", "weapon_switch_to", "use_requested")


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
        slots += list(STATIC_BY_MAP) + self.static + ["world"]
        self.spark.conf.set("spark.sail.slotViews", ",".join(slots))
        self.spark.conf.set("spark.sail.planCache", "true")
        # A tic is a few thousand rows: one partition, no repartitioning.
        self.spark.conf.set("spark.sail.targetPartitions", os.environ.get("SAILDOOM_TIC_PARTITIONS", "1"))
        self.pool = ThreadPoolExecutor(max_workers=8)
        self.loaded = {}
        self.schemas = {}
        self.written = {}  # write_kinds' record of what it wrote last tic
        self.map_id = None
        self.sql = {}
        # The world kept in Sail (the slot `world`): valid for `world_key`
        # while the world's tables are the ones the tic last wrote.
        self.in_sail = os.environ.get("SAILDOOM_WORLD_IN_SAIL", "1") == "1"
        self.world_key = None
        self.after_write = None
        self.packs = {}
        self.steps = {}

    def _slot(self, name, sql):
        self.fills += 1
        self.spark.sql(sql).createOrReplaceTempView(name)

    def _fill(self, name, frame):
        self.fills += 1
        df = frame()
        if os.environ.get("SAILDOOM_SLOT_SCHEMAS"):
            schema = df.schema.json()
            if self.schemas.get(name) not in (None, schema):
                print(f"slot {name} schema changed:\n  {self.schemas[name][:300]}\n  {schema[:300]}", flush=True)
            self.schemas[name] = schema
        df.createOrReplaceTempView(name)

    def _clear_cache(self):
        self.spark.conf.set("spark.sail.planCache", "false")
        self.spark.sql("SELECT 1").collect()
        self.spark.conf.set("spark.sail.planCache", "true")

    def _refresh(self, map_id, player, cmd_sql, se_next):
        s = self.store
        # The definition tables are slots too: read from their files once, then
        # served from memory on every run (a plain view over a file is read
        # again by every run of the kept plan).
        static = [(name, s.paths[name]) for name in self.static if self.loaded.get(name) != s.paths[name]]
        list(self.pool.map(lambda f: self._slot(f[0], f"SELECT * FROM parquet.`{f[1]}`"), static))
        for name, path in static:
            self.loaded[name] = path
        if map_id != self.map_id:
            for name in STATIC_BY_MAP:
                self._slot(name, f"SELECT * FROM parquet.`{s.paths[name]}` WHERE map_id = {map_id}")
            self.map_id = map_id
            for name in [n for n in self.loaded if n.startswith("rec_") or n == "render_segs"]:
                del self.loaded[name]
        views = [("rec_" + t, t, True) for t in self.kind_tables] + [("render_segs", "render_segs", False)]
        # The player's command row, uploaded from the table the store holds
        # (cmd_sql reads the same row from its file).
        cmd = s.arrow("game_tic_commands")
        cmd = cmd.filter(pc.and_(pc.equal(cmd["map_id"], map_id), pc.equal(cmd["player_thing_id"], player)))
        cmd = cmd.select(list(CMD_COLUMNS))
        fills = [("cmd", lambda: engine.upload(self.spark, cmd).selectExpr("1 AS tic", *CMD_COLUMNS)),
                 ("tic_params", lambda: self.spark.sql(f"SELECT CAST({int(se_next)} AS BIGINT) AS se_next"))]
        for name, table, with_tic in views:
            key = (s.paths[table], map_id)
            if self.loaded.get(name) != key:
                # The map's rows, uploaded from the table the store holds:
                # faster than the server reading back the file just written.
                rows = s.arrow(table)
                rows = rows.filter(pc.equal(rows["map_id"], map_id))
                fills.append((name, lambda rows=rows, with_tic=with_tic: (
                    engine.upload(self.spark, rows).selectExpr("0 AS tic", "*") if with_tic
                    else engine.upload(self.spark, rows))))
                self.loaded[name] = key
        # Each fill is a round trip that the server plans and runs on its own;
        # they are independent, so they go at once.
        list(self.pool.map(lambda f: self._fill(*f), fills))

    def run(self, map_id, player, skill, cmd_sql, se_next):
        """One tic: the world rows of the next tic, as an Arrow table."""
        if self.in_sail:
            return self._run_in_sail(map_id, player, skill, se_next)
        started = time.perf_counter()
        self.fills = 0
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
                f"WITH RECURSIVE prev AS (\n  {prev}\n),\n{step},\n{changed_output(w)}"), params))
        df = self.sql[key]
        sent = time.perf_counter()
        out = df.toArrow()
        if os.environ.get("SAILDOOM_TIC_TIMING"):
            print(f"tic engine: {self.fills} fills, refresh {refreshed - started:.3f}s, sql {sent - refreshed:.3f}s, "
                  f"run {time.perf_counter() - sent:.3f}s", flush=True)
        return out


    # -- The world kept in Sail ------------------------------------------------
    #
    # The tic reads the previous world from the slot `world` and returns the
    # changed kinds' rows; the server keeps the rows it computed for `step`,
    # the whole next world, in `world` (the fork's result slot). Only the
    # tic's inputs go up each tic. When anything else has written a world
    # table (a cheat, a menu, a new level), the slot is packed again from the
    # tables.

    def world_is_current(self, key):
        return (self.world_key == key and self.after_write is not None
                and all(self.store.paths[t] == self.after_write[t] for t in self.after_write))

    def tic_written(self):
        """Called after the client has written the tic's changed kinds."""
        self.after_write = {t: self.store.paths[t] for t in self.kind_tables if t != "game_tic_commands"}

    def _run_in_sail(self, map_id, player, skill, se_next):
        started = time.perf_counter()
        self.fills = 0
        key = (map_id, player, skill)
        w = self.world
        params = dict(game.CONSTANTS, map_id=map_id, player=player, skill=skill,
                      se_next="(SELECT se_next FROM tic_params)")
        if not self.world_is_current(key):
            self._refresh(map_id, player, None, se_next)
            pack = expand(strip_comments(
                "SELECT * FROM (\n  " + "\n  UNION ALL\n  ".join(
                    w.recorded_rows(k, "tic = 0") for k in w.kinds) + "\n) packed"), params)
            if key not in self.packs:
                # Creates the slot view, with the world's columns.
                self.spark.sql(pack).createOrReplaceTempView("world")
                self.packs[key] = self.spark.sql("/* sail.result_slot=world */ " + pack)
            else:
                self.packs[key].toArrow()
            self.world_key = key
        else:
            self._refresh_inputs(map_id, player, se_next)
        refreshed = time.perf_counter()
        if key not in self.steps:
            step = game._step_sql(w, FILES)
            self.steps[key] = self.spark.sql("/* sail.result_slot=world:step */ " + expand(strip_comments(
                f"WITH RECURSIVE prev AS (\n  {world_prev(w)}\n),\n{step},\n{changed_output(w)}"), params))
        sent = time.perf_counter()
        out = self.steps[key].toArrow()
        if os.environ.get("SAILDOOM_TIC_TIMING"):
            print(f"tic engine: {self.fills} fills, refresh {refreshed - started:.3f}s, sql 0.000s, "
                  f"run {time.perf_counter() - sent:.3f}s", flush=True)
        return out

    def _refresh_inputs(self, map_id, player, se_next):
        """The slots a tic reads besides the world: the command, the command
        table's rows (the client writes them before the tic) and tic_params."""
        s = self.store
        cmd = s.arrow("game_tic_commands")
        rows = cmd.filter(pc.equal(cmd["map_id"], map_id))
        mine = cmd.filter(pc.and_(pc.equal(cmd["map_id"], map_id), pc.equal(cmd["player_thing_id"], player)))
        mine = mine.select(list(CMD_COLUMNS))
        fills = [("cmd", lambda: engine.upload(self.spark, mine).selectExpr("1 AS tic", *CMD_COLUMNS)),
                 ("tic_params", lambda: self.spark.sql(f"SELECT CAST({int(se_next)} AS BIGINT) AS se_next")),
                 ("rec_game_tic_commands", lambda: engine.upload(self.spark, rows).selectExpr("0 AS tic", "*"))]
        self.loaded["rec_game_tic_commands"] = (s.paths["game_tic_commands"], map_id)
        list(self.pool.map(lambda f: self._fill(*f), fills))


def world_prev(world):
    """`prev` read from the slot `world` (the last tic's `step`), as the
    tables would give it: the player's row with its Thing's position and no
    movement mode (World.recorded_rows), and the commands from their table,
    which the client writes before every tic."""
    cols = [col for col, _ in world.kinds.values()]
    pcol, tcol = world.kinds["P"][0], world.kinds["T"][0]
    others = (f"SELECT 0 AS tic, kind, {', '.join(cols)} FROM world WHERE kind NOT IN ('P', 'GC')")
    from_thing = {"t_x": "x", "t_y": "y", "t_z": "z", "t_angle": "angle"}
    parts = []
    for n, t in world.fields["P"]:
        if n in from_thing:
            value = f"th.{tcol}.{from_thing[n]}"
        elif n == "last_mode":
            value = "NULL"
        else:
            value = f"w.{pcol}.{n}"
        parts.append(f"'{n}', CAST({value} AS {t})")
    player_cols = ", ".join(
        f"named_struct({', '.join(parts)}) AS {col}" if k == "P" else f"CAST(NULL AS {world.struct_type(k)}) AS {col}"
        for k, (col, _) in world.kinds.items())
    player = (f"SELECT 0 AS tic, 'P' AS kind, {player_cols} FROM world w "
              f"JOIN world th ON th.kind = 'T' AND th.{tcol}.map_id = w.{pcol}.map_id "
              f"AND th.{tcol}.id = w.{pcol}.player_thing_id "
              f"WHERE w.kind = 'P' AND w.{pcol}.map_id = ${{map_id}} AND w.{pcol}.player_thing_id = ${{player}}")
    commands = world.recorded_rows("GC", "tic = 0")
    return "\n  UNION ALL\n  ".join([others, player, commands])


def changed_output(world):
    """The tail of the tic query: only the rows of kinds that changed, and a
    marker row (tic -1) per changed kind. Every row carries every kind's
    struct column, so the whole world is megabytes of nulls a tic; most
    kinds do not change from one tic to the next. A kind changed when its
    row count or the XOR of its rows' hashes differs from the world the tic
    started from (`prev`)."""
    sums = []
    for kind, (col, _) in world.kinds.items():
        for rel in ("step", "prev"):
            sums.append(f"SELECT '{rel}' AS rel, '{kind}' AS kind, count(*) AS n, "
                        f"bit_xor(xxhash64({col})) AS h FROM {rel} WHERE kind = '{kind}'")
    nulls = ", ".join(f"CAST(NULL AS {world.struct_type(k)}) AS {col}" for k, (col, _) in world.kinds.items())
    return (f"kind_sums AS (\n  " + "\n  UNION ALL\n  ".join(sums) + "\n),\n"
            "changed AS (\n"
            "  SELECT a.kind FROM kind_sums a JOIN kind_sums b ON a.kind = b.kind\n"
            "  WHERE a.rel = 'step' AND b.rel = 'prev'\n"
            "    AND (a.n <> b.n OR a.h IS DISTINCT FROM b.h)\n"
            ")\n"
            "SELECT * FROM step WHERE kind IN (SELECT kind FROM changed)\n"
            f"UNION ALL\nSELECT -1 AS tic, kind, {nulls} FROM changed")


def write_kinds(store, world, out, map_id, player, last):
    """Every kind's table: the other maps' rows (other players' for the
    player) and this tic's rows of the kind, in the types the tic computed.
    A table is left as it is when its rows are the ones this function wrote
    last tic and nothing else has written it since (`last`: kind -> (path,
    rows)); its slot then needs no refresh either. The other maps' rows are
    carried over from the last version without being rewritten
    (Store.write_split)."""
    writes = []
    markers = out.filter(pc.equal(out["tic"], -1))
    changed = set(markers["kind"].to_pylist())
    out = out.filter(pc.not_equal(out["tic"], -1))
    for kind, (col, table) in world.kinds.items():
        if kind not in changed:
            continue
        names = [n for n, _ in world.fields[kind] if n not in SKIP_FIELDS]
        rows = out.filter(pc.equal(out["kind"], kind)).column(col)
        rows = rows.combine_chunks() if isinstance(rows, pa.ChunkedArray) else rows
        schema = pa.schema([pa.field(n, rows.type.field(n).type) for n in names])
        new = pa.table({n: rows.field(n) for n in names}) if len(rows) else schema.empty_table()
        before = last.get(kind)
        if before is not None and before[0] == store.paths[table] and new.equals(before[1]):
            continue
        part = (map_id, player) if kind == "P" else (map_id,)

        def rest(table=table, names=names, kind=kind, schema=schema):
            old = store.arrow(table).select(names)
            if kind == "P":
                keep = pc.invert(pc.and_(pc.equal(old["map_id"], map_id),
                                         pc.equal(old["player_thing_id"], player)))
            else:
                keep = pc.not_equal(old["map_id"], map_id)
            return old.filter(keep).cast(schema)
        writes.append((kind, table, part, new, rest))
    if os.environ.get("SAILDOOM_TIC_TIMING"):
        print(f"tic writes: {len(writes)} tables, {sum(w[3].num_rows for w in writes)} rows, "
              f"{len(changed)} kinds changed: {' '.join(sorted(changed))}", flush=True)
    paths = store.write_splits([(t, part, new, rest) for _, t, part, new, rest in writes])
    for (kind, _, _, new, _), path in zip(writes, paths):
        last[kind] = (path, new)


def tic_results(store, map_id, player):
    """(sound event ids the tic used, whether the sound stage ran), from the
    _sound_attempts and tic_trace tables write_kinds has just brought up to
    date (an unchanged kind is not in the tic's result)."""
    sq = store.arrow("_sound_attempts")
    sq = sq.filter(pc.equal(sq["map_id"], map_id))
    attempts = sum(v or 0 for v in sq["attempts"].to_pylist())
    tt = store.arrow("tic_trace")
    tt = tt.filter(pc.and_(pc.equal(tt["map_id"], map_id), pc.equal(tt["player_thing_id"], player)))
    stages = tt["stages"].to_pylist()
    return attempts, bool(stages and stages[0] is not None and stages[0] & 65536)
