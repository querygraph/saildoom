"""Generate sql/renderer_batch.sql from sql/renderer.sql.

The batch renderer draws many frames in one query: a `frames(frame_id, tic,
px, py, pz, angle)` table replaces the folded pose, every state table is read
at the frame's tic (`<table>.tic`, the snapshots carry it), every window and
GROUP BY is per frame, and the output is (frame_id, pix, rgb). The plan does
not grow with the number of frames, so one planning pays for all of them.

The transformation is a list of exact replacements on the single-frame SQL;
each must match exactly once (or the stated number of times), so a change to
renderer.sql that breaks one fails loudly here instead of silently.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

HEAD = """WITH cams AS (
  -- ${frames} is an inline VALUES list: the poses go through the same
  -- decimal-literal-to-double conversion as the single-frame renderer's
  -- folded literals, and as SQLDoom's client's parameters on CedarDB, which
  -- is not always the correctly rounded double (215.18106079101562 becomes
  -- 0x406ae5cb3fffffff on both engines, not ...40000000).
  SELECT frame_id, tic, px, py, pz, radians(angle) AS vr FROM ${frames}
),
frame_clock AS (
  SELECT c.frame_id, c.tic, CAST(COALESCE(MAX(ps.level_tics), 0) AS BIGINT) AS t
  FROM cams c
  LEFT JOIN player_state ps ON ps.tic = c.tic
    AND ps.map_id = ${map_id} AND ps.player_thing_id = ${player}
  GROUP BY c.frame_id, c.tic
),
animated_light AS (
  SELECT k.frame_id, k.sector_id,
    LEAST(255, GREATEST(0,
    CASE k.special
      WHEN 2  THEN CASE WHEN ((k.t + k.phase) % 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 13 THEN CASE WHEN (k.t % 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 3  THEN CASE WHEN ((k.t + k.phase) % 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 12 THEN CASE WHEN (k.t % 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 1  THEN CASE WHEN ((k.sector_id*2654435761 + (k.t DIV 4)) % 8) < 2
                        THEN k.dark_light ELSE k.base_light END
      WHEN 17 THEN GREATEST(k.dark_light,
                     k.base_light - CAST(((((((k.t DIV 3) % 1000) * (((k.t DIV 3) % 1000))
                                        * 1103515245) + k.sector_id * 40503)
                                      % 1009) % 4
                       * GREATEST(1, (k.base_light - k.dark_light) DIV 4)) AS INT))
      WHEN 8  THEN (k.dark_light + 8 * (
                      CASE WHEN ((k.t + k.phase) % (2*k.glow_steps)) < k.glow_steps
                           THEN ((k.t + k.phase) % (2*k.glow_steps))
                           ELSE 2*k.glow_steps - ((k.t + k.phase) % (2*k.glow_steps))
                      END))
      ELSE k.base_light
    END)) AS light_level
  FROM (
    SELECT fc.frame_id, f.sector_id, f.base_light, f.dark_light, f.special,
           (f.sector_id*7919) % 64 AS phase,
           GREATEST(1, (f.base_light - f.dark_light) DIV 8) AS glow_steps,
           fc.t
    FROM frame_clock fc
    JOIN sector_light_fx f ON f.tic = fc.tic AND f.map_id = ${map_id}
  ) k
),
sectors_lit AS (
  SELECT fc.frame_id, s.id, s.floor_height, s.ceil_height, s.floor_tex, s.ceil_tex,
         COALESCE(a.light_level, s.light_level) AS light_level
  FROM frame_clock fc
  JOIN sectors s ON s.tic = fc.tic AND s.map_id = ${map_id}
    AND s.tic BETWEEN ${tic_lo} AND ${tic_hi}
  LEFT JOIN animated_light a ON a.frame_id = fc.frame_id AND a.sector_id = s.id
),
weapon_runtime AS (
  SELECT rc.frame_id, COALESCE(w.sx, 1) AS sx, COALESCE(w.sy, 32) AS sy,
         CASE WHEN COALESCE(ps2.light_amp_tics, 0) > 0 THEN 16
              ELSE COALESCE(w.flash_seq_index, -1) + 1 END AS extra_light,
         COALESCE(ps2.invuln_tics, 0) > 0 AS invuln,
         wd.sprite, wd.flash_sprite,
         CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
              THEN rf.frame ELSE mf.frame END AS frame,
         CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
              THEN rf.fullbright ELSE mf.fullbright END AS fullbright,
         ff.frame AS flash_frame, ff.fullbright AS flash_fullbright
  FROM cams rc
  LEFT JOIN player_weapons w ON w.tic = rc.tic
    AND w.map_id = ${map_id} AND w.player_thing_id = ${player}
  LEFT JOIN player_state ps2 ON ps2.tic = rc.tic
    AND ps2.map_id = ${map_id} AND ps2.player_thing_id = ${player}
  JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
  LEFT JOIN weapon_frames rf ON rf.weapon_id = wd.weapon_id
    AND rf.state = 'ready' AND rf.seq_index = 0
  LEFT JOIN weapon_frames mf ON mf.weapon_id = wd.weapon_id
    AND mf.state = COALESCE(w.state, 'ready') AND mf.seq_index = COALESCE(w.seq_index, 0)
  LEFT JOIN weapon_frames ff ON ff.weapon_id = wd.weapon_id
    AND ff.state = 'flash' AND ff.seq_index = w.flash_seq_index
),
"""

BSP = """bsp_order AS (
  SELECT s.frame_id, s.tic, s.ssector_id,
         ROW_NUMBER() OVER (PARTITION BY s.frame_id ORDER BY s.sort_key) AS bsp_seq
  FROM (
    SELECT vc.frame_id, vc.tic, st.ssector_id,
           SUM(CASE WHEN st.side = (CASE
                      WHEN CAST(bround(vc.px - n.x) AS BIGINT) * CAST(n.dy AS BIGINT)
                         - CAST(bround(vc.py - n.y) AS BIGINT) * CAST(n.dx AS BIGINT) > 0
                        THEN 'R' ELSE 'L' END)
                    THEN CAST(0 AS BIGINT)
                    ELSE shiftleft(CAST(1 AS BIGINT), 40 - st.depth) END) AS sort_key,
           bool_and(vc.keep) AS visible
    FROM node_path_steps st
    JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
    JOIN visible_children vc ON vc.node_id = st.node_id AND vc.side = st.side
    WHERE st.map_id = ${map_id}
    GROUP BY vc.frame_id, vc.tic, st.ssector_id
  ) s
  WHERE s.visible
),
"""

SEG_STREAM = """seg_stream AS (
  SELECT bo.frame_id, bo.tic, c.px, c.py, c.pz, c.vr,
         s.seg_id, s.linedef_id, s.x1, s.y1, s.x2, s.y2, s.seg_u1, s.seg_u2,
         s.fsec, s.bsec, s.x_offset, s.y_offset, s.upper_tex, s.mid_tex,
         s.lower_tex, s.flags, s.f_floor, s.f_ceil, s.f_ceil_tex, s.f_light,
         s.b_floor, s.b_ceil, s.b_ceil_tex, s.b_light, s.light_bias,
         bo.bsp_seq,
         MIN(CASE WHEN bo.bsp_seq = 1
                  THEN shiftleft(CAST(s.seg_id AS BIGINT), 24) | CAST(s.fsec AS BIGINT) END)
           OVER (PARTITION BY bo.frame_id) AS ps_key,
         ROW_NUMBER() OVER (PARTITION BY bo.frame_id ORDER BY s.seg_id) AS rn
  FROM bsp_order bo
  JOIN cams c ON c.frame_id = bo.frame_id
  JOIN render_segs s ON s.tic = bo.tic AND s.ssector_id = bo.ssector_id
    AND s.map_id = ${map_id} AND s.tic BETWEEN ${tic_lo} AND ${tic_hi}
),
"""


def cte_span(sql, name):
    """[start, end) of `name AS (...),` including the trailing comma and newline."""
    start = sql.index(f"\n{name} AS (") + 1
    depth, i = 0, sql.index("(", start)
    while True:
        depth += {"(": 1, ")": -1}.get(sql[i], 0)
        i += 1
        if depth == 0:
            break
    assert sql[i:i + 2] == ",\n", sql[i:i + 20]
    return start, i + 2


def replace(sql, old, new, count=1):
    n = sql.count(old)
    if n != count:
        raise SystemExit(f"expected {count} of {old[:70]!r}, found {n}")
    return sql.replace(old, new)


def main():
    sql = (ROOT / "sql/renderer.sql").read_text()
    intro, body = sql.split("WITH frame_clock AS (", 1)
    body = "WITH frame_clock AS (" + body
    bsp_at = body.index("-- ---------------------------------------------------------------- BSP")
    body = HEAD + body[bsp_at:]
    s, e = cte_span(body, "bsp_order")
    body = body[:s] + BSP + body[e:]
    s, e = cte_span(body, "seg_stream")
    body = body[:s] + SEG_STREAM + body[e:]

    r = lambda old, new, count=1: replace(body, old, new, count)
    body = r("  SELECT nc.node_id, nc.side,\n",
             "  SELECT c.frame_id, c.tic, c.px, c.py, nc.node_id, nc.side,\n")
    body = r("  FROM node_children nc\n  WHERE nc.map_id = ${map_id}\n",
             "  FROM cams c CROSS JOIN node_children nc\n  WHERE nc.map_id = ${map_id}\n")
    body = r("  LEFT JOIN sectors_lit ps ON ps.id = CAST(r.ps_key & 16777215 AS INT)",
             "  LEFT JOIN sectors_lit ps ON ps.frame_id = r.frame_id\n"
             "    AND ps.id = CAST(r.ps_key & 16777215 AS INT)")
    body = r("  FROM frame_clock fc\n  CROSS JOIN segs_projected p\n",
             "  FROM frame_clock fc\n  JOIN segs_projected p ON p.frame_id = fc.frame_id\n")
    body = r("  LEFT JOIN animated_light alf ON alf.sector_id = p.fsec",
             "  LEFT JOIN animated_light alf ON alf.frame_id = p.frame_id AND alf.sector_id = p.fsec")
    body = r("OVER (PARTITION BY pc.col_x)", "OVER (PARTITION BY pc.frame_id, pc.col_x)")
    body = r("PARTITION BY p.col_x", "PARTITION BY p.frame_id, p.col_x", count=6)
    body = r("  SELECT b.col_x, b.ps_light, b.sp.*",
             "  SELECT b.frame_id, b.px, b.py, b.pz, b.vr, b.col_x, b.ps_light, b.sp.*")
    body = r("    SELECT k.col_x, k.ps_light, explode(",
             "    SELECT k.frame_id, k.px, k.py, k.pz, k.vr, k.col_x, k.ps_light, explode(")
    body = r("  SELECT kind, col_x, y0, y1, sector_id, plane_z, plane, span_sky, stable_id,\n",
             "  SELECT frame_id, kind, col_x, y0, y1, sector_id, plane_z, plane, span_sky, stable_id,\n"
             "         MIN(px) AS px, MIN(py) AS py, MIN(pz) AS pz, MIN(vr) AS vr,\n")
    body = r("  GROUP BY kind, col_x, y0, y1, sector_id, plane_z, plane, span_sky, stable_id",
             "  GROUP BY frame_id, kind, col_x, y0, y1, sector_id, plane_z, plane, span_sky, stable_id")
    body = r("  LEFT JOIN sectors_lit s ON d.kind = 1 AND s.id = d.sector_id",
             "  LEFT JOIN sectors_lit s ON d.kind = 1 AND s.frame_id = d.frame_id AND s.id = d.sector_id")
    body = r("  SELECT u.kind, u.col_x AS x,", "  SELECT u.frame_id, u.kind, u.col_x AS x,")

    # sprites: every source is read at the frame's tic
    body = r("  SELECT 0 AS src,", "  SELECT c.frame_id, c.tic, c.px, c.py, c.pz, c.vr, 0 AS src,")
    body = r("""  FROM render_things rt
  JOIN things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN thing_health h ON h.map_id = rt.map_id AND h.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
  LEFT JOIN monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id""",
             """  FROM cams c
  JOIN render_things rt ON rt.tic = c.tic AND rt.map_id = ${map_id}
    AND rt.tic BETWEEN ${tic_lo} AND ${tic_hi}
  JOIN things t ON t.tic = c.tic AND t.map_id = rt.map_id AND t.id = rt.thing_id
    AND t.tic BETWEEN ${tic_lo} AND ${tic_hi}
  LEFT JOIN thing_health h ON h.tic = c.tic AND h.map_id = rt.map_id AND h.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
  LEFT JOIN monster_ai ai ON ai.tic = c.tic AND ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id""")
    body = r("  LEFT JOIN picked_up_items pu ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id",
             "  LEFT JOIN picked_up_items pu ON pu.tic = c.tic AND pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id")
    body = r("  SELECT 1, -e.effect_id,", "  SELECT c.frame_id, c.tic, c.px, c.py, c.pz, c.vr, 1, -e.effect_id,")
    body = r("  FROM world_effects e\n",
             "  FROM cams c\n  JOIN world_effects e ON e.tic = c.tic AND e.map_id = ${map_id}\n")
    body = r("  SELECT 2, CAST(ot.id AS BIGINT),",
             "  SELECT c.frame_id, c.tic, c.px, c.py, c.pz, c.vr, 2, CAST(ot.id AS BIGINT),")
    body = r("""  FROM player_state op
  JOIN things ot ON ot.map_id = op.map_id AND ot.id = op.player_thing_id""",
             """  FROM cams c
  JOIN player_state op ON op.tic = c.tic AND op.map_id = ${map_id}
  JOIN things ot ON ot.tic = c.tic AND ot.map_id = op.map_id AND ot.id = op.player_thing_id""")
    body = r("  SELECT 3, -(CAST(1000000000000 AS BIGINT) + mp.projectile_id),",
             "  SELECT c.frame_id, c.tic, c.px, c.py, c.pz, c.vr, 3, -(CAST(1000000000000 AS BIGINT) + mp.projectile_id),")
    body = r("  FROM monster_projectiles mp\n",
             "  FROM cams c\n  JOIN monster_projectiles mp ON mp.tic = c.tic AND mp.map_id = ${map_id}\n")
    body = r("  LEFT JOIN sectors_lit s ON s.id = ts.sector_ref",
             "  LEFT JOIN sectors_lit s ON s.frame_id = ts.frame_id AND s.id = ts.sector_ref")
    body = r("PARTITION BY tv.thing_id", "PARTITION BY tv.frame_id, tv.thing_id")
    body = r("  SELECT 3 AS kind, c.screen_x AS x,", "  SELECT c.frame_id, 3 AS kind, c.screen_x AS x,")
    body = r("  LEFT JOIN mp_players mpl ON mpl.map_id = ${map_id} AND mpl.player_thing_id = c.thing_id",
             "  LEFT JOIN mp_players mpl ON mpl.tic = c.tic AND mpl.map_id = ${map_id}\n"
             "    AND mpl.player_thing_id = c.thing_id")

    # the weapon
    body = r("  SELECT 4 AS kind, q.x,", "  SELECT q.frame_id, 4 AS kind, q.x,")
    body = r("        SELECT x0.l0.layer AS layer,", "        SELECT x0.frame_id, x0.l0.layer AS layer,")
    body = r("          SELECT explode(array(\n            named_struct('layer', 1,",
             "          SELECT wr.frame_id, explode(array(\n            named_struct('layer', 1,")

    # resolve
    body = r("""  FROM weapon_runtime wr
  CROSS JOIN (
    SELECT * FROM view_fragments
    UNION ALL SELECT * FROM sprite_fragments
    UNION ALL SELECT * FROM psprite_fragments
  ) f""", """  FROM weapon_runtime wr
  JOIN (
    SELECT * FROM view_fragments
    UNION ALL SELECT * FROM sprite_fragments
    UNION ALL SELECT * FROM psprite_fragments
  ) f ON f.frame_id = wr.frame_id""")
    body = r("MAX(f.ps_light) OVER () AS cam_light", "MAX(f.ps_light) OVER (PARTITION BY f.frame_id) AS cam_light")
    body = r("  SELECT f.kind, f.y * ${W} + f.x AS pix,", "  SELECT f.frame_id, f.kind, f.y * ${W} + f.x AS pix,")
    body = r("resolved AS (\n  SELECT pix,", "resolved AS (\n  SELECT frame_id, pix,")
    body = r("  FROM sampled\n  GROUP BY pix", "  FROM sampled\n  GROUP BY frame_id, pix")

    # the status bar and the message line
    body = r("""  FROM player_state ps
  LEFT JOIN player_weapons w ON w.map_id = ps.map_id AND w.player_thing_id = ps.player_thing_id
  LEFT JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
  WHERE ps.map_id = ${map_id} AND ps.player_thing_id = ${player}""",
             """  FROM cams c
  JOIN player_state ps ON ps.tic = c.tic
    AND ps.map_id = ${map_id} AND ps.player_thing_id = ${player}
  LEFT JOIN player_weapons w ON w.tic = c.tic
    AND w.map_id = ps.map_id AND w.player_thing_id = ps.player_thing_id
  LEFT JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)""")
    body = r("hud AS (\n  SELECT ps.health,", "hud AS (\n  SELECT c.frame_id, c.tic, ps.health,")
    body = r("  SELECT x.n0.txt AS txt,", "  SELECT x.frame_id, x.n0.txt AS txt,")
    body = r("    SELECT explode(array(\n      named_struct('txt', CAST(h.health",
             "    SELECT h.frame_id, explode(array(\n      named_struct('txt', CAST(h.health")
    body = r("  SELECT 1 AS layer, d.font ||", "  SELECT d.frame_id, 1 AS layer, d.font ||")
    body = r("  SELECT y0.l0.layer, y0.l0.patch, y0.l0.x, y0.l0.y",
             "  SELECT y0.frame_id, y0.l0.layer, y0.l0.patch, y0.l0.x, y0.l0.y")
    body = r("    SELECT explode(array(\n      CASE WHEN h.key_blue",
             "    SELECT h.frame_id, explode(array(\n      CASE WHEN h.key_blue")
    body = r("  SELECT 2 AS layer,\n", "  SELECT c.frame_id, 2 AS layer,\n")
    body = r("""  FROM (SELECT GS(2, 7) AS weapon_id) s
  LEFT JOIN (
    SELECT DISTINCT weapon_id FROM player_weapon_owned
    WHERE map_id = ${map_id} AND player_thing_id = ${player}
  ) o ON o.weapon_id = s.weapon_id""", """  FROM cams c
  CROSS JOIN (SELECT GS(2, 7) AS weapon_id) s
  LEFT JOIN (
    SELECT DISTINCT tic, weapon_id FROM player_weapon_owned
    WHERE map_id = ${map_id} AND player_thing_id = ${player}
  ) o ON o.tic = c.tic AND o.weapon_id = s.weapon_id""")
    body = r("hud_pixels AS (\n  SELECT (l.y", "hud_pixels AS (\n  SELECT l.frame_id, (l.y")
    body = r("  GROUP BY (l.y - p.top_offset + px.dy)", "  GROUP BY l.frame_id, (l.y - p.top_offset + px.dy)")
    body = r("message_pixels AS (\n  SELECT (1 + px.dy)", "message_pixels AS (\n  SELECT mp.frame_id, (1 + px.dy)")
    body = r("    SELECT g.pos, g.patch,", "    SELECT g.frame_id, g.pos, g.patch,")
    body = r("OVER (ORDER BY g.pos ROWS", "OVER (PARTITION BY g.frame_id ORDER BY g.pos ROWS")
    body = r("      SELECT m.i AS pos,", "      SELECT m.frame_id, m.i AS pos,")
    body = r("      FROM (SELECT h.message, GS(1, length(h.message)) AS i FROM hud h",
             "      FROM (SELECT h.frame_id, h.message, GS(1, length(h.message)) AS i FROM hud h")
    body = r("  GROUP BY (1 + px.dy)", "  GROUP BY mp.frame_id, (1 + px.dy)")

    # the frame
    body = r("  SELECT r.pix,\n", "  SELECT r.frame_id, r.pix,\n")
    body = r("  LEFT JOIN message_pixels m ON m.pix = r.pix",
             "  LEFT JOIN message_pixels m ON m.frame_id = r.frame_id AND m.pix = r.pix")
    body = r("  SELECT s.y * ${W} + s.x,\n", "  SELECT h.frame_id, s.y * ${W} + s.x,\n")
    body = r("  LEFT JOIN hud_pixels o ON o.pix = s.y * ${W} + s.x",
             "  LEFT JOIN hud_pixels o ON o.frame_id = h.frame_id AND o.pix = s.y * ${W} + s.x")
    body = r("SELECT f.pix, COALESCE(cm.rgb, f.fallback) AS rgb",
             "SELECT f.frame_id, f.pix, COALESCE(cm.rgb, f.fallback) AS rgb")
    body = r("""  SELECT cm.level, cm.palette_index, cm.rgb
  FROM colormap_rgb cm
  JOIN hud h ON cm.pal = h.pal
) cm ON cm.level = f.level AND cm.palette_index = f.palette_index""",
             """  SELECT h.frame_id, cm.level, cm.palette_index, cm.rgb
  FROM hud h
  JOIN colormap_rgb cm ON cm.pal = h.pal
) cm ON cm.frame_id = f.frame_id AND cm.level = f.level AND cm.palette_index = f.palette_index""")
    body = r("ORDER BY f.pix", "ORDER BY f.frame_id, f.pix")

    header = ("-- GENERATED by scripts/make_batch_renderer.py from sql/renderer.sql; do not edit.\n"
              "-- Many frames per query: frames(frame_id, tic, px, py, pz, angle), state\n"
              "-- tables read at each frame's tic, output (frame_id, pix, rgb).\n")
    (ROOT / "sql/renderer_batch.sql").write_text(header + body)
    print("wrote sql/renderer_batch.sql")


if __name__ == "__main__":
    main()
