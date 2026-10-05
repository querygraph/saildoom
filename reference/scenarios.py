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
