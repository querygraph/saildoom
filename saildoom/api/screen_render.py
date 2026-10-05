"""client/render_screen.sql: the title, menu, load/save, intermission and
finale screens as a 320x200 RGB frame. The SQL resolves each pixel's palette
index (Postgres integer division is DIV here; the correlated width lookups
are joins); the frame is packed from colormap_rgb (pal 0, level 0) here."""

import numpy as np

SQL = """
WITH
state AS (SELECT * FROM screen_state WHERE id = 0),
background AS (
  SELECT 0 AS layer,
    CASE s.screen
      WHEN 'title' THEN 'TITLEPIC'
      WHEN 'help1' THEN 'HELP1'
      WHEN 'help2' THEN 'CREDIT'
      WHEN 'intermission' THEN
        CASE s.inter_episode WHEN 1 THEN 'WIMAP0' WHEN 2 THEN 'WIMAP1'
                             WHEN 3 THEN 'WIMAP2' ELSE 'INTERPIC' END
      WHEN 'finale' THEN f.patch
      ELSE 'TITLEPIC'
    END AS patch,
    0 AS x, 0 AS y
  FROM state s LEFT JOIN finale_defs f ON f.episode = s.finale_episode
  WHERE (s.screen <> 'finale' OR s.finale_stage <> 0)
    AND NOT (s.screen = 'finale' AND s.finale_episode = 3)
),
bunny AS (
  SELECT s.finale_count AS c,
         LEAST(320, GREATEST(0, 320 - (s.finale_count - 230) DIV 2)) AS scrolled
  FROM state s
  WHERE s.screen = 'finale' AND s.finale_stage <> 0 AND s.finale_episode = 3
),
bunny_layers AS (
  SELECT 0 AS layer, 'PFUB1' AS patch, -b.scrolled AS x, 0 AS y FROM bunny b WHERE b.scrolled < 320
  UNION ALL
  SELECT 0, 'PFUB2', 320 - b.scrolled, 0 FROM bunny b WHERE b.scrolled > 0
  UNION ALL
  SELECT 1, concat('END', CAST(LEAST(6, GREATEST(0, (b.c - 1180) DIV 5)) AS STRING)), 108, 68
  FROM bunny b WHERE b.c >= 1130
),
finale_flat AS (
  -- get_byte(palette_indices, row * 64 + col): the flat's texels by offset.
  SELECT g.x, g.y, ft.palette_index
  FROM (
    SELECT q.*, GS(0, 199) AS y FROM (
      SELECT fl.flat_id, GS(0, 319) AS x
      FROM state s
      JOIN finale_defs f ON f.episode = s.finale_episode
      JOIN flat_textures fl ON fl.name = f.flat
      WHERE s.screen = 'finale' AND s.finale_stage = 0) q) g
  JOIN flat_texels ft ON ft.flat_id = g.flat_id AND ft.off = (g.y % 64) * 64 + (g.x % 64)
),
finale_text AS (
  SELECT t.finale_count, t.i, substring(t.story_text, t.i, 1) AS ch FROM (
    SELECT s.finale_count, f.story_text, GS(1, length(f.story_text)) AS i
    FROM state s JOIN finale_defs f ON f.episode = s.finale_episode
    WHERE s.screen = 'finale' AND s.finale_stage = 0) t
),
finale_metrics AS (
  SELECT t.*,
         COALESCE(SUM(CASE WHEN t.ch = chr(10) THEN 1 ELSE 0 END) OVER (
           ORDER BY t.i ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS line_no,
         CASE WHEN t.ch = chr(10) THEN 0 WHEN t.ch = ' ' THEN 4 ELSE COALESCE(p.width, 4) END AS w
  FROM finale_text t
  LEFT JOIN ui_patches p ON p.name = concat('STCFN', lpad(CAST(ascii(upper(t.ch)) AS STRING), 3, '0'))
),
finale_placed AS (
  SELECT m.*,
         10 + COALESCE(SUM(m.w) OVER (PARTITION BY m.line_no ORDER BY m.i
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS x,
         10 + 11 * m.line_no AS y
  FROM finale_metrics m
),
finale_layers AS (
  SELECT 1 AS layer, concat('STCFN', lpad(CAST(ascii(upper(p.ch)) AS STRING), 3, '0')) AS patch, p.x, p.y
  FROM finale_placed p
  WHERE p.i <= GREATEST(0, (p.finale_count - 10) DIV 3)
    AND p.ch <> chr(10) AND p.ch <> ' ' AND p.x + p.w <= 320
),
decor AS (
  SELECT 1 AS layer, d.patch, d.x, d.y FROM state s JOIN menu_decor d ON d.screen = s.screen
),
items AS (
  SELECT 1 AS layer, m.patch, m.x, m.y FROM state s JOIN menu_items m ON m.screen = s.screen
  WHERE m.patch IS NOT NULL
),
cursor_layer AS (
  SELECT 2 AS layer,
    CASE WHEN ({tics} DIV 8) % 2 = 0 THEN 'M_SKULL1' ELSE 'M_SKULL2' END AS patch,
    m.x - 32 AS x, m.y - 5 AS y
  FROM state s JOIN menu_items m ON m.screen = s.screen AND m.idx = s.cursor_index
),
inter_state AS (SELECT * FROM state WHERE screen = 'intermission'),
metrics AS (
  SELECT
    (SELECT max(height) FROM ui_patches WHERE name = 'WINUM0') AS num_h,
    (SELECT max(width) FROM ui_patches WHERE name = 'WINUM0') AS num_w,
    (SELECT max(width) FROM ui_patches WHERE name = 'WIPCNT') AS pct_w
),
level_name AS (
  SELECT s.*, concat('WILV', CAST(s.inter_episode - 1 AS STRING), CAST(s.inter_level - 1 AS STRING)) AS patch
  FROM inter_state s
),
inter_headings AS (
  SELECT 1 AS layer, ln.patch, (320 - p.width) DIV 2 AS x, 2 AS y
  FROM level_name ln JOIN ui_patches p ON p.name = ln.patch
  UNION ALL
  SELECT 1, 'WIF', (320 - f.width) DIV 2, 2 + (5 * p.height) DIV 4
  FROM level_name ln JOIN ui_patches p ON p.name = ln.patch
  CROSS JOIN ui_patches f WHERE f.name = 'WIF'
),
inter_labels AS (
  SELECT 1 AS layer, 'WIOSTK' AS patch, 50 AS x, 50 AS y FROM inter_state
  UNION ALL SELECT 1, 'WIOSTI', 50, 50 + (3 * m.num_h) DIV 2 FROM inter_state, metrics m
  UNION ALL SELECT 1, 'WISCRT2', 50, 50 + 2 * ((3 * m.num_h) DIV 2) FROM inter_state, metrics m
  UNION ALL SELECT 1, 'WITIME', 16, 168 FROM inter_state
  UNION ALL SELECT 1, 'WIPAR', 176, 168 FROM inter_state
  UNION ALL SELECT 1, 'WIPCNT', 270, 50 FROM inter_state
  UNION ALL SELECT 1, 'WIPCNT', 270, 50 + (3 * m.num_h) DIV 2 FROM inter_state, metrics m
  UNION ALL SELECT 1, 'WIPCNT', 270, 50 + 2 * ((3 * m.num_h) DIV 2) FROM inter_state, metrics m
),
inter_runs AS (
  SELECT CAST(COALESCE(s.kills_pct, 0) AS STRING) AS txt, 270 AS right_x, 50 AS y FROM inter_state s
  UNION ALL
  SELECT CAST(COALESCE(s.items_pct, 0) AS STRING), 270, 50 + (3 * m.num_h) DIV 2 FROM inter_state s, metrics m
  UNION ALL
  SELECT CAST(COALESCE(s.secrets_pct, 0) AS STRING), 270, 50 + 2 * ((3 * m.num_h) DIV 2) FROM inter_state s, metrics m
  UNION ALL
  SELECT concat(CAST(COALESCE(s.time_secs, 0) DIV 60 AS STRING), ':',
                lpad(CAST(COALESCE(s.time_secs, 0) % 60 AS STRING), 2, '0')), 144, 168 FROM inter_state s
  UNION ALL
  SELECT concat(CAST(COALESCE(s.par_secs, 0) DIV 60 AS STRING), ':',
                lpad(CAST(COALESCE(s.par_secs, 0) % 60 AS STRING), 2, '0')), 304, 168 FROM inter_state s
),
run_chars AS (
  SELECT r.txt, r.right_x, r.y, r.i, substring(r.txt, r.i, 1) AS ch
  FROM (SELECT r0.*, GS(1, length(r0.txt)) AS i FROM inter_runs r0) r
),
run_glyphs AS (
  SELECT rc.*, CASE rc.ch WHEN ':' THEN 'WICOLON' WHEN '-' THEN 'WIMINUS' ELSE concat('WINUM', rc.ch) END AS patch
  FROM run_chars rc
),
run_placed AS (
  SELECT g.patch, g.y,
         g.right_x - SUM(p.width) OVER (PARTITION BY g.txt, g.right_x, g.y
           ORDER BY g.i DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS x
  FROM run_glyphs g JOIN ui_patches p ON p.name = g.patch
),
inter_layers AS (
  SELECT layer, patch, x, y FROM inter_headings
  UNION ALL SELECT layer, patch, x, y FROM inter_labels
  UNION ALL SELECT 1, patch, x, y FROM run_placed
),
slot_rows AS (
  SELECT m.idx, m.x, m.y FROM state s JOIN menu_items m ON m.screen = s.screen
  WHERE s.screen IN ('load', 'save')
),
slot_border AS (
  SELECT 1 AS layer, 'M_LSLEFT' AS patch, r.x - 8 AS x, r.y + 7 AS y FROM slot_rows r
  UNION ALL
  SELECT 1, 'M_LSCNTR', r.x + 8 * r.n, r.y + 7 FROM (SELECT r0.*, GS(0, 23) AS n FROM slot_rows r0) r
  UNION ALL
  SELECT 1, 'M_LSRGHT', r.x + 8 * 24, r.y + 7 FROM slot_rows r
),
text_runs AS (
  SELECT upper(COALESCE(ss.name, '')) AS txt, r.x, r.y
  FROM slot_rows r LEFT JOIN save_slots ss ON ss.slot = r.idx
),
text_chars AS (
  SELECT t.txt, t.x, t.y, t.i, substring(t.txt, t.i, 1) AS ch
  FROM (SELECT t0.*, GS(1, GREATEST(1, length(t0.txt))) AS i FROM text_runs t0 WHERE length(t0.txt) > 0) t
),
text_glyphs AS (
  SELECT tc.*,
         CASE WHEN tc.ch = ' ' THEN NULL ELSE concat('STCFN', lpad(CAST(ascii(tc.ch) AS STRING), 3, '0')) END AS patch,
         CASE WHEN tc.ch = ' ' THEN 4 ELSE COALESCE(p.width, 4) END AS w
  FROM text_chars tc
  LEFT JOIN ui_patches p ON p.name = concat('STCFN', lpad(CAST(ascii(tc.ch) AS STRING), 3, '0'))
),
text_placed AS (
  SELECT g.patch, g.y,
         g.x + COALESCE(SUM(g.w) OVER (PARTITION BY g.txt, g.x, g.y ORDER BY g.i
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS x
  FROM text_glyphs g
),
saveload_layers AS (
  SELECT layer, patch, x, y FROM slot_border
  UNION ALL SELECT 2, patch, x, y FROM text_placed WHERE patch IS NOT NULL
),
layers AS (
  SELECT layer, patch, x, y FROM background
  UNION ALL SELECT layer, patch, x, y FROM decor
  UNION ALL SELECT layer, patch, x, y FROM items
  UNION ALL SELECT layer, patch, x, y FROM cursor_layer
  UNION ALL SELECT layer, patch, x, y FROM inter_layers
  UNION ALL SELECT layer, patch, x, y FROM saveload_layers
  UNION ALL SELECT layer, patch, x, y FROM finale_layers
  UNION ALL SELECT layer, patch, x, y FROM bunny_layers
),
layer_patches AS (
  SELECT l.layer, l.patch, l.x - p.left_offset AS dest_x, l.y - p.top_offset AS dest_y
  FROM layers l JOIN ui_patches p ON p.name = l.patch
),
pixels AS (
  SELECT lp.layer, lp.dest_x + px.dx AS x, lp.dest_y + px.dy AS y, px.palette_index
  FROM layer_patches lp JOIN ui_patch_pixels px ON px.name = lp.patch
  WHERE lp.dest_x + px.dx BETWEEN 0 AND 319 AND lp.dest_y + px.dy BETWEEN 0 AND 199
  UNION ALL
  SELECT 0 AS layer, x, y, palette_index FROM finale_flat
),
resolved AS (
  SELECT x, y, max_by(palette_index, layer) AS palette_index FROM pixels GROUP BY x, y
)
SELECT r.x, r.y, cm.r, cm.g, cm.b FROM resolved r
LEFT JOIN colormap_rgb cm ON cm.pal = 0 AND cm.level = 0 AND cm.palette_index = r.palette_index
"""


def register(b):
    @b.handler("doom_render_screen")
    def render_screen(tics):
        rows = b.store.query(SQL.replace("{tics}", str(int(tics))))
        frame = np.zeros((200, 320, 3), np.uint8)
        for r in rows:
            if r["r"] is not None:
                frame[r["y"], r["x"]] = (r["r"], r["g"], r["b"])
        return [(frame.tobytes(),)]
