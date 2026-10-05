"""Export a loaded SQLDoom database from CedarDB to Parquet, for Sail.

Every base table and the materialized views go to <out>/<table>.parquet with
types taken from the wire protocol. Then the byte blobs the renderer samples
with GET_BYTE are expanded into texel tables, one row per texel, because a
relational engine joins on a texel far better than it carries a 16 KB blob
through a join:

  walltex_texels(tex_id, off, palette_index)     every texel
  flat_texels(flat_id, off, palette_index)       every texel
  sprite_texels(lump_id, off, palette_index)     opaque texels only (mask <> 0)

walltex_meta, flat_textures and sprite_lumps get an integer id column to join
on, and keep their other columns except the blobs.
"""

import argparse
from pathlib import Path

import numpy as np
import psycopg2
import pyarrow as pa
import pyarrow.parquet as pq

MATVIEWS = ("node_path_steps", "sector_adjacency", "linedef_geom",
            "ui_hud_pixels", "ui_static_pixels")

# Postgres type OIDs; anything else (enums, domains) is exported as text.
OID_TYPES = {
    16: pa.bool_(), 17: pa.binary(), 18: pa.string(), 19: pa.string(),
    20: pa.int64(), 21: pa.int32(), 23: pa.int32(), 25: pa.string(),
    700: pa.float32(), 701: pa.float64(), 1042: pa.string(),
    1043: pa.string(), 1700: pa.float64(),
    1114: pa.timestamp("us"), 1184: pa.timestamp("us", tz="UTC"),
}


def export_table(cur, name, out):
    cur.execute(f'SELECT * FROM "{name}"')
    rows = cur.fetchall()
    fields, columns = [], []
    for i, d in enumerate(cur.description):
        ty = OID_TYPES.get(d.type_code, pa.string())
        values = [r[i] for r in rows]
        if ty == pa.binary():
            values = [None if v is None else bytes(v) for v in values]
        elif ty == pa.float64() and d.type_code == 1700:
            values = [None if v is None else float(v) for v in values]
        elif ty == pa.string():
            values = [None if v is None else str(v) for v in values]
        fields.append(pa.field(d.name, ty))
        columns.append(pa.array(values, type=ty))
    table = pa.Table.from_arrays(columns, schema=pa.schema(fields))
    pq.write_table(table, out / f"{name}.parquet")
    return table


def texels(table, blob, id_name, mask=None):
    """Expand table[blob] into (id, off, palette_index) rows."""
    ids, offs, values = [], [], []
    blobs = table.column(blob).to_pylist()
    masks = table.column(mask).to_pylist() if mask else None
    for i, b in enumerate(blobs):
        v = np.frombuffer(b, dtype=np.uint8)
        off = np.arange(len(v), dtype=np.int32)
        if masks is not None:
            keep = np.frombuffer(masks[i], dtype=np.uint8) != 0
            v, off = v[keep], off[keep]
        ids.append(np.full(len(v), i, dtype=np.int32))
        offs.append(off)
        values.append(v.astype(np.int32))
    return pa.table({id_name: np.concatenate(ids), "off": np.concatenate(offs),
                     "palette_index": np.concatenate(values)})


def with_id(table, id_name, drop):
    table = table.add_column(0, id_name, pa.array(np.arange(table.num_rows,
                                                            dtype=np.int32)))
    return table.drop_columns(list(drop))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("""SELECT table_name FROM information_schema.tables
                   WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
                   ORDER BY table_name""")
    names = [r[0] for r in cur.fetchall()] + list(MATVIEWS)
    tables = {}
    for name in names:
        tables[name] = export_table(cur, name, args.out)
        print(f"{name}: {tables[name].num_rows}")

    wt = tables["walltex_meta"].sort_by("name")
    ft = tables["flat_textures"].sort_by("name")
    sl = tables["sprite_lumps"].sort_by("lump_name")
    for name, table in (
        ("walltex_texels", texels(wt, "palette_indices", "tex_id")),
        ("flat_texels", texels(ft, "palette_indices", "flat_id")),
        ("sprite_texels", texels(sl, "pixels", "lump_id", mask="mask")),
        ("walltex_meta", with_id(wt, "tex_id", ["palette_indices"])),
        ("flat_textures", with_id(ft, "flat_id", ["palette_indices"])),
        ("sprite_lumps", with_id(sl, "lump_id", ["pixels", "mask"])),
    ):
        pq.write_table(table, args.out / f"{name}.parquet")
        print(f"{name}: {table.num_rows}")


if __name__ == "__main__":
    main()
