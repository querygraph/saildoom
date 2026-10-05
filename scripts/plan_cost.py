"""Split one frame's time into analysis, planning and execution."""
import json, statistics, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from saildoom import engine
from saildoom.sqlmacro import expand, strip_comments

ref = ROOT / "reference/cedar-e1m1"
meta = json.loads((ref / "timings.json").read_text())
pose = next(p["pose"] for p in json.loads((ref / "poses.json").read_text()) if p["tic"] == 350)
sql_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "sql/renderer.sql"
s = engine.connect()
engine.load_map(s, ROOT / "data/freedoom1", meta["map_id"])
q = expand(strip_comments(sql_path.read_text()),
           engine.frame_params(meta["map_id"], meta["player_thing_id"], meta["skill"], pose,
                               engine.map_meta(ROOT / "data/freedoom1", meta["map_id"])))
def med(fn, n=5):
    fn(); ts = []
    for _ in range(n):
        t = time.perf_counter(); fn(); ts.append((time.perf_counter() - t) * 1000)
    return statistics.median(ts)
a = med(lambda: s.sql(q).schema)
p = med(lambda: s.sql(q).limit(0).collect())
f = med(lambda: s.sql(q).toArrow())
print(f"analyze {a:.1f} ms | analyze+optimize+plan (limit 0) {p:.1f} ms | full frame {f:.1f} ms")
print(f"=> planning ~{p:.0f} ms, execution ~{f - p:.0f} ms")
