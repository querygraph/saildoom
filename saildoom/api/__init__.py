"""Handlers for SQLDoom's prepared statements, by area. Each module's
register(backend) adds its handlers to backend.handlers (prepared statements
by name) and backend.raw (the few raw SQL statements doom_sql.py runs, by
their text with whitespace collapsed)."""

from . import menus

MODULES = (menus,)


def register_all(backend):
    for module in MODULES:
        module.register(backend)
