"""The client's per-tic queries, computed from the tables the store holds.

sql/client/game_tick_finish.sql, sound_events.sql, sound_loops.sql and
camera_pose.sql run around every tic. On Sail each is planned afresh (10 to
30 ms), and every table they read was just written from the tic's Arrow
result, so here they are evaluated over those tables directly, with SQL's
semantics kept where they show: three-valued AND under COALESCE, real
(single-precision) subtraction before a double multiply, and the same libm
calls (pow, sqrt, atan2, sin) Sail makes.
"""

import math

import numpy as np
import pyarrow.compute as pc


def rows(store, table, **eq):
    """The rows of `table` whose columns equal the given values, as dicts."""
    t = store.arrow(table)
    mask = None
    for col, value in eq.items():
        m = pc.equal(t[col], value)
        mask = m if mask is None else pc.and_(mask, m)
    return (t.filter(mask) if mask is not None else t).to_pylist()


def sql_and(*values):
    """SQL's AND: false if any is false, else NULL if any is NULL, else true."""
    if any(v is False for v in values):
        return False
    if any(v is None for v in values):
        return None
    return True


def coalesce_false(v):
    return False if v is None else v


def tick_finish(store, map_id, player):
    commands = rows(store, "game_tic_commands", map_id=map_id, player_thing_id=player)
    if not commands:
        return []
    c = commands[0]
    line_defs = {d["special"]: d for d in rows(store, "line_special_defs")}

    # cross_exit: BOOL_OR over the player's cross events' line specials.
    specials = {ld["id"]: ld["special"] for ld in rows(store, "linedefs", map_id=map_id)}
    cross, cross_secret = [], []
    for e in rows(store, "line_special_events", map_id=map_id, player_thing_id=player):
        if e["trigger_type"] != "cross" or e["line_id"] not in specials:
            continue
        d = line_defs.get(specials[e["line_id"]])
        if d is not None:
            cross.append(d["is_exit"])
            cross_secret.append(d["secret_exit"])

    def bool_or(values):
        if any(v is True for v in values):
            return True
        return False if any(v is False for v in values) else None

    players = rows(store, "player_state", map_id=map_id, player_thing_id=player)
    # sector_exit: BOOL_OR(health <= exit_at_health) over the player's sector.
    sector_values = []
    for ps in players:
        for s in rows(store, "sectors", map_id=map_id, id=ps["sector_id"]):
            sd = next(iter(rows(store, "sector_special_defs", special=s["special"])), None)
            limit = None if sd is None else sd["exit_at_health"]
            sector_values.append(None if limit is None or ps["health"] is None else ps["health"] <= limit)

    # boss_exit: a map whose exit_level bosses are all dead.
    boss = 0
    names = {m["name"] for m in rows(store, "maps", map_id=map_id)}
    health = {h["thing_id"]: h["alive"] for h in rows(store, "thing_health", map_id=map_id)}
    for ba in rows(store, "boss_actions", action="exit_level"):
        if ba["map_name"] not in names:
            continue
        alive = [health[t["id"]] for t in rows(store, "things", map_id=map_id, type=ba["boss_type"])
                 if t["id"] in health]
        if alive:
            boss = max(boss, 1 if sum(1 for a in alive if a) == 0 else 0)

    screens = rows(store, "screen_state")
    uses = rows(store, "line_use_results", map_id=map_id, player_thing_id=player) or [None]
    traces = rows(store, "tic_trace", map_id=map_id, player_thing_id=player) or [None]
    out = []
    for ss in screens:
        for ps in players:
            for ur in uses:
                usd = line_defs.get(ur["special"]) if ur is not None else None
                for tt in traces:
                    locked = coalesce_false(ur["locked"] if ur else None)
                    key = usd["key_required"] if usd is not None else None
                    out.append((
                        ps["position_x"], ps["position_y"], ps["view_angle"], ps["view_z"], ps["alive"],
                        locked,
                        (None if key is None else str(key)) if locked else None,
                        coalesce_false(sql_and(c["use_requested"], ur["eligible"] if ur else None,
                                               usd["is_exit"] if usd else None)),
                        coalesce_false(sql_and(c["use_requested"], ur["eligible"] if ur else None,
                                               usd["secret_exit"] if usd else None)),
                        coalesce_false(bool_or(cross)), coalesce_false(bool_or(cross_secret)),
                        coalesce_false(bool_or(sector_values)), boss == 1,
                        ps["power_map"],
                        tt["stages"] if tt is not None and tt["stages"] is not None else 0,
                        ss["screen"], ss["demo_playing"] is not None,
                    ))
    return out


def listener(store, map_id, player):
    t = rows(store, "things", map_id=map_id, id=player)
    if not t:
        return None
    t = t[0]
    return float(t["x"]), float(t["y"]), math.radians(float(t["angle"]))


def placed(name_key, sound, source_x, source_y, lis):
    px, py, angle = lis
    if source_x is None:
        distance, pan = 0.0, 0.0
    else:
        dx, dy = float(source_x) - px, float(source_y) - py
        distance = math.sqrt(math.pow(dx, 2) + math.pow(dy, 2))
        pan = math.sin(math.atan2(dy, dx) - angle)
    if distance <= 160.0:
        volume = 1.0
    elif distance >= 1200.0:
        volume = 0.0
    else:
        volume = 1.0 - (distance - 160.0) / 1040.0
    return (name_key, sound, volume, max(-1.0, min(1.0, pan)))


def sound_events(store, map_id, player, map_id2, after):
    lis = listener(store, map_id, player)
    if lis is None:
        return []
    events = sorted((e for e in rows(store, "sound_events", map_id=map_id2) if e["event_id"] > after),
                    key=lambda e: e["event_id"])
    return [placed(e["event_id"], e["sound_name"], e["source_x"], e["source_y"], lis) for e in events]


def sound_loops(store, map_id, player):
    lis = listener(store, map_id, player)
    if lis is None:
        return []
    origins = {o["sector_id"]: o for o in rows(store, "sector_sound_origins", map_id=map_id)}
    loops = []
    for sm in rows(store, "sector_movers", map_id=map_id):
        o = origins.get(sm["sector_id"])
        if sm["direction"] in (-1, 1) and o is not None:
            loops.append((f"mover:{sm['sector_id']}", "DSSTNMOV", o["x"], o["y"]))
    for pw in rows(store, "player_weapons", map_id=map_id, player_thing_id=player):
        if pw["current_weapon"] == 8 and pw["state"] is not None and pw["state"] != "down":
            loops.append((f"chainsaw:{player}", "DSSAWFUL" if pw["state"] == "fire" else "DSSAWIDL", None, None))
    return sorted((placed(k, n, x, y, lis) for k, n, x, y in loops), key=lambda r: r[0])


def camera_pose(store, map_id, player, alpha):
    a = max(0.0, min(1.0, float(alpha)))
    out = []
    for ps in rows(store, "player_state", map_id=map_id, player_thing_id=player):
        f = np.float32
        x = float(ps["previous_x"]) + float(f(ps["position_x"]) - f(ps["previous_x"])) * a
        y = float(ps["previous_y"]) + float(f(ps["position_y"]) - f(ps["previous_y"])) * a
        z = float(ps["previous_view_z"]) + float(f(ps["view_z"]) - f(ps["previous_view_z"])) * a
        a0 = float(ps["previous_view_angle"])
        d = float(ps["view_angle"]) - float(ps["previous_view_angle"]) + 180.0
        turn = (d - 360.0 * math.floor(d / 360.0)) - 180.0
        angle = a0 + turn * a - 360.0 * math.floor((a0 + turn * a) / 360.0)
        out.append((x, y, z, angle))
    return out
