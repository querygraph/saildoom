"""Scenarios for reference/trace_api.py: sequences of SQLDoom API calls, the
ones its client makes, each a module-level class with maps() and run()."""


class Menus:
    """The attract loop from a cold start, then every menu screen and key."""

    @staticmethod
    def maps(cur, sql):
        return []

    @staticmethod
    def run(cur, sql):
        sql.attract_start(cur)
        for _ in range(400):           # title 170 tics, then the next page
            sql.attract_tic(cur)
        sql.attract_stop(cur)
        keys = ["enter",                               # title -> main
                "down", "down", "down", "up", "down", "down", "down", "up", "up",
                "enter", "escape",                     # help (cursor 4) and back? cursor dependent
                "down", "enter", "escape",             # load, back
                "down", "enter", "escape",             # save, back
                "up", "up", "up", "enter",             # new game -> episode
                "down", "escape", "enter",             # episode -> main, main -> episode
                "down", "down", "up", "enter",         # episode 2 -> skill
                "down", "down", "escape", "enter",     # skill -> episode -> skill
                "up", "enter"]                         # start
        for key in keys:
            sql.menu_input(cur, key)
            sql.screen_state(cur)
        sql.set_screen(cur, "game")
        sql.screen_state(cur)


SCENARIOS = {"menus": Menus}


class Campaign:
    """A single-player episode the way the client plays it: E1M1 with the
    recorded bot's commands, cheats typed as keys, weapon slots, the automap,
    the level exit, the intermission tally, E1M2 carried over with a save and
    a load, a secret exit, E1M8 to the finale, and a demo recorded and then
    played back by the attract loop."""

    MAPS = ("E1M1", "E1M2", "E1M8", "E1M9")

    @staticmethod
    def _stages(cur, sql):
        return {s["label"]: s for s in sql.load_stages(cur)}

    @classmethod
    def maps(cls, cur, sql):
        stages = cls._stages(cur, sql)
        return [stages[m]["map_id"] for m in cls.MAPS]

    @classmethod
    def run(cls, cur, sql):
        import json
        from pathlib import Path
        stages = cls._stages(cur, sql)
        commands = json.loads((Path(__file__).parent / "run-e1m1-b/commands.json").read_text())
        skill = 2
        state = {"event": 0}

        def play(stage, tics, offset=0, alpha=0.5):
            m, p = stage["map_id"], stage["player_thing_id"]
            for i in range(tics):
                c = commands[(offset + i) % len(commands)]["command"]
                command = (skill, *c[1:])
                sql.execute_game_tic(cur, m, p, command)
                events, loops = sql.fetch_sound_events(cur, m, p, state["event"])
                if events:
                    state["event"] = max(e[0] for e in events)
                sql.finish_game_tic(cur, m, p)
                sql.camera_pose(cur, m, p, alpha)

        e1m1, e1m2, e1m8 = stages["E1M1"], stages["E1M2"], stages["E1M8"]
        sql.set_screen(cur, "game")
        sql.enter_level(cur, e1m1["map_id"], e1m1["player_thing_id"], skill)
        sql.fetch_stage_music(cur, e1m1["map_id"])
        play(e1m1, 60)
        for key in "iddqd":
            sql.cheat_key(cur, e1m1["map_id"], e1m1["player_thing_id"], key)
        for key in "idkfa":
            sql.cheat_key(cur, e1m1["map_id"], e1m1["player_thing_id"], key)
        sql.select_weapon_slot(cur, e1m1["map_id"], e1m1["player_thing_id"], 3)
        play(e1m1, 30, 60)
        sql.cycle_weapon(cur, e1m1["map_id"], e1m1["player_thing_id"], 1)
        play(e1m1, 30, 90)
        for what in ("follow", "grid"):
            sql.automap_toggle(cur, e1m1["map_id"], e1m1["player_thing_id"], what)
        sql.automap_zoom(cur, e1m1["map_id"], e1m1["player_thing_id"], 1.25)
        sql.automap_pan(cur, e1m1["map_id"], e1m1["player_thing_id"], 64, -32)
        sql.automap_fit(cur, e1m1["map_id"], e1m1["player_thing_id"])
        sql.render_automap(cur, e1m1["map_id"], e1m1["player_thing_id"])
        play(e1m1, 120, 120)

        nxt = sql.level_exit(cur, e1m1["map_id"], e1m1["player_thing_id"], False)
        for i in range(400):
            status, _ = sql.intermission_tic(cur)
            if i == 30:
                sql.intermission_accelerate(cur)
            if status == "waiting":
                sql.intermission_accelerate(cur)
            if status == "done":
                break
        sql.after_intermission(cur, e1m1["map_id"])

        sql.enter_level(cur, e1m2["map_id"], e1m2["player_thing_id"], skill,
                        carry_from=(e1m1["map_id"], e1m1["player_thing_id"]))
        play(e1m2, 60, 300)
        sql.save_game(cur, 0, e1m2["map_id"], e1m2["player_thing_id"], skill, "sail test")
        play(e1m2, 40, 360)
        sql.load_game(cur, 0)
        play(e1m2, 40, 400)
        sql.level_exit(cur, e1m2["map_id"], e1m2["player_thing_id"], True)
        for _ in range(400):
            status, _ = sql.intermission_tic(cur)
            if status == "waiting":
                sql.intermission_accelerate(cur)
            if status == "done":
                break
        sql.after_intermission(cur, e1m2["map_id"])

        sql.enter_level(cur, e1m8["map_id"], e1m8["player_thing_id"], skill)
        play(e1m8, 40, 500)
        sql.level_exit(cur, e1m8["map_id"], e1m8["player_thing_id"], False)
        for _ in range(400):
            status, _ = sql.intermission_tic(cur)
            if status == "waiting":
                sql.intermission_accelerate(cur)
            if status == "done":
                break
        sql.after_intermission(cur, e1m8["map_id"])
        sql.finale_phase(cur)
        for i in range(300):
            if sql.finale_tic(cur) == "done":
                break
            if i in (100, 200):
                sql.finale_advance(cur)
        sql.finale_phase(cur)

        sql.enter_level(cur, e1m1["map_id"], e1m1["player_thing_id"], skill)
        sql.demo_begin(cur, "sailtest", e1m1["map_id"], e1m1["player_thing_id"], skill)
        play(e1m1, 80, 700)
        sql.demo_stop(cur)
        sql.enter_level(cur, e1m1["map_id"], e1m1["player_thing_id"], skill)
        sql.demo_play(cur, "sailtest")
        play(e1m1, 85, 0)
        sql.demo_stop(cur)
        sql.attract_start(cur)
        for _ in range(450):
            outcome = sql.attract_tic(cur)
            if outcome.startswith("demo:"):
                play(e1m1, 30, 0)
                break
        sql.attract_stop(cur)


SCENARIOS["campaign"] = Campaign
