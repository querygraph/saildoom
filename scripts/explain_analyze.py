"""EXPLAIN ANALYZE one frame and list the operators by elapsed compute time."""
import json, re, sys
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
rows = s.sql("EXPLAIN ANALYZE " + q).collect()
text = "\n".join(str(v) for r in rows for v in r)
out = ROOT / "data/explain_analyze.txt"
out.write_text(text)
def ms(m):
    v, unit = float(m.group(1)), m.group(2)
    return v * {"ns": 1e-6, "µs": 1e-3, "us": 1e-3, "ms": 1, "s": 1000}[unit]
ops = []
for line in text.splitlines():
    m = re.search(r"elapsed_compute=([\d.]+)(ns|µs|us|ms|s)\b", line)
    if m:
        ops.append((ms(m), line.strip()[:200]))
for t, line in sorted(ops, reverse=True)[:25]:
    print(f"{t:9.1f} ms  {line}")
print(f"{len(ops)} operators with metrics; full text in {out}")
