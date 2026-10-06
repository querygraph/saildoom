"""sql/renderer.sql as doom_render_frame and doom_render_frame_folded.

The renderer reads its tables under their SQLDoom names, cut to one map
(engine.cut_map), with colormap rgb as an integer and the texel tables merged.
It runs in a Spark session of its own, so the client's render thread does not
share temporary views with the game: the static tables come from the map's
cut, the state tables from the backend's current versions, re-registered when
a version changes.
"""

import os
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pyarrow.compute as pc

from .. import engine
from ..sqlmacro import expand

DATA = Path(os.environ.get("SAILDOOM_DATA", engine.ROOT / "data/freedoom1"))


class Renderer:
    def __init__(self, store):
        from pyspark.sql import SparkSession
        url = os.environ.get("SAIL_REMOTE", "sc://localhost:50051")
        self.spark = SparkSession.builder.remote(url).create()
        for key, value in engine.CLIENT_CONFIGS.items():
            self.spark.conf.set(key, value)
        self.store = store
        self.sql = engine.renderer_sql()
        self.map_id = None
        self.meta = None
        self.registered = {}
        self.lock = threading.Lock()

    def frame(self, map_id, player, skill, pose):
        with self.lock:
            if map_id != self.map_id:
                engine.load_map(self.spark, DATA, map_id)
                self.map_id, self.meta, self.registered = map_id, engine.map_meta(DATA, map_id), {}
            for name in engine.STATE_TABLES:
                path = self.store.paths.get(name)
                if path and self.registered.get(name) != path:
                    self.spark.read.parquet(path).createOrReplaceTempView(name)
                    self.registered[name] = path
            return engine.render(self.spark, self.sql, map_id, player, skill, pose, self.meta)


class ReusedRenderer:
    """sql/renderer_batch.sql for one frame on a plan kept for the level.

    The batch renderer reads the pose from a frames relation and the state
    tables by tic, so its SQL is the same for every frame of a level: here
    the frames relation is a one-row slot (frame_pose) and every state table a
    slot of the map's current rows at tic 0 (spark.sail.slotViews), and the
    fork's plan cache (spark.sail.planCache) plans it once."""

    def __init__(self, store):
        from pyspark.sql import SparkSession
        url = os.environ.get("SAIL_REMOTE", "sc://localhost:50051")
        self.spark = SparkSession.builder.remote(url).create()
        for key, value in engine.CLIENT_CONFIGS.items():
            self.spark.conf.set(key, value)
        # Every table the renderer reads is a slot: the map's static tables
        # filled once per level (a view over a file is read again every frame,
        # and Sail's cache() does nothing), the state tables when they change.
        self.spark.conf.set("spark.sail.slotViews", ",".join(engine.RENDER_TABLES + engine.STATE_TABLES + ("frame_pose",)))
        self.spark.conf.set("spark.sail.planCache", "true")
        # A frame is 64,000 pixels: a few partitions, not one per core.
        self.spark.conf.set("spark.sail.targetPartitions", os.environ.get("SAILDOOM_RENDER_PARTITIONS", "4"))
        self.store = store
        self.sql = engine.batch_sql()
        self.map_id = None
        self.loaded = {}
        self.frames = {}
        self.pool = ThreadPoolExecutor(max_workers=8)
        self.lock = threading.Lock()

    def frame(self, map_id, player, skill, pose, paths=None):
        """One frame. `paths` gives the state tables' files when there is no
        store in this process (RenderProcess); the slots are then filled on
        the server from those files."""
        with self.lock:
            if map_id != self.map_id:
                directory = engine.cut_map(DATA, map_id)
                static = [n for n in engine.RENDER_TABLES if n not in engine.STATE_TABLES]
                list(self.pool.map(lambda n: self.spark.sql(
                    f"SELECT * FROM parquet.`{directory / (n + '.parquet')}`").createOrReplaceTempView(n), static))
                self.map_id, self.loaded, self.frames = map_id, {}, {}
                self.meta = engine.map_meta(DATA, map_id)
            lit = lambda v: f"CAST({float(v)!r} AS DOUBLE)"
            fills = [("frame_pose", f"SELECT 0 AS frame_id, 0 AS tic, {lit(pose[0])} AS px, {lit(pose[1])} AS py, "
                                    f"{lit(pose[2])} AS pz, {lit(pose[3])} AS angle")]
            fills = [(name, lambda sql=sql: self.spark.sql(sql)) for name, sql in fills]
            for name in engine.STATE_TABLES:
                path = (paths if self.store is None else self.store.paths).get(name)
                if not path or self.loaded.get(name) == path:
                    continue
                if self.store is None:
                    sql = f"SELECT 0 AS tic, * FROM parquet.`{path}` WHERE map_id = {map_id}"
                    fills.append((name, lambda sql=sql: self.spark.sql(sql)))
                else:
                    # Uploaded from the table the store holds, not read back.
                    rows = self.store.arrow(name)
                    rows = rows.filter(pc.equal(rows["map_id"], map_id))
                    fills.append((name, lambda rows=rows: engine.upload(self.spark, rows).selectExpr("0 AS tic", "*")))
                self.loaded[name] = path
            # Independent round trips: at once.
            list(self.pool.map(lambda f: f[1]().createOrReplaceTempView(f[0]), fills))
            key = (map_id, player, skill)
            if key not in self.frames:
                params = dict(engine.CONSTANTS, map_id=map_id, player=player, skill=skill,
                              skill_bit=1 if skill <= 1 else 2 if skill == 2 else 4,
                              px="px", py="py", pz="pz", vr="vr",
                              sky_tex_id=self.meta["sky_tex_id"], sky_w=self.meta["sky_w"],
                              tic_lo=0, tic_hi=0, frames="frame_pose")
                self.frames[key] = self.spark.sql(expand(self.sql, params))
            table = engine.fetch(self.frames[key])
            rgb = table.column("rgb").to_numpy().astype(np.uint32)
            if len(rgb) != 64000:
                raise RuntimeError(f"frame has {len(rgb)} pixels, not 64000")
            out = np.empty((64000, 3), dtype=np.uint8)
            out[:, 0], out[:, 1], out[:, 2] = rgb >> 16, (rgb >> 8) & 255, rgb & 255
            return out.tobytes()


class RenderProcess:
    """ReusedRenderer in a process of its own. In the client's process the
    render thread and the game contend for one interpreter; here a frame is a
    request over a pipe: the pose and the state tables' current files (written
    out first), and back the 192,000 bytes of the frame."""

    def __init__(self, store):
        import multiprocessing
        context = multiprocessing.get_context("spawn")
        self.conn, child = context.Pipe()
        self.process = context.Process(
            target=_serve, args=(child, os.environ.get("SAIL_REMOTE", "sc://localhost:50051"), str(DATA)),
            daemon=True)
        self.process.start()
        self.store = store
        self.lock = threading.Lock()

    def frame(self, map_id, player, skill, pose):
        paths = {n: self.store.paths[n] for n in engine.STATE_TABLES if n in self.store.paths}
        for path in paths.values():
            self.store.wait(path)
        with self.lock:
            self.conn.send((map_id, player, skill, tuple(float(v) for v in pose), paths))
            ok, value = self.conn.recv()
        if not ok:
            raise RuntimeError(f"render process: {value}")
        return value


def _serve(conn, url, data):
    os.environ["SAIL_REMOTE"] = url
    global DATA
    DATA = Path(data)
    renderer = ReusedRenderer(None)
    while True:
        try:
            request = conn.recv()
        except EOFError:
            return
        try:
            conn.send((True, renderer.frame(*request)))
        except Exception as exc:  # noqa: BLE001 -- reported to the caller
            conn.send((False, repr(exc)))


def register(b):
    renderer = {}

    def get():
        if "r" not in renderer:
            if os.environ.get("SAILDOOM_RENDER_REUSE", "1") != "1":
                kind = Renderer
            elif os.environ.get("SAILDOOM_RENDER_PROCESS", "1") == "1":
                kind = RenderProcess
            else:
                kind = ReusedRenderer
            renderer["r"] = kind(b.store)
        return renderer["r"]

    @b.handler("doom_render_frame")
    def render(m, p, skill, x, y, z, angle):
        if os.environ.get("SAILDOOM_BLACK_FRAMES") == "1":  # to measure the game without the renderer
            return [(bytes(320 * 200 * 3),)]
        return [(get().frame(int(m), int(p), int(skill), (x, y, z, angle)),)]

    # The folded form is prepared per connection for one (map, player, skill);
    # backend.install hands the handler that context ahead of the pose.
    @b.handler("doom_render_frame_folded")
    def render_folded(m, p, skill, x, y, z, angle):
        return render(m, p, skill, x, y, z, angle)
