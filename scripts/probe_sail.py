"""Check the Spark SQL features SailDoom relies on, and Sail's round-trip cost."""

import time

from saildoom import engine

s = engine.connect()


def q(label, sql):
    t = time.perf_counter()
    try:
        r = s.sql(sql).collect()
        print(f"OK  {label}: {(time.perf_counter() - t) * 1000:.1f} ms -> {r[:3]}")
    except Exception as e:
        print(f"ERR {label}: {str(e).splitlines()[0][:240]}")


for i in range(5):
    q("trivial", "SELECT 1")
q("explode seq", "SELECT explode(CASE WHEN 1<=3 THEN sequence(1,3) END) AS x")
q("explode null", "SELECT explode(CASE WHEN 3<=1 THEN sequence(3,1) END) AS x")
q("shift", "SELECT shiftleft(CAST(1 AS BIGINT), 40), shiftright(CAST(1024 AS BIGINT), 8), CAST(7 AS BIGINT) | 8")
q("bround", "SELECT bround(2.5D), bround(3.5D), bround(-2.5D), CAST(bround(2.5D) AS INT)")
q("div", "SELECT 7 DIV 2, -7 DIV 2, -7 % 2, CAST(-7 AS BIGINT) % 2")
q("bool_and", "SELECT bool_and(x) FROM VALUES (true),(false) AS t(x)")
q("max_by", "SELECT max_by(a,b) FROM VALUES (1,2),(3,1) AS t(a,b)")
q("anti join", "SELECT * FROM VALUES (1),(2) AS a(x) LEFT ANTI JOIN VALUES (1) AS b(x) ON a.x=b.x")
q("window rows", "SELECT x, MAX(x) OVER (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) FROM VALUES (1),(2),(3) AS t(x)")
q("is distinct", "SELECT 'a' IS DISTINCT FROM NULL")
q("greatest nulls", "SELECT greatest(0.0D, NULL), least(1, NULL)")
q("double literal", "SELECT 1e-3D, 2.0D/3, 1e7D")
q("lpad ascii", "SELECT lpad(CAST(ascii('A') AS STRING),3,'0'), substring('abc',2,1)")
q("full outer", "SELECT * FROM VALUES (1,1) AS a(x,y) FULL OUTER JOIN VALUES (2,2) AS b(x,y) ON a.x=b.x AND a.y=b.y")
q("left join on bool", "SELECT * FROM VALUES (true) AS a(f) LEFT JOIN VALUES (5) AS b(w) ON a.f")
q("int*bigint literal", "SELECT 3 * 2654435761")

df = s.sql("SELECT id FROM range(10)")
for label, fn in (("cache", lambda: df.cache().count()),
                  ("localCheckpoint", lambda: df.localCheckpoint().count())):
    t = time.perf_counter()
    try:
        r = fn()
        print(f"OK  {label}: {(time.perf_counter() - t) * 1000:.1f} ms -> {r}")
    except Exception as e:
        print(f"ERR {label}: {str(e).splitlines()[0][:300]}")
q("CACHE TABLE", "CACHE TABLE tt AS SELECT id FROM range(5)")
q("read cached", "SELECT count(*) FROM tt")
