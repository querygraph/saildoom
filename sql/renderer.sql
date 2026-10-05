-- SQLDoom's renderer (sql/renderer.sql in cedardb/sqldoom), in Spark SQL for Sail.
--
-- The CTE names, order and arithmetic are the original's, so any stage can be
-- compared row for row against CedarDB (reference/cte_diff.py). What changed,
-- and why:
--
--  * Parameters are folded in as literals by saildoom/render.py: ${map_id},
--    ${player}, ${skill}, ${x}, ${y}, ${z}, ${angle}.
--  * Postgres divides two integers as integers, Spark always in floating
--    point: integer divisions are written DIV.
--  * Postgres rounds half to even when it casts a float to an integer, Spark
--    truncates: such casts are PGINT(x) (bround, then cast). FLOOR/CEIL
--    results are integral already and are cast directly.
--  * generate_series(a, b) is GS(a, b): explode(sequence(a, b)), empty when
--    a > b (Spark's sequence would count down instead).
--  * GET_BYTE on a texture blob is a join on a texel table:
--    walltex_texels(tex_id, off), flat_texels(flat_id, off) and
--    sprite_texels(lump_id, off), the last holding opaque texels only, so the
--    join is also the mask test.
--  * LATERAL ... ORDER BY ... LIMIT 1 becomes a window MAX and an equi-join;
--    EXISTS / NOT EXISTS become joins.
--  * The frame comes back as 64,000 (pix, rgb) rows in pixel order rather than
--    one string_agg'd bytea: a table of exact RGB values, as SQLDoom's own
--    rule 3 allows.
--  * doom_light_index / doom_light_scale / doom_light_zdepth (43_render_light)
--    are inlined by the macro expander.
WITH render_context AS (
    SELECT ${map_id} AS map_id,
           ${player} AS player_thing_id,
           ${skill} AS skill,
           CASE WHEN ${skill}<=1 THEN 1 WHEN ${skill}=2 THEN 2 ELSE 4 END AS skill_bit
), pos AS (
    SELECT CAST(${x} AS DOUBLE) AS x, CAST(${y} AS DOUBLE) AS y,
           CAST(${z} AS DOUBLE) AS z, CAST(${angle} AS DOUBLE) AS angle
), frame_clock AS (
    SELECT CAST(COALESCE(MAX(ps.level_tics), 0) AS BIGINT) AS t
    FROM player_state ps CROSS JOIN render_context rc
    WHERE ps.map_id = rc.map_id AND ps.player_thing_id = rc.player_thing_id
), animated_light AS (
    SELECT k.sector_id,
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
    END
      )) AS light_level
    FROM (
      SELECT f.sector_id, f.base_light, f.dark_light, f.special,
             (f.sector_id*7919) % 64 AS phase,
             GREATEST(1, (f.base_light - f.dark_light) DIV 8) AS glow_steps,
             fc.t
      FROM sector_light_fx f
      CROSS JOIN render_context rc
      CROSS JOIN frame_clock fc
      WHERE f.map_id = rc.map_id
    ) k
), sectors_lit AS (
    SELECT s.map_id, s.id, s.floor_height, s.ceil_height,
           s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex,
           s.spawn_light_level, s.floor_tex, s.ceil_tex,
           COALESCE(a.light_level, s.light_level) AS light_level,
           s.special, s.tag
    FROM sectors s
    CROSS JOIN render_context rc
    LEFT JOIN animated_light a ON a.sector_id = s.id
    WHERE s.map_id = rc.map_id
), scrolling_segs AS (
    SELECT ld.id AS linedef_id
    FROM linedefs ld CROSS JOIN render_context rc
    WHERE ld.map_id = rc.map_id AND ld.scrolls
), render_settings AS (
    -- The original derives cx, cy, focal ... from screen_w and fov_rad in the
    -- same SELECT; here they are spelled out from the same constants.
    SELECT
      320 AS screen_w,
      168 AS screen_h,
      radians(90.0D) AS fov_rad,
      160.0D AS cx,
      84.0D AS cy,
      160.0D / tan(radians(90.0D) / 2.0D) AS focal,
      tan(radians(90.0D) / 2.0D) AS tan_half_fov,
      1e-3D AS near,
      16.0D * (160.0D / tan(radians(90.0D) / 2.0D)) AS max_plane_depth,
      202.5D AS rotation_offset,
      45.0D AS rotation_span,
      32 AS light_index_invuln,
      23 AS light_psprite_bias,
      256.0D AS sky_columns,
      90.0D AS sky_degrees,
      128 AS sky_rows,
      100 AS sky_horizon_y,
      64 AS flat_size
), cam AS (
    SELECT pos.x AS px, pos.y AS py, pos.z AS pz, radians(pos.angle) AS view_rad
    FROM pos
), weapon_runtime AS (
    SELECT rc.map_id, rc.player_thing_id,
           COALESCE(w.sx, 1) AS sx, COALESCE(w.sy, 32) AS sy,
           CASE WHEN COALESCE(ps2.light_amp_tics, 0) > 0 THEN 16
                ELSE COALESCE(w.flash_seq_index, -1) + 1 END AS extra_light,
           COALESCE(ps2.invuln_tics, 0) > 0 AS invuln,
           wd.sprite, wd.flash_sprite,
           CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
                THEN rf.frame ELSE mf.frame END AS frame,
           CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
                THEN rf.fullbright ELSE mf.fullbright END AS fullbright,
           ff.frame AS flash_frame, ff.fullbright AS flash_fullbright
    FROM render_context rc
    LEFT JOIN player_weapons w ON w.map_id = rc.map_id
      AND w.player_thing_id = rc.player_thing_id
    LEFT JOIN player_state ps2 ON ps2.map_id = rc.map_id
      AND ps2.player_thing_id = rc.player_thing_id
    JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
    LEFT JOIN weapon_frames rf ON rf.weapon_id = wd.weapon_id
      AND rf.state = 'ready' AND rf.seq_index = 0
    LEFT JOIN weapon_frames mf ON mf.weapon_id = wd.weapon_id
      AND mf.state = COALESCE(w.state, 'ready') AND mf.seq_index = COALESCE(w.seq_index, 0)
    LEFT JOIN weapon_frames ff ON ff.weapon_id = wd.weapon_id
      AND ff.state = 'flash' AND ff.seq_index = w.flash_seq_index
),
visible_children AS (
  SELECT
    nc.map_id, nc.node_id, nc.side,
    (c.px BETWEEN nc.bbox_left AND nc.bbox_right
     AND c.py BETWEEN nc.bbox_bottom AND nc.bbox_top)
    OR (
      ((SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad))
         * (CASE WHEN (SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad)) >= 0
                 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad))
         * (CASE WHEN (COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad)) >= 0
                 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (-c.px*SIN(-c.view_rad) - c.py*COS(-c.view_rad)
          + rs.tan_half_fov*(c.px*COS(-c.view_rad) - c.py*SIN(-c.view_rad)))
      ) <= 0.5D
      AND
      ((-SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad))
         * (CASE WHEN (-SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad)) >= 0
                 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (-COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad))
         * (CASE WHEN (-COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad)) >= 0
                 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (c.px*SIN(-c.view_rad) + c.py*COS(-c.view_rad)
          + rs.tan_half_fov*(c.px*COS(-c.view_rad) - c.py*SIN(-c.view_rad)))
      ) <= 0.5D
      AND
      ((-COS(-c.view_rad))
         * (CASE WHEN (-COS(-c.view_rad)) >= 0 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (SIN(-c.view_rad))
         * (CASE WHEN SIN(-c.view_rad) >= 0 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (rs.near + c.px*COS(-c.view_rad) - c.py*SIN(-c.view_rad))
      ) <= 0.5D
    ) AS keep
  FROM node_children nc
  CROSS JOIN cam c
  CROSS JOIN render_settings rs
  CROSS JOIN render_context rctx
  WHERE nc.map_id = rctx.map_id
),
bsp_order AS (
  SELECT s.ssector_id, ROW_NUMBER() OVER (ORDER BY s.sort_key) AS bsp_seq
  FROM (
    SELECT st.ssector_id,
           SUM(CASE WHEN st.side = (CASE
                      WHEN CAST(bround(p.x - n.x) AS BIGINT) * CAST(n.dy AS BIGINT)
                         - CAST(bround(p.y - n.y) AS BIGINT) * CAST(n.dx AS BIGINT) > 0
                        THEN 'R' ELSE 'L' END)
                    THEN CAST(0 AS BIGINT)
                    ELSE shiftleft(CAST(1 AS BIGINT), 40 - st.depth) END) AS sort_key,
           bool_and(vc.keep) AS visible
    FROM node_path_steps st
    CROSS JOIN render_context rc
    JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
    CROSS JOIN pos p
    JOIN visible_children vc ON vc.map_id = st.map_id AND vc.node_id = st.node_id
      AND vc.side = st.side
    WHERE st.map_id = rc.map_id
    GROUP BY st.ssector_id
  ) s
  WHERE s.visible
),
player_sector AS (
  SELECT ps.map_id, ps.id, ps.floor_height, ps.ceil_height,
         ps.spawn_floor_height, ps.spawn_ceil_height, ps.spawn_floor_tex,
         ps.spawn_light_level, ps.floor_tex, ps.ceil_tex, ps.light_level,
         ps.special, ps.tag
  FROM (
    SELECT sec.*, ROW_NUMBER() OVER (ORDER BY sg.seg_id) AS rn
    FROM bsp_order bo
    JOIN render_context rc ON TRUE
    JOIN render_segs sg ON sg.map_id = rc.map_id
      AND sg.ssector_id = bo.ssector_id
    JOIN sectors_lit sec ON sec.map_id = rc.map_id AND sec.id = sg.fsec
    WHERE bo.bsp_seq = 1
  ) ps
  WHERE ps.rn = 1
),
segs_with_verts AS (
  SELECT
    s.seg_id, s.direction, s.linedef_id, s.map_id,
    s.x1, s.y1, s.x2, s.y2,
    s.seg_u1, s.seg_u2
  FROM render_segs s
  JOIN bsp_order bo ON bo.ssector_id = s.ssector_id
  CROSS JOIN pos
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
    AND CAST(s.x2 - s.x1 AS BIGINT) * CAST(bround(pos.y - s.y1) AS BIGINT)
      - CAST(s.y2 - s.y1 AS BIGINT) * CAST(bround(pos.x - s.x1) AS BIGINT) < 0
),
viewspace AS (
    SELECT
        s.seg_id, s.direction, s.linedef_id, s.map_id,
        s.seg_u1, s.seg_u2,
        (s.x1 - c.px) * cos(-c.view_rad) - (s.y1 - c.py) * sin(-c.view_rad) AS x1,
        -((s.x1 - c.px) * sin(-c.view_rad) + (s.y1 - c.py) * cos(-c.view_rad)) AS y1,
        (s.x2 - c.px) * cos(-c.view_rad) - (s.y2 - c.py) * sin(-c.view_rad) AS x2,
        -((s.x2 - c.px) * sin(-c.view_rad) + (s.y2 - c.py) * cos(-c.view_rad)) AS y2
    FROM segs_with_verts s CROSS JOIN cam c
),
visible AS (
    SELECT * FROM viewspace WHERE x1 > 0 OR x2 > 0
),
clipped AS (
    SELECT
        seg_id, direction, linedef_id, map_id, seg_u1, seg_u2,
        CASE WHEN x1 < near THEN near ELSE x1 END AS cx1,
        CASE WHEN x1 < near THEN y1 + (near - x1)*(y2 - y1)/(x2 - x1) ELSE y1 END AS cy1,
        CASE WHEN x2 < near THEN near ELSE x2 END AS cx2,
        CASE WHEN x2 < near THEN y2 + (near - x2)*(y1 - y2)/(x1 - x2) ELSE y2 END AS cy2
    FROM visible CROSS JOIN render_settings
),
projected AS (
    SELECT
        seg_id, direction, linedef_id, map_id,
        cx1, cy1, cx2, cy2,
        cx + focal*(cy1/cx1) AS screen_x1,
        cx + focal*(cy2/cx2) AS screen_x2,
        1.0D/cx1 AS invx1,
        1.0D/cx2 AS invx2,
        seg_u1, seg_u2
    FROM clipped CROSS JOIN render_settings
),
on_screen AS (
  SELECT p.*
  FROM projected p
  CROSS JOIN render_settings rs
  WHERE GREATEST(p.screen_x1, p.screen_x2) >= 0
    AND LEAST(p.screen_x1, p.screen_x2) < rs.screen_w
),
heights AS (
  SELECT
    p.*, s.fsec, s.bsec,
    (s.x_offset + CASE WHEN sc.linedef_id IS NULL THEN 0 ELSE fc.t END) AS x_offset,
    s.y_offset,
    s.upper_tex, s.mid_tex, s.lower_tex, s.flags,
    s.f_floor, s.f_ceil, s.f_ceil_tex,
    COALESCE(alf.light_level, s.f_light) AS f_light,
    s.b_floor, s.b_ceil, s.b_ceil_tex,
    COALESCE(alb.light_level, s.b_light) AS b_light
  FROM on_screen p
  JOIN render_segs s ON s.map_id = p.map_id AND s.seg_id = p.seg_id
  CROSS JOIN frame_clock fc
  LEFT JOIN animated_light alf ON alf.sector_id = s.fsec
  LEFT JOIN animated_light alb ON alb.sector_id = s.bsec
  LEFT JOIN scrolling_segs sc ON sc.linedef_id = s.linedef_id
),
seg_light_bias AS (
  SELECT s.seg_id, s.light_bias
  FROM render_segs s
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
),
seg_bsp AS (
  SELECT s.seg_id, bo.bsp_seq
  FROM render_segs s
  JOIN bsp_order bo ON bo.ssector_id = s.ssector_id
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
),
occluders AS (
  SELECT h.seg_id, h.screen_x1, h.screen_x2, sb.bsp_seq
  FROM heights h
  JOIN seg_bsp sb ON sb.seg_id = h.seg_id
  WHERE h.bsec IS NULL OR h.b_ceil <= h.b_floor
),
occlusion_cols AS (
  SELECT GS(
           GREATEST(0, CAST(FLOOR(LEAST(o.screen_x1, o.screen_x2)) AS INT)),
           LEAST(rs.screen_w - 1, CAST(CEIL(GREATEST(o.screen_x1, o.screen_x2)) AS INT))
         ) AS col_x,
         o.bsp_seq
  FROM occluders o
  CROSS JOIN render_settings rs
  WHERE o.screen_x1 <> o.screen_x2
),
min_occlusion AS (
  SELECT col_x, MIN(bsp_seq) AS min_bsp_seq
  FROM occlusion_cols
  GROUP BY col_x
),
wall_parts AS (
  SELECT seg_id, 'solid' AS part, mid_tex AS tex, x_offset, y_offset, flags,
         f_floor AS z_bot, f_ceil AS z_top,
         CASE WHEN (flags & 16)<>0 THEN f_floor ELSE f_ceil END AS v_anchor_base,
         (flags & 16)<>0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NULL
  AND f_ceil > f_floor
  UNION ALL
  SELECT seg_id, 'upper', upper_tex, x_offset, y_offset, flags,
         b_ceil AS z_bot, f_ceil AS z_top,
         CASE WHEN (flags & 8)<>0 THEN f_ceil ELSE b_ceil END AS v_anchor_base,
         (flags & 8)=0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil < f_ceil
  AND (f_ceil_tex IS DISTINCT FROM 'F_SKY1'
       OR b_ceil_tex IS DISTINCT FROM 'F_SKY1')
  UNION ALL
  SELECT seg_id, 'upper_open', CAST(NULL AS STRING), x_offset, y_offset, flags,
         f_ceil AS z_bot, b_ceil AS z_top,
         b_ceil AS v_anchor_base, FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil > f_ceil
  AND (f_ceil_tex IS DISTINCT FROM 'F_SKY1'
       OR b_ceil_tex IS DISTINCT FROM 'F_SKY1')
  UNION ALL
  SELECT seg_id, 'upper_flush', CAST(NULL AS STRING), x_offset, y_offset, flags,
         f_ceil AS z_bot, b_ceil AS z_top,
         b_ceil AS v_anchor_base, FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil = f_ceil
  AND (f_ceil_tex IS DISTINCT FROM 'F_SKY1'
       OR b_ceil_tex IS DISTINCT FROM 'F_SKY1')
  UNION ALL
  SELECT seg_id, 'lower', lower_tex, x_offset, y_offset, flags,
         f_floor AS z_bot, b_floor AS z_top,
         CASE WHEN (flags & 16)<>0 THEN f_ceil ELSE b_floor END AS v_anchor_base,
         FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_floor > f_floor
  UNION ALL
  SELECT seg_id, 'lower_down', CAST(NULL AS STRING), x_offset, y_offset, flags,
         b_floor AS z_bot, f_floor AS z_top,
         f_floor AS v_anchor_base, FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_floor <= f_floor
  UNION ALL
  SELECT seg_id, 'midmask', mid_tex, x_offset, y_offset, flags,
         f_floor AS z_bot, f_ceil AS z_top,
         CASE WHEN (flags & 16)<>0 THEN GREATEST(f_floor,b_floor)
              ELSE LEAST(f_ceil,b_ceil) END AS v_anchor_base,
         (flags & 16)<>0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND mid_tex IS NOT NULL
  AND mid_tex <> '-'
  AND f_ceil > f_floor
),
wall_parts_tex AS (
  SELECT wp.*,
         COALESCE(m.width, 64)  AS tex_w,
         COALESCE(m.height, 64) AS tex_h,
         m.width                AS tex_width,
         m.tex_id               AS tex_id
  FROM wall_parts wp
  LEFT JOIN walltex_meta m ON m.name = wp.tex
),
column_bounds AS (
  SELECT w.*,
    NOT (GREATEST(w.screen_x1, w.screen_x2) < 0 OR LEAST(w.screen_x1, w.screen_x2) >= rs.screen_w) AS on_screen,
    GREATEST(0, CAST(FLOOR(LEAST(w.screen_x1, w.screen_x2)) AS INT)) AS x_lo,
    LEAST(rs.screen_w-1, CAST(CEIL(GREATEST(w.screen_x1, w.screen_x2)) AS INT)) AS x_hi
  FROM wall_parts_tex w
  CROSS JOIN render_settings rs
),
column_xs AS (
  SELECT b.*, GS(b.x_lo, b.x_hi) AS x
  FROM column_bounds b
  WHERE b.on_screen AND b.screen_x1 <> b.screen_x2
),
columns AS (
  SELECT
    w.*,
    sb.bsp_seq,
    (w.x_offset + w.seg_u1) AS u1,
    (w.x_offset + w.seg_u2) AS u2,
    w.x AS col_x,
    w.x AS screen_x_clamped,
    LEAST(1.0D, GREATEST(0.0D,
      (w.x - w.screen_x1) / NULLIF(w.screen_x2 - w.screen_x1, 1e-6D))) AS t
  FROM column_xs w
  JOIN seg_bsp sb ON sb.seg_id = w.seg_id
  LEFT JOIN min_occlusion mo ON mo.col_x = w.x
  WHERE sb.bsp_seq <= COALESCE(mo.min_bsp_seq, sb.bsp_seq)
),
per_column AS (
  SELECT
    c.*,
    c.invx,
    c.u_over_x,
    1.0D / c.invx                       AS depth_x,
    c.u_over_x / NULLIF(c.invx, 1e-6D)  AS u_col,
    rs.focal * c.invx                   AS scale
  FROM (
    SELECT c0.*,
      c0.invx1 + c0.t * (c0.invx2 - c0.invx1) AS invx,
      (c0.u1 * c0.invx1) + c0.t * ((c0.u2 * c0.invx2) - (c0.u1 * c0.invx1)) AS u_over_x
    FROM columns c0
  ) c
  CROSS JOIN render_settings rs
),
vertical AS (
  SELECT
    p.*,
    c.pz AS view_z, rs.cy AS screen_cy,
    (rs.cy - p.scale * (p.z_top - c.pz)) AS y_top_f,
    (rs.cy - p.scale * (p.z_bot - c.pz)) AS y_bot_f,
    p.v_anchor_base
      + CASE WHEN p.v_anchor_add_tex_h THEN p.tex_h ELSE 0 END
      AS v_anchor_z
  FROM per_column p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
clamped_spans AS (
  SELECT
    t.*,
    t.v_anchor_z
      - (t.view_z+(t.screen_cy-CAST(t.y_start AS DOUBLE))/NULLIF(t.scale,1e-9D))
      + CAST(t.y_offset AS DOUBLE) AS v0,
    1.0D/NULLIF(t.scale,1e-9D) AS v_step
  FROM (
    SELECT
      v.*,
      CAST(CEIL(
        LEAST(rs.screen_h - 1.0D,
              GREATEST(0.0D, LEAST(v.y_top_f, v.y_bot_f)))
      ) AS INT) AS y_start,
      CAST(FLOOR(
        LEAST(rs.screen_h - 1.0D,
              GREATEST(0.0D, GREATEST(v.y_top_f, v.y_bot_f)))
      ) AS INT) AS y_end
    FROM vertical v
    CROSS JOIN render_settings rs
    WHERE LEAST(v.y_top_f, v.y_bot_f) < rs.screen_h
      AND GREATEST(v.y_top_f, v.y_bot_f) >= 0
  ) t
  WHERE t.y_end >= t.y_start
),
clamped_spans_lit AS (
  SELECT c.*,
         CASE WHEN wr.invuln THEN rs.light_index_invuln
              ELSE DOOM_LIGHT_INDEX(c.f_light, b.light_bias + wr.extra_light,
                                    DOOM_LIGHT_SCALE(c.depth_x))
         END AS light_index,
         CAST(CAST(c.seg_id AS BIGINT)*8 + CASE c.part
            WHEN 'solid' THEN 0 WHEN 'upper' THEN 1 WHEN 'lower' THEN 2
            WHEN 'lower_down' THEN 3 ELSE 7 END AS BIGINT) AS stable_id
  FROM clamped_spans c
  JOIN seg_light_bias b ON b.seg_id = c.seg_id
  CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
),
fragment_rows AS (
  SELECT c.*, GS(c.y_start, c.y_end) AS y
  FROM clamped_spans_lit c
  WHERE c.tex IS NOT NULL AND c.tex <> '-'
),
fragments AS (
  SELECT
    c.seg_id, c.part, c.tex, c.tex_width, c.tex_id, c.light_index, c.stable_id,
    c.screen_x_clamped AS x,
    c.y AS y,
    c.depth_x AS depth,
    CAST(FLOOR(c.u_col - c.tex_w * FLOOR(c.u_col / c.tex_w)) AS INT) AS u_i,
    ((CAST(FLOOR(c.v0 + (c.y - c.y_start)*c.v_step) AS INT) % c.tex_h + c.tex_h) % c.tex_h) AS v_i,
    c.f_light AS sector_light,
    c.fsec AS sector_id
  FROM fragment_rows c
),
wall_tex AS (
  SELECT
    f.x, f.y, f.depth, f.light_index, f.stable_id,
    COALESCE(tx.palette_index, 0) AS palette_index
  FROM fragments f
  LEFT JOIN walltex_texels tx
    ON tx.tex_id = f.tex_id AND tx.off = f.v_i * f.tex_width + f.u_i
),
colored AS (
  SELECT w.x, w.y, w.depth, w.light_index, w.palette_index, w.stable_id
  FROM wall_tex w
),
panel_cols AS (
  SELECT
    v.col_x, v.seg_id, v.bsp_seq, v.part, v.depth_x, v.y_top_f, v.y_bot_f,
    CASE WHEN v.part = 'lower_down' THEN v.y_top_f ELSE v.y_bot_f END AS f_floor_y_f,
    CASE WHEN v.part = 'upper_open' THEN v.y_bot_f ELSE v.y_top_f END AS f_ceil_y_f,
    h.fsec, h.f_light, h.f_floor, h.f_ceil,
    (h.f_ceil_tex = 'F_SKY1') AS f_ceil_is_sky
  FROM vertical v
  JOIN heights h ON h.seg_id = v.seg_id
  CROSS JOIN render_settings rs
  WHERE v.part IN ('upper_open','upper_flush','lower_down')
     OR (LEAST(v.y_top_f, v.y_bot_f) < rs.screen_h
         AND GREATEST(v.y_top_f, v.y_bot_f) >= 0)
),
panel_seq AS (
  SELECT p.*,
         ROW_NUMBER() OVER (
           PARTITION BY p.col_x
           ORDER BY p.depth_x ASC, p.bsp_seq ASC, p.part, p.seg_id
         ) AS seq
  FROM panel_cols p
),
panel_marks AS (
  -- The original finds, per panel, the latest earlier panel of its column
  -- whose ceiling is above (floor below) the eye, with LATERAL ... ORDER BY
  -- seq DESC LIMIT 1. The same row is the running MAX of those seqs.
  SELECT p.*,
    COALESCE(
      MAX(CASE
            WHEN p.part IN ('solid','upper')
              THEN CAST(FLOOR(LEAST(rs.screen_h - 1.0D, GREATEST(0.0D, p.y_bot_f))) AS INT) + 1
            WHEN p.part = 'upper_flush'
              THEN GREATEST(0, CAST(FLOOR(LEAST(rs.screen_h - 1.0D, p.y_bot_f)) AS INT) + 1)
          END)
        OVER (PARTITION BY p.col_x ORDER BY p.seq
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
      0
    ) AS cc_before,
    COALESCE(
      MIN(CASE WHEN p.part IN ('solid','lower','lower_down')
               THEN LEAST(rs.screen_h - 1, CAST(CEIL(GREATEST(0.0D, p.y_top_f)) AS INT) - 1) END)
        OVER (PARTITION BY p.col_x ORDER BY p.seq
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
      rs.screen_h - 1
    ) AS fc_before,
    MAX(CASE WHEN p.f_ceil > c.pz THEN p.seq END)
      OVER (PARTITION BY p.col_x ORDER BY p.seq
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS ceil_seq,
    MAX(CASE WHEN p.f_floor < c.pz THEN p.seq END)
      OVER (PARTITION BY p.col_x ORDER BY p.seq
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS floor_seq
  FROM panel_seq p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
panel_clips AS (
  SELECT
    p.*,
    pc.fsec AS carried_ceil_sec,
    pc.f_ceil AS carried_ceil_z,
    pc.f_light AS carried_ceil_light,
    COALESCE(pc.f_ceil_is_sky, FALSE) AS carried_ceil_is_sky,
    pf.fsec AS carried_floor_sec,
    pf.f_floor AS carried_floor_z,
    pf.f_light AS carried_floor_light
  FROM panel_marks p
  LEFT JOIN panel_seq pc ON pc.col_x = p.col_x AND pc.seq = p.ceil_seq
  LEFT JOIN panel_seq pf ON pf.col_x = p.col_x AND pf.seq = p.floor_seq
),
nearest_floor_panel AS (
  SELECT col_x, MIN(depth_x) AS depth_x
  FROM panel_cols
  WHERE part IN ('solid','lower','lower_down')
  GROUP BY col_x
),
nearest_ceiling_panel AS (
  SELECT col_x, MIN(depth_x) AS depth_x
  FROM panel_cols
  WHERE part IN ('solid','upper','upper_open','upper_flush')
  GROUP BY col_x
),
screen_columns AS (
  SELECT GS(0, 319) AS x
),
plane_spans_raw AS (
  SELECT col_x, sector_id, plane_z, sector_light, is_sky, plane,
         source_priority, y0, y1
  FROM (
    SELECT
      k.col_x,
      CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
           THEN k.fsec    ELSE k.carried_ceil_sec   END AS sector_id,
      CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
           THEN k.f_ceil  ELSE k.carried_ceil_z     END AS plane_z,
      CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
           THEN k.f_light ELSE k.carried_ceil_light END AS sector_light,
      CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
           THEN k.f_ceil_is_sky ELSE k.carried_ceil_is_sky END AS is_sky,
      'ceil' AS plane, 1 AS source_priority,
      GREATEST(0, k.cc_before) AS y0,
      CAST(CEIL(LEAST(rs.screen_h - 1.0D, GREATEST(0.0D,
        CASE
          WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky THEN k.f_ceil_y_f
          ELSE LEAST(k.f_ceil_y_f,
                     rs.cy - rs.focal * (k.carried_ceil_z - c.pz)
                             / rs.max_plane_depth)
        END
      ))) AS INT) - 1 AS y1,
      k.cc_before, k.f_ceil, k.f_ceil_is_sky, k.carried_ceil_is_sky, k.part,
      c.pz
    FROM panel_clips k
    CROSS JOIN render_settings rs
    CROSS JOIN cam c
  ) b
  WHERE b.part IN ('solid','upper','upper_open','upper_flush','midmask')
    AND b.y1 >= b.cc_before
    AND (b.f_ceil > b.pz OR b.f_ceil_is_sky
         OR b.carried_ceil_is_sky OR b.cc_before > 0)
  UNION ALL
  SELECT col_x, sector_id, plane_z, sector_light, is_sky, plane,
         source_priority, y0, y1
  FROM (
    SELECT
      k.col_x,
      CASE WHEN k.f_floor < c.pz THEN k.fsec    ELSE k.carried_floor_sec   END AS sector_id,
      CASE WHEN k.f_floor < c.pz THEN k.f_floor ELSE k.carried_floor_z     END AS plane_z,
      CASE WHEN k.f_floor < c.pz THEN k.f_light ELSE k.carried_floor_light END AS sector_light,
      FALSE AS is_sky,
      'floor' AS plane, 1 AS source_priority,
      CAST(FLOOR(LEAST(rs.screen_h - 1.0D, GREATEST(0.0D,
        CASE
          WHEN k.f_floor < c.pz THEN k.f_floor_y_f
          ELSE GREATEST(k.f_floor_y_f,
                        rs.cy - rs.focal * (k.carried_floor_z - c.pz)
                                / rs.max_plane_depth)
        END
      ))) AS INT) + 1 AS y0,
      LEAST(rs.screen_h - 1, k.fc_before) AS y1,
      k.fc_before, k.f_floor, k.part, c.pz, rs.screen_h
    FROM panel_clips k
    CROSS JOIN render_settings rs
    CROSS JOIN cam c
  ) b
  WHERE b.part IN ('solid','midmask','lower','lower_down')
    AND b.y0 <= b.fc_before
    AND (b.f_floor < b.pz OR b.fc_before < b.screen_h - 1)
  UNION ALL
  SELECT
    sx.x AS col_x,
    ps.id AS sector_id,
    ps.floor_height AS plane_z,
    ps.light_level AS sector_light,
    FALSE AS is_sky,
    'floor' AS plane,
    0 AS source_priority,
    CASE WHEN np.depth_x IS NULL THEN CAST(FLOOR(rs.cy) AS INT) + 1
         ELSE CAST(FLOOR(LEAST(rs.screen_h - 1.0D, GREATEST(0.0D,
           rs.cy - rs.focal * (ps.floor_height - c.pz) / np.depth_x
         ))) AS INT) + 1
    END AS y0,
    rs.screen_h - 1 AS y1
  FROM render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  CROSS JOIN screen_columns sx
  LEFT JOIN nearest_floor_panel np ON np.col_x = sx.x
  UNION ALL
  SELECT
    sx.x AS col_x,
    ps.id AS sector_id,
    ps.ceil_height AS plane_z,
    ps.light_level AS sector_light,
    (ps.ceil_tex = 'F_SKY1') AS is_sky,
    'ceil' AS plane,
    0 AS source_priority,
    0 AS y0,
    CASE WHEN np.depth_x IS NULL THEN CAST(CEIL(rs.cy) AS INT) - 1
         ELSE CAST(CEIL(LEAST(rs.screen_h - 1.0D, GREATEST(0.0D,
           rs.cy - rs.focal * (ps.ceil_height - c.pz) / np.depth_x
         ))) AS INT) - 1
    END AS y1
  FROM render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  CROSS JOIN screen_columns sx
  LEFT JOIN nearest_ceiling_panel np ON np.col_x = sx.x
),
plane_spans AS (
  SELECT ps.*
  FROM plane_spans_raw ps
  CROSS JOIN cam c
  WHERE (ps.plane = 'floor' AND ps.plane_z < c.pz)
     OR (ps.plane = 'ceil'  AND (ps.plane_z > c.pz OR ps.is_sky))
),
plane_spans_deduped AS (
  SELECT col_x, sector_id, plane_z, plane, is_sky, y0, y1,
         MIN(sector_light)    AS sector_light,
         MIN(source_priority) AS source_priority
  FROM plane_spans
  WHERE y1 >= y0
  GROUP BY col_x, sector_id, plane_z, plane, is_sky, y0, y1
),
plane_pixels AS (
  SELECT ps.col_x AS x, GS(ps.y0, ps.y1) AS y, ps.sector_id, ps.plane_z,
         ps.sector_light, ps.plane, ps.is_sky, ps.source_priority
  FROM plane_spans_deduped ps
),
plane_rays AS (
  SELECT
    pp.x, pp.y, pp.sector_id, pp.sector_light, pp.plane, pp.source_priority,
    CASE WHEN pp.is_sky THEN 1e7D
         ELSE (rs.focal * (pp.plane_z - c.pz)) / NULLIF(rs.cy - pp.y, 0.0D)
    END AS depth_x,
    (pp.x - rs.cx) / rs.focal AS tan_alpha
  FROM plane_pixels pp
  CROSS JOIN cam c
  CROSS JOIN render_settings rs
  WHERE pp.is_sky
     OR (rs.focal * (pp.plane_z - c.pz)) / NULLIF(rs.cy - pp.y, 0.0D) > rs.near
),
plane_world AS (
  SELECT
    pr.x, pr.y, pr.sector_id, pr.sector_light, pr.plane, pr.source_priority,
    pr.depth_x AS depth,
    (c.px + pr.depth_x * COS(c.view_rad) + (pr.tan_alpha * pr.depth_x) * SIN(c.view_rad)) AS wx,
    (c.py + pr.depth_x * SIN(c.view_rad) - (pr.tan_alpha * pr.depth_x) * COS(c.view_rad)) AS wy,
    degrees(c.view_rad - ATAN(pr.tan_alpha)) AS ray_deg
  FROM plane_rays pr
  CROSS JOIN cam c
),
plane_tex AS (
  SELECT
    pw.*,
    (CASE WHEN pw.plane = 'floor' THEN s.floor_tex ELSE s.ceil_tex END) AS tex_name
  FROM plane_world pw
  CROSS JOIN render_context rc
  JOIN sectors_lit s ON s.id = pw.sector_id AND s.map_id = rc.map_id
),
plane_uv AS (
  SELECT
    x, y, sector_id, sector_light, plane, source_priority, depth, tex_name,
    (tex_name = 'F_SKY1') AS is_sky,
    CASE WHEN tex_name = 'F_SKY1'
      THEN ((CAST(FLOOR(ray_deg * (rs.sky_columns/rs.sky_degrees)) AS INT)
             % CAST(rs.sky_columns AS INT)) + CAST(rs.sky_columns AS INT)) % CAST(rs.sky_columns AS INT)
      ELSE ((CAST(FLOOR(wx) AS INT) % rs.flat_size) + rs.flat_size) % rs.flat_size
    END AS u_i,
    CASE WHEN tex_name = 'F_SKY1'
      THEN (((y - rs.sky_horizon_y) % rs.sky_rows) + rs.sky_rows) % rs.sky_rows
      ELSE ((CAST(FLOOR(wy) AS INT) % rs.flat_size) + rs.flat_size) % rs.flat_size
    END AS v_i
  FROM plane_tex CROSS JOIN render_settings rs
),
sky_texture AS (
  SELECT wt.tex_id, wt.width
  FROM maps m
  JOIN render_context rc ON rc.map_id = m.map_id
  JOIN walltex_meta wt ON wt.name = m.sky_texture
),
plane_color AS (
  -- Flat texels are found by (flat_id, v*64+u); the sky by (tex_id, v*width+u).
  -- Either key that matches no texel samples palette index 0, like the
  -- original's bounds checks.
  SELECT
    p.x, p.y, p.depth, p.sector_id, p.plane, p.sector_light, p.is_sky,
    p.source_priority,
    CASE WHEN NOT p.is_sky THEN COALESCE(fx.palette_index, 0)
         ELSE COALESCE(sx.palette_index, 0) END AS palette_index
  FROM plane_uv p
  CROSS JOIN render_settings rs
  LEFT JOIN flat_textures ft ON NOT p.is_sky AND ft.name = p.tex_name
  LEFT JOIN flat_texels fx
    ON fx.flat_id = ft.flat_id AND fx.off = p.v_i * rs.flat_size + p.u_i
  LEFT JOIN sky_texture sk ON p.is_sky
  LEFT JOIN walltex_texels sx
    ON sx.tex_id = sk.tex_id AND sx.off = p.v_i * sk.width + p.u_i
    AND p.v_i * sk.width + p.u_i >= 0
),
plane_lit AS (
  SELECT
    x, y, depth, sector_id, plane, source_priority, is_sky, palette_index,
    CASE WHEN wr.invuln THEN rs.light_index_invuln
         ELSE DOOM_LIGHT_INDEX(sector_light, wr.extra_light,
                               DOOM_LIGHT_ZDEPTH(depth))
    END AS light_index
  FROM plane_color CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
),
plane_fragments AS (
  SELECT
    p.x, p.y, p.depth, p.source_priority,
    CASE WHEN p.is_sky THEN 0 ELSE p.light_index END AS light_index,
    p.palette_index,
    CAST(CAST(p.sector_id AS BIGINT)*2
      + CASE WHEN p.plane='floor' THEN 0 ELSE 1 END AS BIGINT) AS stable_id
  FROM plane_lit p
),
thing_view AS (
  SELECT
    CAST(t.id AS BIGINT) AS thing_id, CAST(t.x AS FLOAT) AS x, CAST(t.y AS FLOAT) AS y,
    CAST(t.angle AS DOUBLE) AS angle,
    CASE WHEN COALESCE(d.explodes, FALSE) AND ai.state='die' THEN d.death_sprite
         WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
         THEN d.death_sprite ELSE rt.sprite END AS sprite,
    CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
           THEN CASE WHEN h.health < -h.max_health AND d.xdeath_frame IS NOT NULL
                     THEN d.xdeath_frame ELSE d.death_frame END
         WHEN f.frame IS NOT NULL THEN f.frame
         ELSE rt.frame END AS frame,
    CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
           THEN d.death_fullbright
         WHEN f.frame IS NOT NULL THEN f.fullbright
         ELSE rt.fullbright END AS fullbright,
    CAST(CASE WHEN rt.spawn_ceiling THEN s.ceil_height - rt.thing_height
         WHEN d.floats AND COALESCE(h.alive, TRUE) THEN t.z
         ELSE s.floor_height END AS FLOAT) AS base_z,
    s.floor_height, s.ceil_height, s.light_level AS sector_light,
    (t.x - c.px) * COS(c.view_rad)
      + (t.y - c.py) * SIN(c.view_rad) AS depth,
    (t.x - c.px) * SIN(c.view_rad)
      - (t.y - c.py) * COS(c.view_rad) AS side,
    (((CAST(FLOOR((
        DEGREES(ATAN2(t.y - c.py, t.x - c.px))
        - t.angle + rs.rotation_offset
      ) / rs.rotation_span) AS INT) % 8) + 8) % 8 + 1) AS wanted_rotation,
    COALESCE(d.fuzzy, FALSE) AS fuzz
  FROM render_things rt
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  JOIN things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN thing_health h ON h.map_id = rt.map_id AND h.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
  LEFT JOIN monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
  LEFT JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = ai.state
    AND f.seq_index = ai.seq_index
  LEFT JOIN picked_up_items pu ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
  JOIN sectors_lit s ON s.map_id = rt.map_id AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  CROSS JOIN cam c
  WHERE rt.map_id = rc.map_id
    AND (t.flags & rc.skill_bit) <> 0
    AND (t.flags & 16) = 0
    AND pu.thing_id IS NULL
    AND NOT (COALESCE(d.explodes, FALSE) AND ai.state='dead')
  UNION ALL
  SELECT
    -e.effect_id AS thing_id, e.x, e.y, CAST(0 AS DOUBLE),
    ed.sprite,
    substring(ed.frame_sequence,
              LEAST(length(ed.frame_sequence) - 1,
                    e.age DIV ed.tics_per_frame) + 1, 1),
    ed.fullbright, e.z,
    s.floor_height, s.ceil_height, COALESCE(s.light_level, ps.light_level),
    (e.x - c.px) * COS(c.view_rad) + (e.y - c.py) * SIN(c.view_rad),
    (e.x - c.px) * SIN(c.view_rad) - (e.y - c.py) * COS(c.view_rad),
    0, FALSE
  FROM world_effects e
  CROSS JOIN render_context rc
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN effect_sprite_defs ed ON ed.effect_type = e.effect_type
  LEFT JOIN sectors_lit s ON s.map_id=e.map_id AND s.id=e.sector_id
  WHERE e.map_id=rc.map_id
  UNION ALL
  SELECT
    CAST(ot.id AS BIGINT), CAST(ot.x AS FLOAT), CAST(ot.y AS FLOAT), CAST(ot.angle AS DOUBLE),
    'PLAY', op.sprite_frame, FALSE,
    CAST(s.floor_height AS FLOAT), s.floor_height, s.ceil_height, s.light_level,
    (ot.x - c.px) * COS(c.view_rad) + (ot.y - c.py) * SIN(c.view_rad),
    (ot.x - c.px) * SIN(c.view_rad) - (ot.y - c.py) * COS(c.view_rad),
    (((CAST(FLOOR((DEGREES(ATAN2(ot.y - c.py, ot.x - c.px))
        - ot.angle + rs.rotation_offset) / rs.rotation_span) AS INT) % 8)
        + 8) % 8 + 1),
    (op.invis_tics > 0)
  FROM player_state op
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  JOIN things ot ON ot.map_id = op.map_id AND ot.id = op.player_thing_id
  JOIN sectors_lit s ON s.map_id = op.map_id AND s.id = op.sector_id
  CROSS JOIN cam c
  WHERE op.map_id = rc.map_id AND op.player_thing_id <> rc.player_thing_id
  UNION ALL
  SELECT
    -(CAST(1000000000000 AS BIGINT)+mp.projectile_id) AS thing_id,
    mp.x, mp.y, CAST(PGINT(DEGREES(ATAN2(mp.vy,mp.vx))) AS DOUBLE),
    CASE WHEN mp.state='fly' THEN pd.fly_sprite ELSE pd.impact_sprite END,
    CASE
      WHEN mp.projectile_type='rocket' THEN
        CASE WHEN mp.state='fly' THEN 'A' WHEN mp.age<8 THEN 'B'
             WHEN mp.age<14 THEN 'C' ELSE 'D' END
      WHEN mp.projectile_type='plasma' THEN
        CASE WHEN mp.state='fly' THEN CASE WHEN (mp.age%12)<6 THEN 'A' ELSE 'B' END
             WHEN mp.age<4 THEN 'A' WHEN mp.age<8 THEN 'B'
             WHEN mp.age<12 THEN 'C' WHEN mp.age<16 THEN 'D' ELSE 'E' END
      WHEN mp.projectile_type='bfg' THEN
        CASE WHEN mp.state='fly' THEN CASE WHEN (mp.age%8)<4 THEN 'A' ELSE 'B' END
             WHEN mp.age<8 THEN 'A' WHEN mp.age<16 THEN 'B'
             WHEN mp.age<24 THEN 'C' WHEN mp.age<32 THEN 'D'
             WHEN mp.age<40 THEN 'E' ELSE 'F' END
      ELSE CASE WHEN mp.state='fly'
             THEN CASE WHEN (mp.age%8)<4 THEN 'A' ELSE 'B' END
             WHEN mp.age<5 THEN 'C' WHEN mp.age<10 THEN 'D' ELSE 'E' END
    END,
    TRUE, mp.z,
    COALESCE(s.floor_height,ps.floor_height),
    COALESCE(s.ceil_height,ps.ceil_height),
    COALESCE(s.light_level,ps.light_level),
    (mp.x-c.px)*COS(c.view_rad)+(mp.y-c.py)*SIN(c.view_rad),
    (mp.x-c.px)*SIN(c.view_rad)-(mp.y-c.py)*COS(c.view_rad),
    CASE WHEN mp.state='fly' THEN
      (((CAST(FLOOR((DEGREES(ATAN2(mp.y-c.py,mp.x-c.px))
          -DEGREES(ATAN2(mp.vy,mp.vx))+rs.rotation_offset)
          /rs.rotation_span) AS INT)%8)+8)%8+1)
      ELSE 0 END, FALSE
  FROM monster_projectiles mp
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
  LEFT JOIN sectors_lit s ON s.map_id=mp.map_id AND s.id=mp.sector_id
  WHERE mp.map_id=rc.map_id
),
thing_frame_choice AS (
  -- The original takes, per thing, the frame of the wanted rotation if it
  -- exists, else rotation 0 (LATERAL ... ORDER BY ... LIMIT 1).
  SELECT tv.*, f.lump_name, f.flipped, f.width, f.height,
         f.left_offset, f.top_offset,
         ROW_NUMBER() OVER (
           PARTITION BY tv.thing_id
           ORDER BY CASE WHEN f.rotation = tv.wanted_rotation THEN 0 ELSE 1 END
         ) AS pick
  FROM thing_view tv
  JOIN sprite_frames f
    ON f.sprite = tv.sprite AND f.frame = tv.frame
   AND f.rotation IN (0, tv.wanted_rotation)
),
thing_projected AS (
  SELECT
    tv.*, sl.lump_id,
    rs.focal / tv.depth AS scale,
    rs.cx + rs.focal * tv.side / tv.depth AS origin_x
  FROM thing_frame_choice tv
  CROSS JOIN render_settings rs
  JOIN sprite_lumps sl ON sl.lump_name = tv.lump_name
  WHERE tv.pick = 1
    AND tv.depth >= 4.0D
    AND ABS(tv.side) <= tv.depth * 2.0D
),
thing_bounds AS (
  SELECT
    tp.*,
    tp.origin_x - tp.scale * tp.left_offset AS x_left_f,
    tp.origin_x + tp.scale * (tp.width - tp.left_offset) AS x_right_f,
    rs.cy - tp.scale * (tp.base_z + tp.top_offset - c.pz) AS y_top_f,
    rs.cy - tp.scale
      * (tp.base_z + tp.top_offset - tp.height - c.pz) AS y_bottom_f
  FROM thing_projected tp
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
thing_bounds_lit AS (
  SELECT tb.*,
         CASE WHEN wr.invuln THEN rs.light_index_invuln
              WHEN tb.fullbright THEN 0
              ELSE DOOM_LIGHT_INDEX(tb.sector_light, wr.extra_light,
                                    DOOM_LIGHT_SCALE(tb.depth))
         END AS base_light
  FROM thing_bounds tb
  CROSS JOIN weapon_runtime wr CROSS JOIN render_settings rs
),
thing_cols AS (
  SELECT tb.*, GS(
           GREATEST(0, CAST(FLOOR(tb.x_left_f) AS INT)),
           LEAST(rs.screen_w - 1, CAST(CEIL(tb.x_right_f) AS INT) - 1)) AS screen_x
  FROM thing_bounds_lit tb
  CROSS JOIN render_settings rs
  WHERE tb.x_right_f > 0 AND tb.x_left_f < rs.screen_w
    AND tb.y_bottom_f > 0 AND tb.y_top_f < rs.screen_h
),
thing_cells AS (
  SELECT tb.*, GS(
           GREATEST(0, CAST(FLOOR(tb.y_top_f) AS INT)),
           LEAST(rs.screen_h - 1, CAST(CEIL(tb.y_bottom_f) AS INT) - 1)) AS screen_y
  FROM thing_cols tb
  CROSS JOIN render_settings rs
),
thing_uv AS (
  SELECT tb.*,
    LEAST(tb.height - 1, GREATEST(0,
      CAST(FLOOR((tb.screen_y - tb.y_top_f) / tb.scale) AS INT))) AS v_i,
    LEAST(tb.width - 1, GREATEST(0,
      CAST(FLOOR((tb.screen_x - tb.x_left_f) / tb.scale) AS INT))) AS raw_u
  FROM thing_cells tb
),
thing_pixels AS (
  SELECT
    tb.thing_id, tb.screen_x AS x, tb.screen_y AS y,
    tb.depth, tb.sector_light, tb.fullbright, tb.fuzz, tb.base_light,
    CASE WHEN mpl.slot > 1 AND px.palette_index BETWEEN 112 AND 127
         THEN px.palette_index - 112 + CASE mpl.slot WHEN 2 THEN 96 WHEN 3 THEN 64 ELSE 32 END
         ELSE px.palette_index END AS palette_index
  FROM thing_uv tb
  CROSS JOIN render_context rc
  LEFT JOIN mp_players mpl ON mpl.map_id = rc.map_id AND mpl.player_thing_id = tb.thing_id
  JOIN sprite_texels px
    ON px.lump_id = tb.lump_id
   AND px.off = tb.v_i * tb.width
              + CASE WHEN tb.flipped THEN tb.width - 1 - tb.raw_u ELSE tb.raw_u END
),
sprite_fragments AS (
  SELECT
    sp.x, sp.y, sp.depth, sp.thing_id AS stable_id, sp.palette_index,
    CASE WHEN sp.fuzz THEN
      CAST(26 + ((sp.x * 7 + sp.y * 13 + PGINT(sp.depth)) % 5) AS INT)
    ELSE sp.base_light
    END AS light_index
  FROM thing_pixels sp
),
fragment_union AS (
  SELECT x, y, depth, light_index, palette_index,
         CAST(2 AS BIGINT) AS surface_priority, CAST(0 AS BIGINT) AS source_priority, stable_id
  FROM colored
  UNION ALL
  SELECT x, y, depth, light_index, palette_index,
         CAST(1 AS BIGINT), CAST(0 AS BIGINT), stable_id
  FROM sprite_fragments
  UNION ALL
  SELECT x, y, depth, light_index, palette_index,
         CAST(0 AS BIGINT), CAST(source_priority AS BIGINT), stable_id
  FROM plane_fragments
),
ranked_fragments AS (
  SELECT u.y*rs.screen_w+u.x AS pix,
         shiftleft(CAST(bround(GREATEST(0.0D, LEAST(u.depth, 131071.0D))*4096) AS BIGINT), 34)
         | shiftleft(CAST(2 AS BIGINT) - u.surface_priority, 32)
         | shiftleft(LEAST(u.source_priority, CAST(3 AS BIGINT)), 30)
         | shiftleft(LEAST(CAST(65535 AS BIGINT), GREATEST(CAST(0 AS BIGINT), u.stable_id + 32768)), 14)
         | shiftleft(CAST(u.light_index AS BIGINT), 8)
         | CAST(u.palette_index AS BIGINT) AS winner_key
  FROM fragment_union u CROSS JOIN render_settings rs
),
resolved AS (
  SELECT CAST(w.pix % rs.screen_w AS INT) AS x, CAST(w.pix DIV rs.screen_w AS INT) AS y,
         CAST(shiftright(w.winner_key, 8) & 63 AS INT) AS light_index,
         CAST(w.winner_key & 255 AS INT) AS palette_index
  FROM (SELECT pix, MIN(winner_key) AS winner_key
        FROM ranked_fragments GROUP BY pix) w
  CROSS JOIN render_settings rs
),
psprite_layers AS (
  SELECT 1 AS layer, wr.sprite, wr.frame AS frame,
         CAST(wr.sx AS DOUBLE) AS sx, CAST(wr.sy AS DOUBLE) AS sy,
         COALESCE(wr.fullbright, FALSE) AS fullbright
  FROM weapon_runtime wr
  UNION ALL
  SELECT 2, wr.flash_sprite, wr.flash_frame AS frame,
         CAST(wr.sx AS DOUBLE), CAST(wr.sy AS DOUBLE), COALESCE(wr.flash_fullbright, TRUE)
  FROM weapon_runtime wr
  WHERE wr.flash_sprite IS NOT NULL AND wr.flash_frame IS NOT NULL
),
psprite_patches AS (
  SELECT p.*, sf.width, sf.height, sf.left_offset, sf.top_offset,
         sl.lump_id,
         p.sx - sf.left_offset AS x_left_f,
         p.sy - sf.top_offset + rs.cy - 100.0D - 0.5D AS y_top_f
  FROM psprite_layers p
  CROSS JOIN render_settings rs
  JOIN sprite_frames sf ON sf.sprite=p.sprite AND sf.frame=p.frame
    AND sf.rotation=0
  JOIN sprite_lumps sl ON sl.lump_name=sf.lump_name
),
psprite_cols AS (
  SELECT q.*, GS(
           GREATEST(0, CAST(FLOOR(q.x_left_f) AS INT)),
           LEAST(rs.screen_w-1, CAST(FLOOR(q.x_left_f) AS INT)+q.width-1)) AS x
  FROM psprite_patches q
  CROSS JOIN render_settings rs
),
psprite_cells AS (
  SELECT q.*, GS(
           GREATEST(0, CAST(FLOOR(q.y_top_f) AS INT)),
           LEAST(rs.screen_h-1, CAST(FLOOR(q.y_top_f) AS INT)+q.height-1)) AS y
  FROM psprite_cols q
  CROSS JOIN render_settings rs
),
psprite_pixels AS (
  SELECT q.layer, q.x, q.y, q.fullbright, px.palette_index
  FROM psprite_cells q
  JOIN sprite_texels px
    ON px.lump_id = q.lump_id
   AND px.off = (q.y - CAST(FLOOR(q.y_top_f) AS INT))*q.width
              + (q.x - CAST(FLOOR(q.x_left_f) AS INT))
),
psprite_resolved AS (
  SELECT p.x, p.y, p.palette_index,
    CASE WHEN wr.invuln THEN rs.light_index_invuln
         WHEN p.fullbright THEN 0
         ELSE DOOM_LIGHT_INDEX(ps.light_level, wr.extra_light,
                               rs.light_psprite_bias)
    END AS light_index
  FROM (
    SELECT pp.*, ROW_NUMBER() OVER (
      PARTITION BY pp.x, pp.y ORDER BY pp.layer DESC) AS rn
    FROM psprite_pixels pp
  ) p
  CROSS JOIN player_sector ps CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
  WHERE p.rn=1
),
final_pixels AS (
  SELECT COALESCE(p.x,r.x) AS x, COALESCE(p.y,r.y) AS y,
         COALESCE(p.light_index,r.light_index) AS light_index,
         COALESCE(p.palette_index,r.palette_index) AS palette_index
  FROM resolved r FULL OUTER JOIN psprite_resolved p ON p.x = r.x AND p.y = r.y
),
player_ui_state AS (
  SELECT ps.health, ps.alive, ps.pain_face_tics, ps.armor,
         ps.ammo_bullets, ps.ammo_shells, ps.ammo_rockets, ps.ammo_cells,
         ps.key_blue, ps.key_yellow, ps.key_red,
         ps.damage_count, ps.bonus_count, ps.radsuit_tics,
         ps.message, ps.message_tics, ps.backpack,
         wd.ammo_type AS current_ammo_type
  FROM player_state ps
  CROSS JOIN render_context rc
  LEFT JOIN player_weapons w ON w.map_id = ps.map_id
    AND w.player_thing_id = ps.player_thing_id
  LEFT JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
  WHERE ps.map_id = rc.map_id AND ps.player_thing_id = rc.player_thing_id
),
active_palette AS (
  SELECT CASE
    WHEN pu.damage_count > 0
      THEN LEAST(7, (pu.damage_count + 7) DIV 8) + 1
    WHEN pu.bonus_count > 0
      THEN LEAST(3, (pu.bonus_count + 7) DIV 8) + 9
    WHEN pu.radsuit_tics > 128 OR (pu.radsuit_tics & 8) <> 0
      THEN 13
    ELSE 0
  END AS pal
  FROM player_ui_state pu
),
palette_map AS (
  SELECT cm.level, cm.palette_index, cm.rgb
  FROM colormap_rgb cm
  CROSS JOIN active_palette ap
  WHERE cm.pal = ap.pal
),
weapon_slots AS (
  SELECT GS(2, 7) AS weapon_id
),
weapon_ownership AS (
  SELECT slot.weapon_id, o.weapon_id IS NOT NULL AS owned
  FROM weapon_slots slot
  LEFT JOIN (
    SELECT DISTINCT o.weapon_id
    FROM player_weapon_owned o CROSS JOIN render_context rc
    WHERE o.map_id=rc.map_id AND o.player_thing_id=rc.player_thing_id
  ) o ON o.weapon_id = slot.weapon_id
),
weapon_layers AS (
  SELECT 2 AS layer,
         (CASE WHEN owned THEN 'STYSNUM' ELSE 'STGNUM' END)
           || CAST(weapon_id AS STRING) AS patch,
         111+((weapon_id-2)%3)*12 AS x,
         172+((weapon_id-2) DIV 3)*10 AS y
  FROM weapon_ownership
),
ui_face AS (
  SELECT
    CASE
      WHEN NOT pu.alive THEN 'STFDEAD0'
      WHEN pu.pain_face_tics > 0 THEN
        'STFOUCH' || CAST(LEAST(4, GREATEST(0, (100 - GREATEST(0, LEAST(100, pu.health))) DIV 20)) AS STRING)
      ELSE
        'STFST' || CAST(LEAST(4, GREATEST(0, (100 - GREATEST(0, LEAST(100, pu.health))) DIV 20)) AS STRING) || '0'
    END AS face_patch
  FROM player_ui_state pu
),
status_bar AS (
  SELECT
    rs.screen_h     AS top_y,
    rs.screen_h + 4 AS digit_y,
    90  AS health_right_x,
    221 AS armor_right_x,
    44  AS ammo_right_x,
    288 AS ammo_box_right_x,
    314 AS max_ammo_right_x,
    239 AS key_x,
    143 AS face_x,
    14  AS tall_digit_w,
    4   AS short_digit_w
  FROM render_settings rs
),
health_digits AS (SELECT pu.health AS value, sb.health_right_x AS right_x
                  FROM player_ui_state pu CROSS JOIN status_bar sb),
armor_digits AS (SELECT pu.armor AS value, sb.armor_right_x AS right_x
                 FROM player_ui_state pu CROSS JOIN status_bar sb),
ammo_digits AS (
  SELECT
    CASE pu.current_ammo_type
      WHEN 'bullets' THEN pu.ammo_bullets WHEN 'shells' THEN pu.ammo_shells
      WHEN 'rockets' THEN pu.ammo_rockets WHEN 'cells' THEN pu.ammo_cells
    END AS value,
    sb.ammo_right_x AS right_x
  FROM player_ui_state pu CROSS JOIN status_bar sb
  WHERE pu.current_ammo_type IS NOT NULL
),
ammo_type_values AS (
  SELECT pu.ammo_bullets AS value, sb.ammo_box_right_x AS right_x, 173 AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_shells, sb.ammo_box_right_x, 179
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_rockets, sb.ammo_box_right_x, 185
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_cells, sb.ammo_box_right_x, 191
  FROM player_ui_state pu CROSS JOIN status_bar sb
),
ammo_max_values AS (
  SELECT (CASE WHEN pu.backpack THEN ad.backpack_cap ELSE ad.cap END) AS value,
         sb.max_ammo_right_x AS right_x,
         (CASE ad.ammo_type WHEN 'bullets' THEN 173 WHEN 'shells' THEN 179
                            WHEN 'rockets' THEN 185 ELSE 191 END) AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb
  CROSS JOIN ammo_defs ad
),
key_layers AS (
  SELECT 1 AS layer, 'STKEYS0' AS patch, sb.key_x AS x, 171 AS y
  FROM player_ui_state CROSS JOIN status_bar sb WHERE key_blue
  UNION ALL SELECT 1, 'STKEYS1', sb.key_x, 181
  FROM player_ui_state CROSS JOIN status_bar sb WHERE key_yellow
  UNION ALL SELECT 1, 'STKEYS2', sb.key_x, 191
  FROM player_ui_state CROSS JOIN status_bar sb WHERE key_red
),
digit_values AS (
  -- One row per number on the bar: its text, right edge, row and digit font.
  SELECT CAST(hd.value AS STRING) AS txt, hd.right_x, sb.digit_y AS y,
         'STTNUM' AS font, sb.tall_digit_w AS w
  FROM health_digits hd CROSS JOIN status_bar sb
  UNION ALL
  SELECT CAST(ad.value AS STRING), ad.right_x, sb.digit_y, 'STTNUM', sb.tall_digit_w
  FROM armor_digits ad CROSS JOIN status_bar sb
  UNION ALL
  SELECT CAST(am.value AS STRING), am.right_x, sb.digit_y, 'STTNUM', sb.tall_digit_w
  FROM ammo_digits am CROSS JOIN status_bar sb
  UNION ALL
  SELECT CAST(at.value AS STRING), at.right_x, at.y, 'STYSNUM', sb.short_digit_w
  FROM ammo_type_values at CROSS JOIN status_bar sb
  UNION ALL
  SELECT CAST(mx.value AS STRING), mx.right_x, mx.y, 'STYSNUM', sb.short_digit_w
  FROM ammo_max_values mx CROSS JOIN status_bar sb
),
digit_chars AS (
  SELECT dv.*, GS(1, length(dv.txt)) AS i FROM digit_values dv
),
digit_layers AS (
  SELECT 1 AS layer,
    dc.font || substring(dc.txt, dc.i, 1) AS patch,
    dc.right_x - (length(dc.txt) - dc.i + 1) * dc.w AS x,
    dc.y AS y
  FROM digit_chars dc
),
ui_layers AS (
  SELECT layer, patch, x, y FROM digit_layers
  UNION ALL SELECT layer, patch, x, y FROM key_layers
  UNION ALL SELECT layer, patch, x, y FROM weapon_layers
  UNION ALL SELECT 1, face_patch, sb.face_x, sb.top_y
  FROM ui_face CROSS JOIN status_bar sb
),
ui_layer_patches AS (
  SELECT l.layer, l.patch, l.x-p.left_offset AS dest_x,
         l.y-p.top_offset AS dest_y
  FROM ui_layers l
  JOIN ui_patches p ON p.name = l.patch
),
ui_pixels AS (
  SELECT ulp.layer, ulp.dest_x+px.dx AS x, ulp.dest_y+px.dy AS y,
         px.palette_index
  FROM ui_layer_patches ulp
  JOIN ui_hud_pixels px ON px.name=ulp.patch
),
ui_resolved AS (
  SELECT x, y, max_by(palette_index, layer) AS palette_index
  FROM ui_pixels GROUP BY x, y
),
ui_colored AS (
  SELECT s.x, s.y,
         COALESCE(ovcm.rgb,
                  CASE WHEN ap.pal = 0 THEN s.rgb ELSE barcm.rgb END,
                  s.rgb) AS rgb
  FROM ui_static_pixels s
  CROSS JOIN active_palette ap
  LEFT JOIN ui_resolved ur ON ur.x = s.x AND ur.y = s.y
  LEFT JOIN palette_map ovcm
    ON ovcm.level = 0 AND ovcm.palette_index = ur.palette_index
  LEFT JOIN palette_map barcm
    ON ap.pal <> 0 AND barcm.level = 0
   AND barcm.palette_index = s.palette_index
),
view_colored AS (
  SELECT r.x, r.y, COALESCE(cm.rgb, 0) AS rgb
  FROM final_pixels r
  LEFT JOIN palette_map cm
    ON cm.level = r.light_index
   AND cm.palette_index = r.palette_index
),
view_cells AS (
  SELECT sx.x, GS(0, 167) AS y FROM screen_columns sx
),
view_holes AS (
  SELECT vc.x, vc.y, 0 AS rgb
  FROM view_cells vc
  LEFT ANTI JOIN final_pixels f ON f.x = vc.x AND f.y = vc.y
),
message_glyphs AS (
  SELECT g.i AS pos, substring(upper(g.message), g.i, 1) AS ch
  FROM (
    SELECT pu.message, GS(1, length(pu.message)) AS i
    FROM player_ui_state pu
    WHERE pu.message IS NOT NULL AND pu.message_tics > 0
  ) g
),
message_placed AS (
  SELECT g.pos, g.ch,
         CASE WHEN g.ch = ' ' THEN NULL
              ELSE 'STCFN' || lpad(CAST(ascii(g.ch) AS STRING), 3, '0') END AS patch,
         SUM(CASE WHEN g.ch = ' ' THEN 4 ELSE COALESCE(p.width, 4) END)
           OVER (ORDER BY g.pos ROWS BETWEEN UNBOUNDED PRECEDING
                                     AND 1 PRECEDING) AS pen
  FROM message_glyphs g
  LEFT JOIN ui_patches p
    ON g.ch <> ' ' AND p.name = 'STCFN' || lpad(CAST(ascii(g.ch) AS STRING), 3, '0')
),
message_pixels AS (
  SELECT CAST(COALESCE(mp.pen, 0) AS INT) + px.dx AS x, 1 + px.dy AS y,
         px.palette_index
  FROM message_placed mp
  JOIN ui_hud_pixels px ON px.name = mp.patch
  WHERE mp.patch IS NOT NULL
),
message_colored AS (
  SELECT m.x, m.y, cm.rgb
  FROM message_pixels m
  JOIN palette_map cm ON cm.level = 0 AND cm.palette_index = m.palette_index
  WHERE m.x BETWEEN 0 AND 319 AND m.y BETWEEN 0 AND 167
),
framebuffer AS (
  SELECT v.y * 320 + v.x AS pix, COALESCE(m.rgb, v.rgb) AS rgb
  FROM view_colored v
  LEFT JOIN message_colored m ON m.x = v.x AND m.y = v.y
  UNION ALL
  SELECT h.y * 320 + h.x AS pix, COALESCE(m.rgb, h.rgb) AS rgb
  FROM view_holes h
  LEFT JOIN message_colored m ON m.x = h.x AND m.y = h.y
  UNION ALL
  SELECT y * 320 + x AS pix, rgb FROM ui_colored
)
SELECT pix, rgb FROM framebuffer ORDER BY pix
