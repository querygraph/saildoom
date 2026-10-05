"""The level exit, intermission and finale (06_finish_level, 33_intermission,
36_finale, 41_flow's doom_level_exit and doom_after_intermission), demos
(41_flow), cheats (38_cheats, 07_cheat_arsenal), and weapon selection
(client/weapon_slot.sql, client/weapon_cycle.sql)."""

from pathlib import Path

from ..backend import literal, pg
from ..sqlmacro import strip_comments

VOID = [("",)]
CLIENT = Path("/Users/alexy/src/saildoom-ref/sqldoom/sql/client")
CODES = ("IDSPISPOPD", "IDCHOPPERS", "IDBEHOLDV", "IDBEHOLDS", "IDBEHOLDI", "IDBEHOLDR",
         "IDBEHOLDA", "IDBEHOLDL", "IDMYPOS", "IDCLIP", "IDKFA", "IDDQD", "IDFA")


def register(b):
    s = b.store

    def one(sql):
        rows = s.query(sql)
        return rows[0] if rows else None

    # ------------------------------------------------------------ level exit
    def finish_level(m, p, secret):
        b.update("level_stats", {
            "level_tics": "ps.level_tics", "kills": "k.value", "items": "i.value", "secrets": "x.value",
            "completed": "TRUE", "secret_exit": literal(bool(secret))},
            f"t.map_id = {m} AND t.player_thing_id = {p} AND ps.map_id IS NOT NULL",
            joins=f"""LEFT JOIN (SELECT * FROM player_state WHERE map_id = {m} AND player_thing_id = {p}) ps ON TRUE
              CROSS JOIN (SELECT CAST(count(*) AS INT) AS value FROM thing_health h
                          JOIN things t2 ON t2.map_id = h.map_id AND t2.id = h.thing_id
                          JOIN thing_combat_defs d ON d.thing_type = t2.type AND d.counts_kill
                          WHERE h.map_id = {m} AND NOT h.alive) k
              CROSS JOIN (SELECT CAST(count(*) AS INT) AS value FROM picked_up_items pi
                          JOIN things t3 ON t3.map_id = pi.map_id AND t3.id = pi.thing_id
                          JOIN pickup_defs d ON d.thing_type = t3.type AND d.counts_item
                          WHERE pi.map_id = {m}) i
              CROSS JOIN (SELECT CAST(count(*) AS INT) AS value FROM level_secret_discoveries
                          WHERE map_id = {m} AND player_thing_id = {p}) x""")

    def intermission_begin(m, p, secret):
        cur = one(f"SELECT name FROM maps WHERE map_id = {m}")
        ep, lv = int(cur["name"][1]), int(cur["name"][3])
        if secret:
            nxt = 9
        elif lv == 9:
            nxt = {1: 4, 2: 6, 3: 7}.get(ep, 3)
        elif lv == 8:
            nxt = None
        else:
            nxt = lv + 1
        nid = None
        if nxt is not None:
            row = one(f"SELECT map_id FROM maps WHERE name = 'E{ep}M{nxt}'")
            nid = row["map_id"] if row else None
        st = one(f"SELECT * FROM level_stats WHERE map_id = {m} AND player_thing_id = {p}")
        if st is not None:
            pct = lambda a, b: min(100, a * 100 // b) if b > 0 else 0
            b.update("screen_state", {
                "screen": "'intermission'", "cursor_index": "0", "inter_episode": str(ep),
                "inter_level": str(lv), "inter_next": str(nxt if nxt is not None else lv),
                "next_map_id": literal(nid), "secret_exit": literal(bool(secret)),
                "tgt_kills": str(pct(st["kills"], st["total_kills"])),
                "tgt_items": str(pct(st["items"], st["total_items"])),
                "tgt_secrets": str(pct(st["secrets"], st["total_secrets"])),
                "tgt_time": str(int(st["level_tics"] // 35)),
                "tgt_par": str(int(st["par_tics"] // 35) if st["par_tics"] is not None else 0),
                "kills_pct": "0", "items_pct": "0", "secrets_pct": "0", "time_secs": "0", "par_secs": "0",
                "sp_state": "1", "cnt_pause": "35", "accelerate": "FALSE"}, "t.id = 0")
        row = one("SELECT next_map_id FROM screen_state WHERE id = 0")
        return -1 if row is None or row["next_map_id"] is None else row["next_map_id"]

    @b.handler("doom_level_exit_call")
    def level_exit(m, p, secret):
        finish_level(m, p, secret)
        return [(intermission_begin(m, p, secret),)]

    @b.handler("doom_level_finish")
    def finish_call(m, p, secret):
        finish_level(m, p, secret)
        return VOID

    @b.handler("doom_intermission_begin_call")
    def begin_call(m, p, secret):
        return [(intermission_begin(m, p, secret),)]

    @b.handler("doom_intermission_accel_call")
    def accelerate():
        b.update("screen_state", {"accelerate": "TRUE"}, "t.id = 0")
        return [(0,)]

    @b.handler("doom_intermission_tic_call")
    def intermission_tic():
        pre = one("SELECT accelerate, sp_state FROM screen_state WHERE id = 0")
        acc = "(t.accelerate AND t.sp_state <> 10)"
        b.update("screen_state", {
            "kills_pct": f"CASE WHEN {acc} THEN t.tgt_kills WHEN t.sp_state = 2 THEN LEAST(t.tgt_kills, t.kills_pct + 2) ELSE t.kills_pct END",
            "items_pct": f"CASE WHEN {acc} THEN t.tgt_items WHEN t.sp_state = 4 THEN LEAST(t.tgt_items, t.items_pct + 2) ELSE t.items_pct END",
            "secrets_pct": f"CASE WHEN {acc} THEN t.tgt_secrets WHEN t.sp_state = 6 THEN LEAST(t.tgt_secrets, t.secrets_pct + 2) ELSE t.secrets_pct END",
            "time_secs": f"CASE WHEN {acc} THEN t.tgt_time WHEN t.sp_state = 8 THEN LEAST(t.tgt_time, t.time_secs + 3) ELSE t.time_secs END",
            "par_secs": f"CASE WHEN {acc} THEN t.tgt_par WHEN t.sp_state = 8 THEN LEAST(t.tgt_par, t.par_secs + 3) ELSE t.par_secs END",
            "sp_state": f"""CASE WHEN {acc} THEN 10
                WHEN t.sp_state = 2 AND t.kills_pct + 2 >= t.tgt_kills THEN 3
                WHEN t.sp_state = 4 AND t.items_pct + 2 >= t.tgt_items THEN 5
                WHEN t.sp_state = 6 AND t.secrets_pct + 2 >= t.tgt_secrets THEN 7
                WHEN t.sp_state = 8 AND t.time_secs + 3 >= t.tgt_time AND t.par_secs + 3 >= t.tgt_par THEN 10
                WHEN t.sp_state IN (1, 3, 5, 7, 9) AND t.cnt_pause <= 1 THEN t.sp_state + 1
                ELSE t.sp_state END""",
            "cnt_pause": """CASE WHEN t.sp_state IN (1, 3, 5, 7, 9) AND t.cnt_pause > 1 THEN t.cnt_pause - 1
                WHEN t.sp_state IN (1, 3, 5, 7, 9) THEN 35 ELSE t.cnt_pause END""",
            "accelerate": "FALSE"}, "t.id = 0")
        st = one("SELECT screen, sp_state FROM screen_state WHERE id = 0")
        result = "done" if st["screen"] != "intermission" else "waiting" if st["sp_state"] >= 10 else "counting"
        if pre["accelerate"] and pre["sp_state"] >= 10:
            b.update("screen_state", {"screen": "'game'", "sp_state": "0", "cnt_pause": "0"}, "t.id = 0")
            result = "done"
        return [(result,)]

    @b.raw("SELECT sp_state,kills_pct,items_pct,secrets_pct,time_secs,par_secs FROM screen_state WHERE id=0")
    def figures():
        return [tuple(r) for r in s.query(
            "SELECT sp_state, kills_pct, items_pct, secrets_pct, time_secs, par_secs FROM screen_state WHERE id = 0")]

    # ------------------------------------------------------------ finale
    def finale_begin(ep):
        found = one(f"SELECT count(*) AS n FROM finale_defs WHERE episode = {ep}")["n"]
        if found:
            b.update("screen_state", {"screen": "'finale'", "finale_episode": str(ep), "finale_count": "0",
                                      "finale_stage": "0", "cursor_index": "0"}, "t.id = 0")
        return found

    @b.handler("doom_finale_begin_call")
    def finale_begin_call(ep):
        return [(finale_begin(ep),)]

    @b.handler("doom_after_intermission_call")
    def after_intermission(m):
        row = one(f"""SELECT s.next_map_id, CAST(substring(mm.name, 2, 1) AS INT) AS ep
                      FROM screen_state s CROSS JOIN maps mm WHERE s.id = 0 AND mm.map_id = {m}""")
        nxt = -1 if row is None or row["next_map_id"] is None else row["next_map_id"]
        ep = 1 if row is None else row["ep"]
        if nxt >= 0:
            return [(f"level:{nxt}",)]
        if finale_begin(ep):
            return [("finale",)]
        first = one("SELECT MIN(map_id) AS f FROM maps")["f"]
        return [(f"level:{first}",)]

    @b.handler("doom_finale_tic_call")
    def finale_tic():
        b.update("screen_state", {
            "finale_count": "CASE WHEN d.advance THEN 0 ELSE t.finale_count + 1 END",
            "finale_stage": "CASE WHEN d.advance THEN 1 ELSE t.finale_stage END"},
            "t.id = 0 AND d.advance IS NOT NULL",
            joins="""LEFT JOIN (SELECT s2.id, (s2.finale_stage = 0 AND s2.finale_count + 1 > length(f.story_text) * 3 + 250) AS advance
                                FROM screen_state s2 JOIN finale_defs f ON f.episode = s2.finale_episode
                                WHERE s2.id = 0 AND s2.screen = 'finale') d ON d.id = t.id""")
        st = one("SELECT screen, finale_stage FROM screen_state WHERE id = 0")
        return [("done" if st["screen"] != "finale" else "text" if st["finale_stage"] == 0 else "picture",)]

    @b.handler("doom_finale_advance_call")
    def finale_advance():
        st = one("""SELECT s.finale_stage AS st, s.finale_count AS c, COALESCE(length(f.story_text), 0) * 3 + 10 AS t
                    FROM screen_state s LEFT JOIN finale_defs f ON f.episode = s.finale_episode WHERE s.id = 0""")
        result = "text"
        if st["st"] != 0:
            b.update("screen_state", {"screen": "'title'", "finale_stage": "0", "finale_count": "0",
                                      "finale_episode": "NULL", "cursor_index": "0"}, "t.id = 0")
            result = "done"
        if st["st"] == 0 and st["c"] < st["t"]:
            b.update("screen_state", {"finale_count": str(st["t"])}, "t.id = 0")
            result = "text"
        if st["st"] == 0 and st["c"] >= st["t"]:
            b.update("screen_state", {"finale_stage": "1", "finale_count": "0"}, "t.id = 0")
            result = "picture"
        return [(result,)]

    @b.raw("SELECT finale_stage,finale_count FROM screen_state WHERE id=0")
    def finale_phase():
        return [tuple(r) for r in s.query("SELECT finale_stage, finale_count FROM screen_state WHERE id = 0")]

    # ------------------------------------------------------------ weapons
    @b.handler("doom_select_weapon_slot")
    def weapon_slot(m, p, slot):
        return [tuple(r) for r in s.query(pg(strip_comments((CLIENT / "weapon_slot.sql").read_text()), (m, p, slot)))]

    @b.handler("doom_cycle_weapon")
    def weapon_cycle(m, p, step):
        return [tuple(r) for r in s.query(pg(strip_comments((CLIENT / "weapon_cycle.sql").read_text()), (m, p, step)))]

    # ------------------------------------------------------------ demos
    @b.handler("doom_demo_header")
    def demo_header(did):
        return [tuple(r) for r in s.query(pg(strip_comments((CLIENT / "demo_header.sql").read_text()), (did,)))]

    @b.handler("doom_demo_begin_call")
    def demo_begin(name, m, p, skill):
        row = one(f"SELECT demo_id FROM demos WHERE name = {literal(name)}")
        did = row["demo_id"] if row else (one("SELECT COALESCE(MAX(demo_id), 0) + 1 AS i FROM demos")["i"])
        b.replace_rows("demo_tics", f"demo_id = {did}", "SELECT * FROM demo_tics WHERE FALSE")
        b.replace_rows("demos", f"demo_id = {did}", f"""SELECT {did} AS demo_id, {literal(name)} AS name, {m} AS map_id,
                       {p} AS player_thing_id, {skill} AS skill, 0 AS tic_count, current_timestamp() AS recorded_at""")
        b.update("screen_state", {"demo_recording": str(did), "demo_playing": "NULL", "demo_tic": "0"}, "t.id = 0")
        return [(did,)]

    @b.handler("doom_demo_play_call")
    def demo_play(name):
        row = one(f"SELECT demo_id FROM demos WHERE name = {literal(name)}")
        did = row["demo_id"] if row else -1
        if did >= 0:
            b.update("screen_state", {"demo_playing": str(did), "demo_recording": "NULL", "demo_tic": "0"}, "t.id = 0")
        return [(did,)]

    @b.handler("doom_demo_stop_call")
    def demo_stop():
        b.update("screen_state", {"demo_playing": "NULL", "demo_recording": "NULL", "demo_tic": "0"}, "t.id = 0")
        return VOID

    # ------------------------------------------------------------ cheats
    def arsenal(m, p):
        b.replace_rows("player_weapon_owned", f"map_id = {m} AND player_thing_id = {p}", f"""
            SELECT {m} AS map_id, {p} AS player_thing_id, w AS weapon_id FROM (SELECT explode(sequence(1, 8)) AS w)""")
        caps = {a: f"(SELECT CASE WHEN t.backpack THEN backpack_cap ELSE cap END FROM ammo_defs WHERE ammo_type = '{a}')"
                for a in ("bullets", "shells", "rockets", "cells")}
        b.update("player_state", {f"ammo_{a}": f"CASE WHEN t.backpack THEN ad.{a}_b ELSE ad.{a}_c END" for a in caps},
                 f"t.map_id = {m} AND t.player_thing_id = {p}",
                 joins="CROSS JOIN (SELECT " + ", ".join(
                     f"MAX(CASE WHEN ammo_type = '{a}' THEN cap END) AS {a}_c, "
                     f"MAX(CASE WHEN ammo_type = '{a}' THEN backpack_cap END) AS {a}_b" for a in caps) + " FROM ammo_defs) ad")

    def cheat(m, p, code):
        code = code.upper()
        where = f"t.map_id = {m} AND t.player_thing_id = {p}"
        message = ""
        ps = lambda col: one(f"SELECT {col} FROM player_state WHERE map_id = {m} AND player_thing_id = {p}")[col]
        if code == "IDDQD":
            b.update("player_state", {"god_mode": "NOT t.god_mode"}, where)
            message = "Degreelessness Mode ON" if ps("god_mode") else "Degreelessness Mode OFF"
        if code in ("IDCLIP", "IDSPISPOPD"):
            b.update("player_state", {"noclip": "NOT t.noclip"}, where)
            message = "No Clipping Mode ON" if ps("noclip") else "No Clipping Mode OFF"
        if code in ("IDFA", "IDKFA"):
            arsenal(m, p)
            message = "Ammo (no keys) Added"
        if code == "IDKFA":
            b.update("player_state", {"key_red": "TRUE", "key_blue": "TRUE", "key_yellow": "TRUE"}, where)
            message = "Very Happy Ammo Added"
        for c, col, val, msg in (("IDBEHOLDV", "invuln_tics", "1050", "Invulnerability"),
                                 ("IDBEHOLDI", "invis_tics", "2100", "Partial Invisibility"),
                                 ("IDBEHOLDR", "radsuit_tics", "2100", "Radiation Suit"),
                                 ("IDBEHOLDA", "power_map", "TRUE", "Computer Area Map"),
                                 ("IDBEHOLDL", "light_amp_tics", "4200", "Light Amplification Visor")):
            if code == c:
                b.update("player_state", {col: val}, where)
                message = msg
        if code == "IDBEHOLDS":
            b.update("player_state", {"berserk": "TRUE", "health": "GREATEST(t.health, 100)"}, where)
            message = "Berserk"
        if code == "IDCHOPPERS":
            b.replace_rows("player_weapon_owned", f"map_id = {m} AND player_thing_id = {p} AND weapon_id = 8",
                           f"SELECT {m} AS map_id, {p} AS player_thing_id, 8 AS weapon_id")
            message = "... doesn't suck - GM"
        if code == "IDMYPOS":
            t = one(f"SELECT angle, x, y FROM things WHERE map_id = {m} AND id = {p}")
            rnd = lambda v: int(abs(v) + 0.5) * (1 if v >= 0 else -1)
            message = f"ang={rnd(t['angle'])}; x,y=({rnd(t['x'])},{rnd(t['y'])})"
        return message

    @b.handler("doom_cheat_code")
    def cheat_code(m, p, code):
        return [(cheat(m, p, code),)]

    @b.handler("doom_cheat_arsenal")
    def cheat_arsenal(m, p):
        arsenal(m, p)
        return [(7,)]

    @b.handler("doom_cheat_key_call")
    def cheat_key(m, p, key):
        b.update("screen_state", {"cheat_buffer": f"right(concat(t.cheat_buffer, upper({literal(key)})), 12)"}, "t.id = 0")
        buf = one("SELECT cheat_buffer FROM screen_state WHERE id = 0")["cheat_buffer"]
        result = "none"
        if len(buf) >= 8 and buf[-8:-2] == "IDCLEV" and "1" <= buf[-2] <= "9" and "1" <= buf[-1] <= "9":
            result = f"warp:E{buf[-2]}M{buf[-1]}"
        elif len(buf) >= 7 and buf[-7:-2] == "IDMUS" and "1" <= buf[-2] <= "9" and "1" <= buf[-1] <= "9":
            result = f"music:E{buf[-2]}M{buf[-1]}"
        elif buf.endswith("IDDT"):
            result = "iddt"
        else:
            hits = sorted((c for c in CODES if buf.endswith(c)), key=lambda c: (-len(c), c))
            if hits:
                result = "code:" + hits[0]
        if result.startswith("code:"):
            result = "msg:" + cheat(m, p, result[5:])
        if result != "none":
            b.update("screen_state", {"cheat_buffer": "''"}, "t.id = 0")
        return [(result,)]
