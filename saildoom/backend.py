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

import json
import shutil
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from .sqlmacro import expand, strip_comments

ROOT = Path(__file__).resolve().parents[1]


class Store:
    """The current version of every table, as Parquet on local disk."""

    def __init__(self, spark, root, initial):
        self.spark = spark
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
        (self.root / "manifest.json").write_text(json.dumps(self.paths, indent=0))

    def _register(self, name):
        self.spark.read.parquet(self.paths[name]).createOrReplaceTempView(name)

    def tables(self):
        return sorted(self.paths)

    def path(self, name):
        return self.paths[name]

    def write(self, name, sql, params=None):
        """The next version of `name` is the result of `sql`."""
        versions = self.root / name
        n = len(list(versions.glob("v*"))) if versions.exists() else 0
        path = versions / f"v{n:06d}"
        query = expand(strip_comments(sql), params or {})
        self.spark.sql(query).write.parquet(str(path))
        self.paths[name] = str(path)
        self._register(name)
        self._save()

    def write_arrow(self, name, table):
        versions = self.root / name
        versions.mkdir(parents=True, exist_ok=True)
        n = len(list(versions.glob("v*")))
        path = versions / f"v{n:06d}.parquet"
        pq.write_table(table, path)
        self.paths[name] = str(path)
        self._register(name)
        self._save()

    def arrow_schema(self, name):
        p = Path(self.paths[name])
        return pq.read_schema(p) if p.is_file() else pq.ParquetDataset(str(p)).schema

    def arrow(self, name):
        p = Path(self.paths[name])
        return pq.read_table(p) if p.is_file() else pq.read_table(str(p))

    def query(self, sql, params=None):
        return self.spark.sql(expand(strip_comments(sql), params or {})).collect()


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

    def sequence(self, table):
        """The last value of a table's serial column (CedarDB's sequence)."""
        seqs = self.store.root / "sequences.json"
        values = json.loads(seqs.read_text()) if seqs.exists() else {}
        if table not in values:
            initial = Path(self.store.paths.get("_sequences", ""))
            if initial.exists():
                rows = {r["name"]: r["last_value"] for r in pq.read_table(initial).to_pylist()}
                values[table] = rows.get(f"{table}_event_id_seq", 0)
            else:
                m = self.store.query(f"SELECT MAX(event_id) AS m FROM {table}")[0]["m"]
                values[table] = int(m or 0)
            seqs.write_text(json.dumps(values))
        return values[table]

    def set_sequence(self, table, value):
        seqs = self.store.root / "sequences.json"
        values = json.loads(seqs.read_text()) if seqs.exists() else {}
        values[table] = int(value)
        seqs.write_text(json.dumps(values))

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
        rows = fn(*params)
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
        cur.rows = [tuple(r) for r in backend.call(name, tuple(params))]

    doom_sql.prepare_statement = prepare_statement
    doom_sql.execute_prepared = execute_prepared
    doom_sql._reprepare = lambda cur, name, parameter_types, statement: None
    return Cursor(backend)


PG_CASTS = (("::double precision", "::DOUBLE"), ("::float8", "::DOUBLE"), ("::real", "::FLOAT"),
            ("::float4", "::FLOAT"), ("::text", "::STRING"), ("::smallint", "::INT"),
            ("::bigint", "::BIGINT"), ("::int", "::INT"), ("::boolean", "::BOOLEAN"))


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
