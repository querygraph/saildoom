"""The title screen's attract loop and the menus: 41_flow.sql's
doom_attract_start/stop/tic and 31_menu.sql's doom_menu_input, over the
single screen_state row."""

VOID = [("",)]  # what CedarDB returns for a function with no result


def register(b):
    s = b.store

    def screen():
        return s.query("SELECT * FROM screen_state WHERE id = 0")[0].asDict()

    @b.handler("doom_attract_start_call")
    def attract_start():
        b.update("screen_state", {"attract_step": "0", "attract_pagetic": "170", "screen": "'title'",
                                  "cursor_index": "0", "demo_playing": "NULL", "demo_recording": "NULL",
                                  "demo_tic": "0"}, "t.id = 0")
        return VOID

    @b.handler("doom_attract_stop_call")
    def attract_stop():
        b.update("screen_state", {"attract_step": "-1",
                                  "screen": "CASE WHEN t.demo_playing IS NOT NULL THEN 'title' ELSE t.screen END",
                                  "demo_playing": "NULL", "demo_tic": "0"}, "t.id = 0")
        return VOID

    @b.handler("doom_attract_tic_call")
    def attract_tic():
        st = screen()
        step, pagetic, playing = st["attract_step"], st["attract_pagetic"], st["demo_playing"]
        if step < 0 or playing is not None:
            return [("none",)]
        if pagetic > 1:
            b.update("screen_state", {"attract_pagetic": "t.attract_pagetic - 1"}, "t.id = 0")
            return [("none",)]
        step += 1
        n = s.query("SELECT count(*) AS c FROM demos")[0]["c"]
        if n == 0:
            b.update("screen_state", {"attract_step": str(step), "attract_pagetic": "170",
                                      "screen": "'title'", "cursor_index": "0"}, "t.id = 0")
            return [("page",)]
        slot = step % (2 * n)
        if slot % 2 == 0:
            b.update("screen_state", {"attract_step": str(step),
                                      "attract_pagetic": "170" if slot == 0 else "200",
                                      "screen": "'title'" if slot == 0 else "'help2'",
                                      "cursor_index": "0"}, "t.id = 0")
            return [("page",)]
        rows = s.query(f"""SELECT demo_id FROM (SELECT d.demo_id, ROW_NUMBER() OVER (ORDER BY d.demo_id) AS rn
                           FROM demos d) q WHERE q.rn = {slot // 2 + 1}""")
        did = rows[0]["demo_id"] if rows else -1
        b.update("screen_state", {"attract_step": str(step), "attract_pagetic": "0",
                                  "demo_playing": "NULL" if did is None else str(did),
                                  "demo_recording": "NULL", "demo_tic": "0", "screen": "'game'"}, "t.id = 0")
        return [(f"demo:{did}",)]

    @b.handler("doom_menu_input_call")
    def menu_input(key):
        k = "'" + key.replace("'", "''") + "'"
        st = screen()
        sc, cur = st["screen"], st["cursor_index"]
        has_save = bool(s.query(f"SELECT 1 FROM save_slots WHERE slot = {cur}"))
        action = ("start" if sc == "skill" and key == "enter" else
                  "quit" if sc == "main" and key == "enter" and cur == 5 else
                  "advance" if sc == "intermission" and key in ("enter", "escape") else
                  f"load:{cur}" if sc == "load" and key == "enter" and has_save else
                  f"save:{cur}" if sc == "save" and key == "enter" else "none")
        items = s.query(f"SELECT count(*) AS c FROM menu_items WHERE screen = '{sc}'")[0]["c"]
        n = max(1, items)
        save = "TRUE" if has_save else "FALSE"
        b.update("screen_state", {
            "screen": f"""CASE
              WHEN t.screen='title' THEN 'main'
              WHEN t.screen='main' AND {k}='enter' AND t.cursor_index=0 THEN 'episode'
              WHEN t.screen='main' AND {k}='enter' AND t.cursor_index=4 THEN 'help1'
              WHEN t.screen='help1' AND {k}='enter' THEN 'help2'
              WHEN t.screen='help2' AND {k}='enter' THEN 'main'
              WHEN t.screen IN ('help1','help2') AND {k}='escape' THEN 'main'
              WHEN t.screen='main' AND {k}='enter' AND t.cursor_index=2 THEN 'load'
              WHEN t.screen='main' AND {k}='enter' AND t.cursor_index=3 THEN 'save'
              WHEN t.screen IN ('load','save') AND {k}='escape' THEN 'main'
              WHEN t.screen='main' AND {k}='escape' THEN 'game'
              WHEN t.screen='save' AND {k}='enter' THEN 'game'
              WHEN t.screen='load' AND {k}='enter' AND {save} THEN 'game'
              WHEN t.screen='episode' AND {k}='enter' THEN 'skill'
              WHEN t.screen='episode' AND {k}='escape' THEN 'main'
              WHEN t.screen='skill' AND {k}='escape' THEN 'episode'
              WHEN t.screen='skill' AND {k}='enter' THEN 'game'
              WHEN t.screen='intermission' AND {k} IN ('enter','escape') THEN 'game'
              ELSE t.screen END""",
            "cursor_index": f"""CASE
              WHEN t.screen='title' THEN 0
              WHEN {k}='enter' AND t.screen='episode' THEN 2
              WHEN {k}='enter' AND ((t.screen='main' AND t.cursor_index IN (0,2,3))
                                    OR t.screen IN ('skill','intermission','load','save')) THEN 0
              WHEN t.screen IN ('help1','help2') THEN 4
              WHEN {k}='escape' AND t.screen='skill' THEN 0
              WHEN {k}='escape' AND t.screen IN ('episode','intermission','load','save','main') THEN 0
              WHEN {k}='down' THEN (t.cursor_index + 1) % {n}
              WHEN {k}='up' THEN (t.cursor_index - 1 + {n}) % {n}
              ELSE t.cursor_index END""",
            "episode": f"CASE WHEN t.screen='episode' AND {k}='enter' THEN t.cursor_index + 1 ELSE t.episode END",
            "skill": f"CASE WHEN t.screen='skill' AND {k}='enter' THEN t.cursor_index ELSE t.skill END",
        }, "t.id = 0")
        return [(action,)]

    @b.raw("SELECT screen,cursor_index,episode,skill FROM screen_state WHERE id=0")
    def screen_row():
        return [tuple(r) for r in s.query("SELECT screen, cursor_index, episode, skill FROM screen_state WHERE id = 0")]

    @b.raw("UPDATE screen_state SET screen=%s WHERE id=0")
    def set_screen(name):
        b.update("screen_state", {"screen": "'" + name.replace("'", "''") + "'"}, "t.id = 0")
        return []
