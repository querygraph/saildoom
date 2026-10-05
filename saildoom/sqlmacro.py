"""Expand the few macros the Spark SQL port uses in place of Postgres features.

  GS(a, b)               generate_series(a, b): one row per integer, none when
                         a > b (Spark's sequence() would count down instead)
  PGINT(x)               Postgres' float-to-integer cast: round half to even
  DOOM_LIGHT_INDEX(l, e, a), DOOM_LIGHT_SCALE(d), DOOM_LIGHT_ZDEPTH(d)
                         SQLDoom's 43_render_light.sql functions, inlined
  PRANDOM(actor, tic, use)
                         00_prandom.sql's doom_prandom: Doom's rndtable at an
                         index hashed from the three arguments
  ${name}                a parameter, folded in as a literal
"""

import re

# Doom's rndtable (m_random.c), as 00_prandom.sql spells it.
RNDTABLE = [0, 8, 109, 220, 222, 241, 149, 107, 75, 248, 254, 140, 16, 66, 74, 21, 211, 47, 80, 242, 154, 27, 205, 128, 161, 89, 77, 36, 95, 110, 85, 48, 212, 140, 211, 249, 22, 79, 200, 50, 28, 188, 52, 140, 202, 120, 68, 145, 62, 70, 184, 190, 91, 197, 152, 224, 149, 104, 25, 178, 252, 182, 202, 182, 141, 197, 4, 81, 181, 242, 145, 42, 39, 227, 156, 198, 225, 193, 219, 93, 122, 175, 249, 0, 175, 143, 70, 239, 46, 246, 163, 53, 163, 109, 168, 135, 2, 235, 25, 92, 20, 145, 138, 77, 69, 166, 78, 176, 173, 212, 166, 113, 94, 161, 41, 50, 239, 49, 111, 164, 70, 60, 2, 37, 171, 75, 136, 156, 11, 56, 42, 146, 138, 229, 73, 146, 77, 61, 98, 196, 135, 106, 63, 197, 195, 86, 96, 203, 113, 101, 170, 247, 181, 113, 80, 250, 108, 7, 255, 237, 129, 226, 79, 107, 112, 166, 103, 241, 24, 223, 239, 120, 198, 58, 60, 82, 128, 3, 184, 66, 143, 224, 145, 224, 81, 206, 163, 45, 63, 90, 168, 114, 59, 33, 159, 95, 28, 139, 123, 98, 125, 196, 15, 70, 194, 253, 54, 14, 109, 226, 71, 17, 161, 93, 186, 87, 244, 138, 20, 52, 123, 251, 26, 36, 17, 46, 52, 231, 232, 76, 31, 221, 84, 37, 216, 165, 212, 106, 197, 242, 98, 43, 39, 175, 254, 145, 190, 84, 118, 222, 187, 136, 120, 163, 236, 249]


def _prandom(actor, tic, use):
    h = (f"((ABS(CAST({actor} AS BIGINT)) * 2654435761 + ABS(CAST({tic} AS BIGINT)) * 2246822519"
         f" + ABS(CAST({use} AS BIGINT)) * 3266489917) % 4294967296)")
    index = f"(((({h} ^ ({h} DIV 32768)) * 40503 % 4294967296) DIV 256) % 256)"
    return f"element_at(array({', '.join(map(str, RNDTABLE))}), CAST({index} AS INT) + 1)"


MACROS = {
    "GS": lambda a, b: (
        f"explode(CASE WHEN ({a}) <= ({b}) "
        f"THEN sequence(CAST({a} AS INT), CAST({b} AS INT)) END)"),
    "PGINT": lambda x: f"CAST(bround({x}) AS INT)",
    "PRANDOM": _prandom,
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
