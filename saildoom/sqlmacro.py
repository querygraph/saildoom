"""Expand the few macros the Spark SQL port uses in place of Postgres features.

  GS(a, b)               generate_series(a, b): one row per integer, none when
                         a > b (Spark's sequence() would count down instead)
  PGINT(x)               Postgres' float-to-integer cast: round half to even
  DOOM_LIGHT_INDEX(l, e, a), DOOM_LIGHT_SCALE(d), DOOM_LIGHT_ZDEPTH(d)
                         SQLDoom's 43_render_light.sql functions, inlined
  ${name}                a parameter, folded in as a literal
"""

import re

MACROS = {
    "GS": lambda a, b: (
        f"explode(CASE WHEN ({a}) <= ({b}) "
        f"THEN sequence(CAST({a} AS INT), CAST({b} AS INT)) END)"),
    "PGINT": lambda x: f"CAST(bround({x}) AS INT)",
    "DOOM_LIGHT_INDEX": lambda light, extra, att: (
        f"GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, "
        f"CAST(FLOOR(CAST({light} AS DOUBLE) / 16.0D) AS INT) + ({extra})))) * 4"
        f" - ({att})))"),
    "DOOM_LIGHT_SCALE": lambda depth: (
        f"CAST(FLOOR(LEAST(47.0D, GREATEST(0.0D, "
        f"2560.0D / NULLIF(CAST({depth} AS DOUBLE), 0.0D))) / 2.0D) AS INT)"),
    "DOOM_LIGHT_ZDEPTH": lambda depth: (
        f"CAST(FLOOR(80.0D / (LEAST(127, "
        f"CAST(FLOOR(CAST({depth} AS DOUBLE) / 16.0D) AS INT)) + 1)) AS INT)"),
}

_CALL = re.compile(r"\b(" + "|".join(MACROS) + r")\s*\(")


def _split_args(text):
    """Split a macro's argument text at top-level commas."""
    args, depth, start, quote = [], 0, 0, None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch == "'":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(text[start:i].strip())
            start = i + 1
    args.append(text[start:].strip())
    return args


def expand(sql, params=None):
    """Expand every macro (innermost arguments first) and fold parameters."""
    if params:
        for name, value in params.items():
            sql = sql.replace("${" + name + "}", repr(value)
                              if isinstance(value, float) else str(value))
    while True:
        m = _CALL.search(sql)
        if not m:
            break
        depth, i = 1, m.end()
        while depth:
            if sql[i] == "(":
                depth += 1
            elif sql[i] == ")":
                depth -= 1
            i += 1
        args = [expand(a) for a in _split_args(sql[m.end():i - 1])]
        sql = sql[:m.start()] + MACROS[m.group(1)](*args) + sql[i:]
    if "${" in sql:
        raise ValueError("unfolded parameter: " + sql[sql.index("${"):][:40])
    return sql


def strip_comments(sql):
    return re.sub(r"--[^\n]*", "", sql)
