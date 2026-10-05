"""A psycopg2 stand-in that runs SQLDoom's client on Sail.

doom_client.py, render_worker.py and dock.py open their own connections with
psycopg2.connect and call doom_sql.py, whose prepared statements
backend.install has already pointed at the backend. What reaches a cursor here
is the client's raw SQL: a statement saildoom/api registered, a session
setting (accepted and ignored), or a plain SELECT over the game's tables,
which runs on Sail with its parameters bound as literals.
"""

import re
import sys
import threading
import time
import types

from .backend import PG_CASTS, literal

LOG = []


class Error(Exception):
    pass


class SerializationFailure(Error):
    pass


def bind(sql, params):
    if not params:
        return sql
    parts = sql.split("%s")
    if len(parts) - 1 != len(params):
        raise Error(f"{len(params)} parameters for {len(parts) - 1} placeholders")
    out = parts[0]
    for p, rest in zip(params, parts[1:]):
        out += literal(p) + rest
    return out


def spark_sql(sql):
    for a, b in PG_CASTS:
        sql = sql.replace(a, b).replace(a.upper(), b)
    return sql


class Cursor:
    def __init__(self, conn):
        self.connection = conn
        self.rows = []
        self.description = None
        self.rowcount = -1

    def _set(self, rows):
        self.rows = [tuple(r) for r in rows]
        self.description = [("c",)] if self.rows else None
        self.rowcount = len(self.rows)

    def execute(self, sql, params=None):
        text = " ".join(sql.split())
        head = text.split(" ", 1)[0].upper()
        if head in ("SET", "DEALLOCATE", "PREPARE"):
            self._set([])
            return
        if head in ("SHOW", "EXPLAIN"):
            raise Error(f"{head} is not available on Sail")
        backend = self.connection.backend
        started = time.perf_counter()
        if text in backend.raws:
            with backend.lock:
                self._set(backend.call_raw(sql, params))
        elif head in ("SELECT", "WITH"):
            try:
                with backend.lock:
                    self._set(backend.store.query(spark_sql(bind(sql, params))))
            except Exception as exc:
                LOG.append(("failed", text[:160], str(exc)[:300]))
                raise Error(str(exc)) from exc
        else:
            LOG.append(("unported", text[:160], ""))
            raise Error("not ported to Sail: " + text[:120])
        LOG.append(("raw", text[:80], time.perf_counter() - started))

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None

    def fetchall(self):
        rows, self.rows = self.rows, []
        return rows

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Connection:
    def __init__(self, backend):
        self.backend = backend
        self.autocommit = True
        self.closed = 0

    def cursor(self):
        return Cursor(self)

    def commit(self):
        pass

    def rollback(self):
        pass

    def close(self):
        self.closed = 1


def module(backend):
    """psycopg2, psycopg2.errors and psycopg2.extensions for sys.modules."""
    pg = types.ModuleType("psycopg2")
    errors = types.ModuleType("psycopg2.errors")
    extensions = types.ModuleType("psycopg2.extensions")
    pg.Error = pg.DatabaseError = pg.OperationalError = pg.InterfaceError = Error
    pg.ProgrammingError = pg.InternalError = Error
    errors.SerializationFailure = SerializationFailure
    errors.Error = Error
    errors.__getattr__ = lambda name: Error
    pg.errors, pg.extensions = errors, extensions
    pg.connect = lambda *a, **k: Connection(backend)
    return {"psycopg2": pg, "psycopg2.errors": errors, "psycopg2.extensions": extensions}


def install_module(backend):
    if not hasattr(backend, "lock"):
        backend.lock = threading.RLock()
    sys.modules.update(module(backend))
