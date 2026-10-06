"""Record a video of SQLDoom's own client playing on Sail.

The client runs as in scripts/play.py, headless, and every frame it shows is
captured at the wall-clock time it is shown (30 frames a second of video),
with captions drawn into it. The menus are driven by key presses; in the game,
the client's commands are replaced by the recorded bot run's
(reference/run-e1m1-b: the same cheats, IDDQD and IDKFA, before tic 1, then
1,200 tics of commands), so the run is an eventful one. Every tic and every
frame is computed live by Sail, at the speed the client runs.

  SAIL_REMOTE=sc://localhost:50053 record_play.py --out video/saildoom-interactive.mp4
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT))

FPS = 30

CAPTIONS = [
    # (from tic, text); "menus" and "planning" are the phases before tic 1.
    ("menus", "SQLDoom's own client, unchanged. Title screen and menus are rendered in SQL by Sail."),
    ("planning", "New game: the level's first tic plans the 710 KB tic query once (about 5 seconds)."),
    (1, "Every tic: one request carrying the inputs; Sail runs the plan it keeps (25 to 40 ms; more in a fight)."),
    (180, "The world stays on the server between tics, in Sail slots; only what changed comes back."),
    (360, "Inputs replayed from a recorded bot run; every tic and frame is computed live by Sail."),
    (540, "Doors, lifts, pickups, monsters, rockets: joins and windows over one relation."),
    (640, "The automap is a SQL query too (the game pauses while it is open)."),
    (800, "Each frame: SQLDoom's renderer as Spark SQL, on a plan kept for the level (about 90 ms)."),
    (960, "Checked against CedarDB: 5,349 API calls replay with identical rows, frames byte for byte."),
    (1100, "Code, reports and the Sail fork: github.com/querygraph/saildoom"),
]
AUTOMAP_AT = 640  # Tab pressed at this tic, and again after AUTOMAP_SECONDS
AUTOMAP_SECONDS = 4


class Recorder:
    def __init__(self, out):
        self.out = out
        self.proc = None
        self.size = None
        self.t0 = None
        self.written = 0
        self.tics = 0
        self.tic_times = []
        self.frame_times = []
        self.phase = "menus"
        self.done_at = None
        self.on_first_frame = None
        self.shown = []
        self.lock = threading.Lock()

    def start(self, size):
        self.size = (size[0] - size[0] % 2, size[1] - size[1] % 2)
        self.proc = subprocess.Popen(
            ["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
             "-s", f"{self.size[0]}x{self.size[1]}", "-r", str(FPS), "-i", "-",
             "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv420p",
             str(self.out)],
            stdin=subprocess.PIPE)
        self.t0 = time.perf_counter()

    def caption(self):
        if self.phase in ("menus", "planning"):
            return dict(CAPTIONS)[self.phase]
        text = None
        for at, line in CAPTIONS:
            if isinstance(at, int) and self.tics >= at:
                text = line
        return text

    def rate(self, times):
        now = time.perf_counter()
        recent = [t for t in times if t >= now - 2.0]
        return len(recent) / 2.0

    def card(self, size, lines, seconds):
        import pygame
        pygame.font.init()
        surface = pygame.Surface(size)
        surface.fill((12, 12, 16))
        big = pygame.font.Font(None, max(36, size[1] // 12))
        small = pygame.font.Font(None, max(24, size[1] // 24))
        y = size[1] // 3
        for i, line in enumerate(lines):
            font = big if i == 0 else small
            image = font.render(line, True, (235, 235, 235) if i == 0 else (190, 190, 200))
            surface.blit(image, ((size[0] - image.get_width()) // 2, y))
            y += image.get_height() + size[1] // 30
        data = pygame.image.tobytes(surface.subsurface((0, 0, *self.size)), "RGB")
        for _ in range(int(seconds * FPS)):
            self.proc.stdin.write(data)

    def capture(self, surface):
        import pygame
        if os.environ.get("RECORD_DRY"):  # measure the run without recording it
            if self.on_first_frame:
                self.on_first_frame()
                self.on_first_frame = None
            if self.phase == "playing":
                self.shown.append(self.rate(self.tic_times))
            return
        if self.proc is None:
            self.start(surface.get_size())
            if self.on_first_frame:
                self.on_first_frame()
            self.card(surface.get_size(), [
                "Sail plays Doom",
                "SQLDoom's own client, every tic and frame computed by Sail",
                "(Spark SQL on Apache DataFusion, querygraph/sail fork; live rate at top left)",
            ], 5)
            self.t0 = time.perf_counter() - 0  # time starts after the title card
        due = int((time.perf_counter() - self.t0) * FPS)
        if self.written and due <= self.written:
            return  # no video frame due yet: skip the copy (the client flips up to 120 times a second)
        frame = surface.copy()
        caption = self.caption()
        w, h = frame.get_size()
        font = pygame.font.Font(None, max(22, h // 26))
        if caption:
            image = font.render(caption, True, (255, 255, 255))
            box = pygame.Surface((image.get_width() + 24, image.get_height() + 14), pygame.SRCALPHA)
            box.fill((0, 0, 0, 170))
            x = (w - box.get_width()) // 2
            y = h - box.get_height() - h // 40
            frame.blit(box, (x, y))
            frame.blit(image, (x + 12, y + 7))
        if self.phase == "playing":
            self.shown.append(self.rate(self.tic_times))
            stats = font.render(f"Sail: {self.rate(self.tic_times):.0f} tics/s, "
                                f"{self.rate(self.frame_times):.0f} frames/s", True, (255, 230, 120))
            box = pygame.Surface((stats.get_width() + 16, stats.get_height() + 10), pygame.SRCALPHA)
            box.fill((0, 0, 0, 150))
            frame.blit(box, (10, 10))
            frame.blit(stats, (18, 15))
        data = pygame.image.tobytes(frame.subsurface((0, 0, *self.size)), "RGB")
        due = int((time.perf_counter() - self.t0) * FPS)
        while self.written < max(due, self.written + 1 if self.written == 0 else due):
            self.proc.stdin.write(data)
            self.written += 1

    def finish(self, surface_size):
        if self.proc is None or os.environ.get("RECORD_DRY"):
            return
        self.card(surface_size, [
            "github.com/querygraph/saildoom",
            "git clone, scripts/setup.sh, scripts/play-sail.sh",
            "SQLDoom by CedarDB  |  Freedoom  |  Sail by LakeSail  |  Apache DataFusion",
        ], 6)
        self.proc.stdin.close()
        self.proc.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=ROOT / "video/saildoom-interactive.mp4")
    ap.add_argument("--run", type=Path, default=ROOT / "reference/run-e1m1-b")
    ap.add_argument("--sqldoom", type=Path, default=ROOT.parent / "saildoom-ref/sqldoom")
    ap.add_argument("--tics", type=int, help="stop after this many tics (default: the whole run)")
    args = ap.parse_args()
    args.out = args.out.resolve()  # play.py changes into SQLDoom's directory
    args.out.parent.mkdir(parents=True, exist_ok=True)
    commands = [c["command"] for c in json.loads((args.run / "commands.json").read_text())]
    if args.tics:
        commands = commands[:args.tics]

    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"
    os.environ.setdefault("WINDOW_SCALE", "2")
    import pygame
    recorder = Recorder(args.out)

    # Every frame the client shows, as it shows it.
    real_flip, real_update = pygame.display.flip, pygame.display.update

    def flip(*a, **k):
        real_flip(*a, **k)
        surface = pygame.display.get_surface()
        if surface is not None:
            recorder.capture(surface)

    def update(*a, **k):
        real_update(*a, **k)
        surface = pygame.display.get_surface()
        if surface is not None:
            recorder.capture(surface)
    pygame.display.flip, pygame.display.update = flip, update

    # The menus: Enter through title, main menu, episode and skill, counted
    # from the first frame the client shows (events posted before its window
    # exists are lost).
    def press():
        start = time.perf_counter()
        for at in (4, 7, 10, 13):
            time.sleep(max(0.0, at - (time.perf_counter() - start)))
            for kind in (pygame.KEYDOWN, pygame.KEYUP):
                pygame.event.post(pygame.event.Event(kind, key=pygame.K_RETURN, mod=0, unicode="\r", scancode=40))
    recorder.on_first_frame = lambda: threading.Thread(target=press, daemon=True).start()

    sys.path.insert(0, str(args.sqldoom))
    import doom_sql
    real_tic = doom_sql.execute_game_tic
    real_render = doom_sql.render_frame

    def game_tic(cur, map_id, player_id, command):
        if recorder.tics == 0 and recorder.phase != "playing":
            recorder.phase = "planning"
            # The bot's run: god mode and every weapon, before tic 1.
            for code in ("IDDQD", "IDKFA"):
                doom_sql.cheat_code(cur, map_id, player_id, code)
        i = min(recorder.tics, len(commands) - 1)
        due = real_tic(cur, map_id, player_id, (command[0], *commands[i][1:]))
        recorder.phase = "playing"
        recorder.tics += 1
        recorder.tic_times.append(time.perf_counter())
        if recorder.tics == AUTOMAP_AT:
            # The client pauses the game while the automap is open: it is
            # closed again on a timer, not at a later tic.
            def automap():
                for delay in (0, AUTOMAP_SECONDS):
                    time.sleep(delay)
                    for kind in (pygame.KEYDOWN, pygame.KEYUP):
                        pygame.event.post(pygame.event.Event(kind, key=pygame.K_TAB, mod=0, unicode="\t", scancode=43))
            threading.Thread(target=automap, daemon=True).start()
        if recorder.tics == len(commands) and recorder.done_at is None:
            recorder.done_at = time.perf_counter()

            def stop():
                time.sleep(2)
                pygame.event.post(pygame.event.Event(pygame.QUIT))
            threading.Thread(target=stop, daemon=True).start()
        return due

    def render_frame(*a, **k):
        out = real_render(*a, **k)
        recorder.frame_times.append(time.perf_counter())
        return out
    doom_sql.execute_game_tic = game_tic
    doom_sql.render_frame = render_frame

    import play
    sys.argv = ["play.py", "--headless", "--sqldoom", str(args.sqldoom)]
    size = None
    try:
        play.main()
    finally:
        surface = pygame.display.get_surface()
        size = surface.get_size() if surface is not None else (recorder.size or (1280, 600))
        recorder.finish(size)
    shown = recorder.shown[len(recorder.shown) // 4:]
    print(f"recorded {args.out}: {recorder.tics} tics; overlay rate median "
          f"{sorted(shown)[len(shown) // 2] if shown else 0:.1f} tics/s")


if __name__ == "__main__":
    main()
