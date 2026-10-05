"""The automap's camera: 44_automap_view.sql's doom_automap_pan, zoom, toggle
and fit (with doom_automap_touch), which doom_sql.py runs as raw SQL."""


from decimal import ROUND_DOWN, Decimal  # noqa: E402


def register(b):
    register_render(b)
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
        e = s.query(f"""SELECT MIN(LEAST(v1.x, v2.x)) AS x0, MAX(GREATEST(v1.x, v2.x)) AS x1,
                               MIN(LEAST(v1.y, v2.y)) AS y0, MAX(GREATEST(v1.y, v2.y)) AS y1
                        FROM linedefs ld
                        JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
                        JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
                        WHERE ld.map_id = {m}""")[0]
        # CedarDB divides these numerics to 8 decimal places, truncating
        # (numeric(_,1) / numeric(_,1) at these magnitudes; probed).
        q = lambda a, d: (Decimal(a) / Decimal(d)).quantize(Decimal("1e-8"), rounding=ROUND_DOWN)
        ratio = min(q("224.0", max(1, e["x1"] - e["x0"])), q("56.0", max(1, e["y1"] - e["y0"])))
        fit = max(lo, min(hi, float(ratio) / (200.0 / h)))
        b.update("automap_view", {"center_x": repr((e["x0"] + e["x1"]) / 2.0) + "D",
                                  "center_y": repr((e["y0"] + e["y1"]) / 2.0) + "D",
                                  "zoom": repr(fit) + "D", "follow": "FALSE"}, where(m, p))
        return [(1,)]


def register_render(b):
    """client/render_automap.sql: the automap as a 320x200 RGB frame. The SQL
    resolves every pixel's palette index; the frame is packed from
    colormap_rgb (pal 0, level 0) here."""
    import numpy as np
    s = b.store

    @b.handler("doom_render_automap")
    def render(m, p):
        h = s.query("SELECT value FROM doom_constants WHERE name = 'AUTOMAP_WORLD_HEIGHT'")[0]["value"]
        rows = s.query(f"""
WITH settings AS (
  SELECT {m} AS map_id, {p} AS player_thing_id,
    CAST(CASE WHEN COALESCE(av.follow, TRUE) THEN ps.position_x ELSE av.center_x END AS DOUBLE) AS cx,
    CAST(CASE WHEN COALESCE(av.follow, TRUE) THEN ps.position_y ELSE av.center_y END AS DOUBLE) AS cy,
    (200.0D / {h!r}D) * CAST(COALESCE(av.zoom, CAST(1.0 AS FLOAT)) AS DOUBLE) AS scale,
    ps.power_map AS reveal_all, COALESCE(av.cheat, 0) > 0 AS cheat, COALESCE(av.cheat, 0) = 2 AS show_things,
    COALESCE(av.grid, FALSE) AS grid, 320 AS w, 200 AS h
  FROM player_state ps
  LEFT JOIN automap_view av ON av.map_id = ps.map_id AND av.player_thing_id = ps.player_thing_id
  WHERE ps.map_id = {m} AND ps.player_thing_id = {p}
),
drawn_lines AS (
  SELECT CAST(v1.x AS DOUBLE) AS x1, CAST(v1.y AS DOUBLE) AS y1, CAST(v2.x AS DOUBLE) AS x2, CAST(v2.y AS DOUBLE) AS y2,
    CASE WHEN ml.line_id IS NULL AND NOT s.cheat THEN 99
         WHEN ls.sector_id IS NULL OR rs.sector_id IS NULL THEN 176
         WHEN ld.special = 39 THEN 184
         WHEN (ld.flags & 32) <> 0 THEN 176
         WHEN rsec.floor_height <> lsec.floor_height THEN 64
         WHEN rsec.ceil_height <> lsec.ceil_height THEN 231
         WHEN s.cheat THEN 96 END AS palette_index
  FROM settings s
  JOIN linedefs ld ON ld.map_id = s.map_id
  JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
  JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
  LEFT JOIN sidedefs rs ON rs.map_id = ld.map_id AND rs.id = ld.right_sd_id
  LEFT JOIN sidedefs ls ON ls.map_id = ld.map_id AND ls.id = ld.left_sd_id
  LEFT JOIN sectors rsec ON rsec.map_id = ld.map_id AND rsec.id = rs.sector_id
  LEFT JOIN sectors lsec ON lsec.map_id = ld.map_id AND lsec.id = ls.sector_id
  LEFT JOIN (SELECT DISTINCT line_id FROM mapped_lines WHERE map_id = {m}) ml ON ml.line_id = ld.id
  WHERE (s.cheat OR (ld.flags & 128) = 0) AND (ml.line_id IS NOT NULL OR s.reveal_all OR s.cheat)
),
projected AS (
  SELECT c.palette_index,
    160.0D + (c.x1 - s.cx) * s.scale AS ax, 100.0D - (c.y1 - s.cy) * s.scale AS ay,
    160.0D + (c.x2 - s.cx) * s.scale AS bx, 100.0D - (c.y2 - s.cy) * s.scale AS by
  FROM drawn_lines c CROSS JOIN settings s WHERE c.palette_index IS NOT NULL
),
arrow_shape AS (
  SELECT * FROM VALUES (-0.875D, 0.0D, 1.0D, 0.0D), (1.0D, 0.0D, 0.5D, 0.25D), (1.0D, 0.0D, 0.5D, -0.25D),
    (-0.875D, 0.0D, -1.125D, 0.25D), (-0.875D, 0.0D, -1.125D, -0.25D), (-0.625D, 0.0D, -0.875D, 0.25D),
    (-0.625D, 0.0D, -0.875D, -0.25D) AS a(lx1, ly1, lx2, ly2)
),
arrow AS (
  SELECT 209 AS palette_index,
    160.0D + ((t.x + r.rr * (a.lx1 * COS(r.ang) - a.ly1 * SIN(r.ang))) - s.cx) * s.scale AS ax,
    100.0D - ((t.y + r.rr * (a.lx1 * SIN(r.ang) + a.ly1 * COS(r.ang))) - s.cy) * s.scale AS ay,
    160.0D + ((t.x + r.rr * (a.lx2 * COS(r.ang) - a.ly2 * SIN(r.ang))) - s.cx) * s.scale AS bx,
    100.0D - ((t.y + r.rr * (a.lx2 * SIN(r.ang) + a.ly2 * COS(r.ang))) - s.cy) * s.scale AS by
  FROM settings s
  JOIN things t ON t.map_id = s.map_id AND t.id = s.player_thing_id
  CROSS JOIN arrow_shape a
  CROSS JOIN (SELECT RADIANS(CAST(t2.angle AS DOUBLE)) AS ang, 18.285714D AS rr
              FROM things t2 WHERE t2.map_id = {m} AND t2.id = {p}) r
),
thing_shape AS (
  SELECT * FROM VALUES (-0.5D, -0.7D, 1.0D, 0.0D), (1.0D, 0.0D, -0.5D, 0.7D), (-0.5D, 0.7D, -0.5D, -0.7D)
    AS a(lx1, ly1, lx2, ly2)
),
mobjs AS (
  SELECT CAST(t.x AS DOUBLE) AS x, CAST(t.y AS DOUBLE) AS y, CAST(t.angle AS DOUBLE) AS angle
  FROM settings s
  JOIN render_things rt ON rt.map_id = s.map_id
  JOIN things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN game_tic_commands gc ON gc.map_id = s.map_id AND gc.player_thing_id = s.player_thing_id
  LEFT JOIN picked_up_items pu ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
  LEFT JOIN monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
  WHERE s.show_things AND (t.flags & COALESCE(gc.skill_bit, 2)) <> 0 AND (t.flags & 16) = 0
    AND pu.thing_id IS NULL
    -- NOT (EXISTS ... AND ai.state = 'dead'): an exploding thing with no AI row is NULL, so dropped.
    AND NOT (cd.thing_type IS NOT NULL AND ai.state = 'dead')
  UNION ALL
  SELECT CAST(t.x AS DOUBLE), CAST(t.y AS DOUBLE), CAST(t.angle AS DOUBLE)
  FROM settings s JOIN things t ON t.map_id = s.map_id AND t.id = s.player_thing_id
  WHERE s.show_things
),
thing_marks AS (
  SELECT 112 AS palette_index,
    160.0D + ((mm.x + 16.0D * (a.lx1 * COS(RADIANS(mm.angle)) - a.ly1 * SIN(RADIANS(mm.angle)))) - s.cx) * s.scale AS ax,
    100.0D - ((mm.y + 16.0D * (a.lx1 * SIN(RADIANS(mm.angle)) + a.ly1 * COS(RADIANS(mm.angle)))) - s.cy) * s.scale AS ay,
    160.0D + ((mm.x + 16.0D * (a.lx2 * COS(RADIANS(mm.angle)) - a.ly2 * SIN(RADIANS(mm.angle)))) - s.cx) * s.scale AS bx,
    100.0D - ((mm.y + 16.0D * (a.lx2 * SIN(RADIANS(mm.angle)) + a.ly2 * COS(RADIANS(mm.angle)))) - s.cy) * s.scale AS by
  FROM settings s CROSS JOIN mobjs mm CROSS JOIN thing_shape a
),
grid_span AS (
  SELECT s.cx - 160.0D / s.scale AS x0, s.cx + 160.0D / s.scale AS x1,
         s.cy - 100.0D / s.scale AS y0, s.cy + 100.0D / s.scale AS y1
  FROM settings s WHERE s.grid
),
grid_lines AS (
  SELECT 104 AS palette_index, 160.0D + (g.k * 128.0D - s.cx) * s.scale AS ax, 100.0D - (g.y0 - s.cy) * s.scale AS ay,
         160.0D + (g.k * 128.0D - s.cx) * s.scale AS bx, 100.0D - (g.y1 - s.cy) * s.scale AS by
  FROM settings s CROSS JOIN (SELECT v.*, GS(CAST(CEIL(v.x0 / 128.0D) AS INT), CAST(FLOOR(v.x1 / 128.0D) AS INT)) AS k FROM grid_span v) g
  UNION ALL
  SELECT 104, 160.0D + (g.x0 - s.cx) * s.scale, 100.0D - (g.k * 128.0D - s.cy) * s.scale,
         160.0D + (g.x1 - s.cx) * s.scale, 100.0D - (g.k * 128.0D - s.cy) * s.scale
  FROM settings s CROSS JOIN (SELECT v.*, GS(CAST(CEIL(v.y0 / 128.0D) AS INT), CAST(FLOOR(v.y1 / 128.0D) AS INT)) AS k FROM grid_span v) g
),
segments AS (
  SELECT palette_index, ax, ay, bx, by FROM projected
  UNION ALL SELECT palette_index, ax, ay, bx, by FROM arrow
  UNION ALL SELECT palette_index, ax, ay, bx, by FROM thing_marks
  UNION ALL SELECT palette_index, ax, ay, bx, by FROM grid_lines
),
clipped AS (
  SELECT q.* FROM (
    SELECT g.*,
      GREATEST(0.0D, GREATEST(
        CASE WHEN g.dx > 0 THEN (0.0D - g.ax) / g.dx WHEN g.dx < 0 THEN (319.0D - g.ax) / g.dx ELSE 0.0D END,
        CASE WHEN g.dy > 0 THEN (0.0D - g.ay) / g.dy WHEN g.dy < 0 THEN (199.0D - g.ay) / g.dy ELSE 0.0D END)) AS t_lo,
      LEAST(1.0D, LEAST(
        CASE WHEN g.dx > 0 THEN (319.0D - g.ax) / g.dx WHEN g.dx < 0 THEN (0.0D - g.ax) / g.dx ELSE 1.0D END,
        CASE WHEN g.dy > 0 THEN (199.0D - g.ay) / g.dy WHEN g.dy < 0 THEN (0.0D - g.ay) / g.dy ELSE 1.0D END)) AS t_hi
    FROM (SELECT sg.*, sg.bx - sg.ax AS dx, sg.by - sg.ay AS dy FROM segments sg) g
    WHERE g.dx <> 0 OR g.dy <> 0
  ) q WHERE q.t_lo <= q.t_hi
),
line_pixels AS (
  SELECT c.palette_index,
    CAST(ROUND(c.ax + c.dx * (c.t_lo + (c.t_hi - c.t_lo) * c.i / c.steps)) AS INT) AS x,
    CAST(ROUND(c.ay + c.dy * (c.t_lo + (c.t_hi - c.t_lo) * c.i / c.steps)) AS INT) AS y
  FROM (
    SELECT n.*, GS(0, CAST(n.steps AS INT)) AS i FROM (
      SELECT c0.*, GREATEST(1.0D, CEIL(GREATEST(ABS(c0.dx * (c0.t_hi - c0.t_lo)), ABS(c0.dy * (c0.t_hi - c0.t_lo))))) AS steps
      FROM clipped c0) n
  ) c
),
resolved AS (
  SELECT x, y, max_by(palette_index,
           (CASE palette_index WHEN 112 THEN 10 WHEN 209 THEN 9 WHEN 99 THEN 0 WHEN 104 THEN -1 ELSE 1 END) * 256
           + palette_index) AS palette_index
  FROM line_pixels WHERE x BETWEEN 0 AND 319 AND y BETWEEN 0 AND 199
  GROUP BY x, y
)
SELECT r.x, r.y, cm.r, cm.g, cm.b FROM resolved r
LEFT JOIN colormap_rgb cm ON cm.pal = 0 AND cm.level = 0 AND cm.palette_index = r.palette_index""")
        frame = np.zeros((200, 320, 3), np.uint8)
        for r in rows:
            if r["r"] is not None:
                frame[r["y"], r["x"]] = (r["r"], r["g"], r["b"])
        return [(frame.tobytes(),)]
