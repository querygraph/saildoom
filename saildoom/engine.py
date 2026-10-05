"""Sail session, per-map data and the renderer.

The WAD lives in Parquet (data/<wad>/*.parquet, written by the loader). For a
level, every table with a map_id is cut to that map, and the texel tables to
the textures, flats and sprites the map can show, so a frame joins against
thousands of texels instead of millions. The cut is written once per map under
data/<wad>/maps/<map_id>/ and registered in Sail as temporary views with the
original table names, so the SQL reads like SQLDoom's.
"""

import os
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

from .sqlmacro import expand, strip_comments

ROOT = Path(__file__).resolve().parents[1]

RENDER_TABLES = (
    "ammo_defs", "colormap_rgb", "effect_sprite_defs", "flat_texels",
    "flat_textures", "linedefs", "maps", "monster_ai", "monster_projectiles",
    "mp_players", "node_children", "node_path_steps", "nodes",
    "picked_up_items", "player_state", "player_weapon_owned", "player_weapons",
    "projectile_defs", "render_segs", "render_things", "sector_light_fx",
    "sectors", "sprite_frames", "sprite_lumps", "sprite_texels",
    "thing_ai_frames", "thing_combat_defs", "thing_health", "things",
    "ui_hud_pixels", "ui_patches", "ui_static_pixels", "walltex_meta",
    "walltex_texels", "weapon_defs", "weapon_frames", "world_effects",
)


def connect(url=None):
    from pyspark.sql import SparkSession
    url = url or os.environ.get("SAIL_REMOTE", "sc://localhost:50051")
    return SparkSession.builder.remote(url).getOrCreate()


def _rgb_int(table):
    """Replace a 3-byte rgb blob column by the integer r<<16 | g<<8 | b."""
    if "rgb" not in table.column_names:
        return table
    values = [None if b is None else (b[0] << 16) | (b[1] << 8) | b[2]
              for b in table.column("rgb").to_pylist()]
    i = table.column_names.index("rgb")
    return table.set_column(i, "rgb", pa.array(values, pa.int32()))


def cut_map(data, map_id):
    """Write data/<wad>/maps/<map_id>/<table>.parquet; return that directory."""
    out = Path(data) / "maps" / str(map_id)
    if (out / "_done").exists():
        return out
    out.mkdir(parents=True, exist_ok=True)
    read = lambda name: pq.read_table(Path(data) / f"{name}.parquet")
    tables = {}
    for name in RENDER_TABLES:
        t = read(name)
        if "map_id" in t.column_names:
            t = t.filter(pc.equal(t.column("map_id"), map_id))
        tables[name] = _rgb_int(t)

    # Wall textures: every name the map's sides use, and its sky.
    segs = tables["render_segs"]
    names = set()
    for col in ("upper_tex", "mid_tex", "lower_tex"):
        names.update(v for v in segs.column(col).to_pylist() if v)
    sidedefs = read("sidedefs")
    if "map_id" in sidedefs.column_names:
        sidedefs = sidedefs.filter(pc.equal(sidedefs.column("map_id"), map_id))
        for col in sidedefs.column_names:
            if col.endswith("_tex") or col.endswith("_texture"):
                names.update(v for v in sidedefs.column(col).to_pylist()
                             if isinstance(v, str) and v)
    # A switch flips its side between SWn and the other state when used.
    names.update({"SW2" + n[3:] for n in names if n.startswith("SW1")}
                 | {"SW1" + n[3:] for n in names if n.startswith("SW2")})
    names.update(tables["maps"].column("sky_texture").to_pylist())
    meta = tables["walltex_meta"]
    keep = pc.is_in(meta.column("name"), pa.array(sorted(names)))
    tex_ids = meta.filter(keep).column("tex_id")
    tables["walltex_texels"] = tables["walltex_texels"].filter(
        pc.is_in(tables["walltex_texels"].column("tex_id"), tex_ids))

    # Flats: everything a sector of this map shows or can change to. A mover
    # copies a flat from a neighbouring sector of the same map, so the map's
    # own flats are enough.
    sectors = tables["sectors"]
    flats = set()
    for col in ("floor_tex", "ceil_tex", "spawn_floor_tex"):
        flats.update(v for v in sectors.column(col).to_pylist() if v)
    ft = tables["flat_textures"]
    flat_ids = ft.filter(pc.is_in(ft.column("name"), pa.array(sorted(flats)))).column("flat_id")
    tables["flat_texels"] = tables["flat_texels"].filter(
        pc.is_in(tables["flat_texels"].column("flat_id"), flat_ids))

    for name, t in tables.items():
        pq.write_table(t, out / f"{name}.parquet")
    (out / "_done").write_text("")
    return out


def load_map(spark, data, map_id, cache=None):
    """Register the map's tables in Sail under their original names."""
    cache = os.environ.get("SAILDOOM_CACHE", "1") == "1" if cache is None else cache
    directory = cut_map(data, map_id)
    for name in RENDER_TABLES:
        df = spark.read.parquet(str(directory / f"{name}.parquet"))
        if cache:
            df = df.cache()
        df.createOrReplaceTempView(name)
    return directory


def renderer_sql():
    return strip_comments((ROOT / "sql" / "renderer.sql").read_text())


def render(spark, sql_text, map_id, player, skill, pose):
    """One frame: 320x200x3 RGB bytes."""
    x, y, z, angle = (float(v) for v in pose)
    sql = expand(sql_text, dict(map_id=map_id, player=player, skill=skill,
                                x=x, y=y, z=z, angle=angle))
    table = spark.sql(sql).toArrow()
    rgb = table.column("rgb").to_numpy().astype(np.uint32)
    if len(rgb) != 64000:
        raise RuntimeError(f"frame has {len(rgb)} pixels, not 64000")
    out = np.empty((64000, 3), dtype=np.uint8)
    out[:, 0] = rgb >> 16
    out[:, 1] = (rgb >> 8) & 255
    out[:, 2] = rgb & 255
    return out.tobytes()
