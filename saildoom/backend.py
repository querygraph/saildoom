"""SQLDoom's database API on Sail.

SQLDoom's Python side (doom_sql.py, and the client, server and dock on top of
it) talks to its database only through prepared statements: `prepare_statement`
names one, `execute_prepared` runs it, the cursor hands back rows. This module
keeps every SQLDoom table on Sail and answers those statements there, so the
unchanged doom_sql.py runs on Sail once `install()` has replaced its two entry
points.

Sail has no `UPDATE`: a table here is a series of Parquet versions under the
store's directory, and a statement that changes a table writes its next
version with Spark SQL that reads the current one. Each table is registered
as a temp view of its current version under its own name, so the SQL reads
like SQLDoom's.

The handlers live in saildoom/api/: one module per area of SQLDoom (menus,
the level flow, the game tic, saves, demos, the automap, sound, deathmatch).
"""

import contextlib
import json
import os
import re
import shutil
import time
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from .sqlmacro import expand, strip_comments

ROOT = Path(__file__).resolve().parents[1]


class Store:
    """The current version of every table, as Parquet on local disk."""

    def __init__(self, spark, root, initial):
        self.spark = spark
        self.dirty = set()
        self.counters = {}
        self.pending = {}  # version directory -> futures of its background writes
        self.splits = {}  # name -> (path, part, rest file, rest rows) of a write_split version
        self.batching = self.unsaved = False
        self.held = {}  # name -> (path, table) for tables written from Arrow
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        manifest = self.root / "manifest.json"
        if manifest.exists():
            self.paths = json.loads(manifest.read_text())
        else:
            self.paths = {p.stem: str(p) for p in sorted(Path(initial).glob("*.parquet"))}
            self._save()
        for name in self.paths:
            self._register(name)

    def _save(self):
        if self.batching:
            self.unsaved = True
            return
        (self.root / "manifest.json").write_text(json.dumps(self.paths, indent=0))

    @contextlib.contextmanager
    def batch(self):
        """Write the manifest once, at the end of a statement that writes many tables."""
        self.batching, self.unsaved = True, False
        try:
            yield
        finally:
            self.batching = False
            if self.unsaved:
                self._save()

    def _register(self, name):
        self.wait(self.paths[name])
        self.spark.read.parquet(self.paths[name]).createOrReplaceTempView(name)
        self.dirty.discard(name)

    def _flush(self, sql):
        """Register the written tables that `sql` names. A write only marks
        its table: a tic writes dozens, and most are not read before the next."""
        for name in [n for n in self.dirty if re.search(rf"\b{re.escape(n)}\b", sql)]:
            self._register(name)

    def tables(self):
        return sorted(self.paths)

    def path(self, name):
        return self.paths[name]

    def write(self, name, sql, params=None):
        """The next version of `name` is the result of `sql`."""
        path = self._next_version(name)
        query = expand(strip_comments(sql), params or {})
        self._flush(query)
        df = self.spark.sql(query)
        df.write.parquet(str(path))
        if not path.exists():
            # Sail writes no files for an empty result; keep the schema.
            path.mkdir(parents=True)
            pq.write_table(df.limit(0).toArrow(), path / "part-0.parquet")
        self.paths[name] = str(path)
        self._register(name)
        self._save()

    def write_arrow(self, name, table):
        path = self._next_version(name, ".parquet")
        pq.write_table(table, path)
        self.paths[name] = str(path)
        self.held[name] = (str(path), table)
        self.dirty.add(name)
        self._save()

    def _next_version(self, name, suffix=""):
        """The path of `name`'s next version. Counted once per table, then in
        memory: a directory listing per write grows with every tic."""
        versions = self.root / name
        if name not in self.counters:
            versions.mkdir(parents=True, exist_ok=True)
            self.counters[name] = len(list(versions.glob("v*")))
        n = self.counters[name]
        self.counters[name] = n + 1
        return versions / f"v{n:06d}{suffix}"

    def write_splits(self, writes):
        """New versions of tables that one map's rows (`part`, a key such as
        (map_id,)) replace: each version is a directory of rest.parquet, the
        other rows, and part.parquet. When the table's current version was
        written this way for the same part, its rest.parquet is linked into
        the new version rather than rewritten -- render_segs holds 141,000
        rows across the WAD's maps and 2,057 of one. `writes` is
        [(name, part, rows, rest)], `rest` a function returning the other
        rows when they must be written. Returns the new paths."""
        from concurrent.futures import ThreadPoolExecutor
        if not hasattr(self, "pool"):
            self.pool = ThreadPoolExecutor(max_workers=8)
        jobs = []
        for name, part, rows, rest in writes:
            path = self._next_version(name)
            path.mkdir(parents=True)
            split = self.splits.get(name)
            if split is not None and split[0] == self.paths[name] and split[1] == part:
                rest_file, rest_rows = split[2], split[3]
                os.link(rest_file, path / "rest.parquet")
            else:
                rest_rows = rest()
                jobs.append((rest_rows, path / "rest.parquet"))
            jobs.append((rows, path / "part.parquet"))
            self.splits[name] = (str(path), part, str(path / "rest.parquet"), rest_rows)
            self.paths[name] = str(path)
            self.held[name] = (str(path), pa.concat_tables([rest_rows, rows]))
            self.dirty.add(name)
        # The files are written in the background: readers in this process use
        # the held tables, and a Sail read of a path waits for it (wait()).
        for rows, file in jobs:
            self.pending.setdefault(str(file.parent), []).append(self.pool.submit(pq.write_table, rows, file))
        self._save()
        return [self.paths[name] for name, *_ in writes]

    def wait(self, path=None):
        """Until the files of `path` (every pending path if None) are written."""
        keys = list(self.pending) if path is None else [str(path)]
        for key in keys:
            for future in self.pending.pop(key, []):
                future.result()

    def write_arrows(self, tables):
        """write_arrow for several tables at once, the files written in
        parallel; returns their new paths."""
        from concurrent.futures import ThreadPoolExecutor
        targets = []
        for name, table in tables:
            targets.append((name, table, self._next_version(name, ".parquet")))
        if not hasattr(self, "pool"):
            self.pool = ThreadPoolExecutor(max_workers=8)
        list(self.pool.map(lambda t: pq.write_table(t[1], t[2]), targets))
        for name, table, path in targets:
            self.paths[name] = str(path)
            self.held[name] = (str(path), table)
            self.dirty.add(name)
        self._save()
        return [str(path) for _, _, path in targets]

    def arrow_schema(self, name):
        p = Path(self.paths[name])
        return pq.read_schema(p) if p.is_file() else pq.ParquetDataset(str(p)).schema

    def arrow(self, name):
        held = self.held.get(name)
        if held is not None and held[0] == self.paths[name]:
            return held[1]
        p = Path(self.paths[name])
        table = pq.read_table(p) if p.is_file() else pq.read_table(str(p))
        self.held[name] = (self.paths[name], table)
        return table

    def query(self, sql, params=None):
        query = expand(strip_comments(sql), params or {})
        self._flush(query)
        return self.spark.sql(query).collect()


class Backend:
    """Prepared statements by name, answered on Sail."""

    def __init__(self, spark, store):
        self.spark = spark
        self.store = store
        self.handlers = {}
        self.raws = {}
        from .api import register_all
        register_all(self)

    def handler(self, name):
        def wrap(fn):
            self.handlers[name] = fn
            return fn
        return wrap

    def raw(self, text):
        def wrap(fn):
            self.raws[" ".join(text.split())] = fn
            return fn
        return wrap

    def call_raw(self, text, params):
        fn = self.raws.get(" ".join(text.split()))
        if fn is None:
            raise NotImplementedError("raw SQL is not ported to Sail: " + " ".join(text.split())[:100])
        return fn(*(params or ()))

    def update(self, table, sets, where="TRUE", joins=""):
        """UPDATE table t SET ... WHERE ...: the table's next version. Every
        expression may read the table's row as `t` and anything `joins`
        brings in; each column keeps its type."""
        schema = self.store.arrow_schema(table)
        cols = []
        for f in schema:
            if f.name in sets:
                expr = f"CASE WHEN ({where}) THEN ({sets[f.name]}) ELSE t.{f.name} END"
                cols.append(f"CAST({expr} AS {sql_type(f.type)}) AS {f.name}")
            else:
                cols.append(f"t.{f.name}")
        self.store.write(table, f"SELECT {', '.join(cols)} FROM {table} t {joins}")

    def _sequences(self):
        if getattr(self, "seq_values", None) is None:
            seqs = self.store.root / "sequences.json"
            self.seq_values = json.loads(seqs.read_text()) if seqs.exists() else {}
        return self.seq_values

    def sequence(self, table):
        """The last value of a table's serial column (CedarDB's sequence)."""
        values = self._sequences()
        if table not in values:
            initial = self.store.paths.get("_sequences")
            if initial:
                rows = {r["name"]: r["last_value"] for r in pq.read_table(initial).to_pylist()}
                values[table] = rows.get(f"{table}_event_id_seq", 0)
            else:
                m = self.store.query(f"SELECT MAX(event_id) AS m FROM {table}")[0]["m"]
                values[table] = int(m or 0)
            (self.store.root / "sequences.json").write_text(json.dumps(values))
        return values[table]

    def set_sequence(self, table, value):
        values = self._sequences()
        values[table] = int(value)
        (self.store.root / "sequences.json").write_text(json.dumps(values))

    def replace_rows(self, table, where, rows_sql):
        """DELETE FROM table WHERE where; INSERT the rows of rows_sql -- an
        upsert, as one new version. rows_sql yields the table's columns."""
        schema = self.store.arrow_schema(table)
        cols = ", ".join(f.name for f in schema)
        casts = ", ".join(f"CAST(n.{f.name} AS {sql_type(f.type)}) AS {f.name}" for f in schema)
        self.store.write(table, f"""SELECT {cols} FROM {table} WHERE NOT ({where})
                                    UNION ALL SELECT {casts} FROM ({rows_sql}) n""")

    def call(self, name, params):
        fn = self.handlers.get(name)
        if fn is None:
            raise NotImplementedError(f"statement {name} is not ported to Sail")
        t0 = time.perf_counter()
        with self.store.batch():
            rows = fn(*params)
            t1 = time.perf_counter()
        if os.environ.get("SAILDOOM_TIC_TIMING") and name == "doom_game_tic":
            print(f"call: handler {t1 - t0:.4f}s, after {time.perf_counter() - t1:.4f}s", flush=True)
        return [] if rows is None else rows


class Cursor:
    """Enough of a DB-API cursor for doom_sql.py's use of one."""

    def __init__(self, backend):
        self.backend = backend
        self.rows = []
        self.description = None

    def execute(self, sql, params=None):
        self.rows = [tuple(r) for r in self.backend.call_raw(sql, params)]

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None

    def fetchall(self):
        rows, self.rows = self.rows, []
        return rows

    def close(self):
        pass


def install(doom_sql, backend):
    """Point doom_sql.py's statement entry points at the backend."""
    def prepare_statement(cur, name, parameter_types, statement):
        return None

    def execute_prepared(cur, name, params=()):
        if name == "doom_render_frame_folded":
            # Prepared for one (map, player, skill) on this connection.
            params = doom_sql._RENDER_FOLDED[id(cur.connection)] + tuple(params)
        lock = getattr(backend, "lock", None)
        if name.startswith("doom_render_frame") or lock is None:
            rows = backend.call(name, tuple(params))
        else:
            with lock:
                rows = backend.call(name, tuple(params))
        cur.rows = [tuple(r) for r in rows]
        cur.description = [("c",)] if cur.rows else None

    doom_sql.prepare_statement = prepare_statement
    doom_sql.execute_prepared = execute_prepared
    doom_sql._reprepare = lambda cur, name, parameter_types, statement: None
    return Cursor(backend)


PG_CASTS = (("::double precision", "::DOUBLE"), ("::float8", "::DOUBLE"), ("::real", "::FLOAT"),
            ("::float4", "::FLOAT"), ("::text", "::STRING"), ("::smallint", "::INT"),
            ("::bigint", "::BIGINT"), ("::int", "::INT"), ("::boolean", "::BOOLEAN"))


def cedar_real(v):
    """The real CedarDB stores for a Python float sent as a parameter.
    psycopg2 sends repr(v) as a numeric literal. Written with an exponent it
    is a double, rounded to the nearest float; written plainly CedarDB turns
    its digits into a float and divides by a float power of ten, which is a
    different float a third of the time (probed against 2,000 values)."""
    import numpy as np
    from decimal import Decimal
    v = float(v)
    if v == 0:
        return 0.0
    text = repr(v)
    if "e" in text or "E" in text or "inf" in text or "nan" in text:
        return float(np.float32(v))
    sign, digits, exp = Decimal(text).as_tuple()
    m = int("".join(map(str, digits))) * (-1 if sign else 1)
    f = np.float32(m) / np.float32(10.0 ** -exp) if exp < 0 else np.float32(m) * np.float32(10.0 ** exp)
    return float(f)


def real_literal(v):
    import numpy as np
    return f"CAST('{np.float32(cedar_real(v))}' AS FLOAT)"


def literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return f"CAST('{v!r}' AS DOUBLE)"
    return "'" + str(v).replace("'", "''") + "'"


def pg(sql, params=()):
    """A client query file in Spark SQL: $n parameters folded in as literals,
    Postgres casts spelled the Spark way."""
    for i in range(len(params), 0, -1):
        sql = sql.replace(f"${i}", literal(params[i - 1]))
    for a, b in PG_CASTS:
        sql = sql.replace(a, b).replace(a.upper(), b)
    return sql


def sql_type(t):
    if pa.types.is_int8(t) or pa.types.is_int16(t) or pa.types.is_int32(t):
        return "INT"
    if pa.types.is_int64(t):
        return "BIGINT"
    if pa.types.is_float32(t):
        return "FLOAT"
    if pa.types.is_float64(t):
        return "DOUBLE"
    if pa.types.is_boolean(t):
        return "BOOLEAN"
    if pa.types.is_string(t) or pa.types.is_large_string(t):
        return "STRING"
    if pa.types.is_binary(t):
        return "BINARY"
    if pa.types.is_timestamp(t):
        return "TIMESTAMP"
    raise TypeError(t)


def fresh_store(spark, root, initial):
    shutil.rmtree(root, ignore_errors=True)
    return Store(spark, root, initial)


def arrow_rows(table: pa.Table):
    return [tuple(r.values()) for r in table.to_pylist()]
