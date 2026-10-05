"""The automap's camera: 44_automap_view.sql's doom_automap_pan, zoom, toggle
and fit (with doom_automap_touch), which doom_sql.py runs as raw SQL."""


def register(b):
    s = b.store

    def const(name):
        return s.query(f"SELECT value FROM doom_constants WHERE name = '{name}'")[0]["value"]

    def touch(m, p):
        b.replace_rows("automap_view", "FALSE", f"""
            SELECT ps.map_id, ps.player_thing_id, ps.position_x AS center_x, ps.position_y AS center_y,
                   CAST(1.0 AS FLOAT) AS zoom, TRUE AS follow, FALSE AS grid, 0 AS cheat
            FROM player_state ps
            LEFT ANTI JOIN automap_view av ON av.map_id = ps.map_id AND av.player_thing_id = ps.player_thing_id
            WHERE ps.map_id = {m} AND ps.player_thing_id = {p}""")

    where = lambda m, p: f"t.map_id = {m} AND t.player_thing_id = {p}"

    @b.raw("SELECT doom_automap_pan(%s,%s,%s,%s)")
    def pan(m, p, dx, dy):
        touch(m, p)
        b.update("automap_view", {
            "center_x": f"CASE WHEN t.follow THEN ps.position_x ELSE t.center_x END + {float(dx)!r}D",
            "center_y": f"CASE WHEN t.follow THEN ps.position_y ELSE t.center_y END + {float(dy)!r}D",
            "follow": "FALSE"}, where(m, p) + " AND ps.map_id IS NOT NULL",
            joins=f"LEFT JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = t.player_thing_id")
        return [(1,)]

    @b.raw("SELECT doom_automap_zoom(%s,%s,%s)")
    def zoom(m, p, factor):
        touch(m, p)
        lo, hi = const("AUTOMAP_MIN_ZOOM"), const("AUTOMAP_MAX_ZOOM")
        b.update("automap_view", {"zoom": f"GREATEST({lo!r}D, LEAST({hi!r}D, t.zoom * {float(factor)!r}D))"}, where(m, p))
        return [(1,)]

    @b.raw("SELECT doom_automap_toggle(%s,%s,%s)")
    def toggle(m, p, what):
        touch(m, p)
        b.update("automap_view", {
            "follow": f"CASE WHEN '{what}' = 'follow' THEN NOT t.follow ELSE t.follow END",
            "grid": f"CASE WHEN '{what}' = 'grid' THEN NOT t.grid ELSE t.grid END",
            "cheat": f"CASE WHEN '{what}' = 'cheat' THEN (t.cheat + 1) % 3 ELSE t.cheat END"}, where(m, p))
        return [(1,)]

    @b.raw("SELECT doom_automap_fit(%s,%s)")
    def fit(m, p):
        touch(m, p)
        h, lo, hi = const("AUTOMAP_WORLD_HEIGHT"), const("AUTOMAP_MIN_ZOOM"), const("AUTOMAP_MAX_ZOOM")
        b.update("automap_view", {"center_x": "bb.cx", "center_y": "bb.cy",
                                  "zoom": f"GREATEST({lo!r}D, LEAST({hi!r}D, bb.fit))", "follow": "FALSE"},
                 where(m, p),
                 joins=f"""CROSS JOIN (
                   SELECT (MIN(LEAST(v1.x, v2.x)) + MAX(GREATEST(v1.x, v2.x))) / 2.0D AS cx,
                          (MIN(LEAST(v1.y, v2.y)) + MAX(GREATEST(v1.y, v2.y))) / 2.0D AS cy,
                          LEAST((320.0D - 96.0D) / GREATEST(1.0D, MAX(GREATEST(v1.x, v2.x)) - MIN(LEAST(v1.x, v2.x))),
                                (200.0D - 144.0D) / GREATEST(1.0D, MAX(GREATEST(v1.y, v2.y)) - MIN(LEAST(v1.y, v2.y))))
                            / (200.0D / {h!r}D) AS fit
                   FROM linedefs ld
                   JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
                   JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
                   WHERE ld.map_id = {m}) bb""")
        return [(1,)]
