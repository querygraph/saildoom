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
from pathlib import Path

from .. import engine

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


def register(b):
    renderer = {}

    def get():
        if "r" not in renderer:
            renderer["r"] = Renderer(b.store)
        return renderer["r"]

    @b.handler("doom_render_frame")
    def render(m, p, skill, x, y, z, angle):
        return [(get().frame(int(m), int(p), int(skill), (x, y, z, angle)),)]

    # The folded form is prepared per connection for one (map, player, skill);
    # backend.install hands the handler that context ahead of the pose.
    @b.handler("doom_render_frame_folded")
    def render_folded(m, p, skill, x, y, z, angle):
        return render(m, p, skill, x, y, z, angle)
