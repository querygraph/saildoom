"""Handlers for SQLDoom's prepared statements, by area. Each module's
register(backend) adds its handlers to backend.handlers (prepared statements
by name) and backend.raw (the few raw SQL statements doom_sql.py runs, by
their text with whitespace collapsed)."""

from . import automap, flow, game, menus, render, saves, screen_render, screens

MODULES = (menus, flow, game, screens, saves, automap, render, screen_render)


def register_all(backend):
    for module in MODULES:
        module.register(backend)
