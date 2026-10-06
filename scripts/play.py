"""Play SQLDoom on Sail: SQLDoom's own client, unchanged, with its database
calls answered by the API backend (saildoom/backend.py) instead of CedarDB.

  SAIL_REMOTE=sc://localhost:50053 play.py --sqldoom ../saildoom-ref/sqldoom

--seconds N --headless runs it without a window for N seconds and prints where
the time went, which is how it is tested.
"""

import argparse
import os
import sys
import threading
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from saildoom import engine, pgshim  # noqa: E402
from saildoom.backend import Backend, Store  # noqa: E402


def initial_store(data, trace, out):
    """The Freedoom export, with the tables only a fresh CedarDB dump has."""
    out.mkdir(parents=True, exist_ok=True)
    for p in out.glob("*.parquet"):
        p.unlink()
    for p in data.glob("*.parquet"):
        (out / p.name).symlink_to(p.resolve())
    for p in (trace / "initial").glob("*.parquet"):
        if not (out / p.name).exists():
            (out / p.name).symlink_to(p.resolve())
    return out


def scripted_input():
    """Menu presses as events and held keys through key.get_pressed, on a
    clock from now: Enter four times (title, main menu, episode, skill), then
    forward, a turn, and the fire button."""
    import pygame
    start = time.perf_counter()
    presses = [(4, pygame.K_RETURN), (7, pygame.K_RETURN), (10, pygame.K_RETURN), (13, pygame.K_RETURN)]
    held = [(16, 40, pygame.K_w), (24, 27, pygame.K_RIGHT), (30, 33, pygame.K_LCTRL), (34, 38, pygame.K_w)]

    class Pressed:
        def __getitem__(self, key):
            t = time.perf_counter() - start
            return any(a <= t < b and k == key for a, b, k in held)

    pygame.key.get_pressed = lambda: Pressed()

    def press():
        for at, key in presses:
            time.sleep(max(0.0, at - (time.perf_counter() - start)))
            for kind in (pygame.KEYDOWN, pygame.KEYUP):
                pygame.event.post(pygame.event.Event(kind, key=key, mod=0, unicode="\r", scancode=40))
    threading.Thread(target=press, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sqldoom", type=Path, default=ROOT.parent / "saildoom-ref/sqldoom")
    ap.add_argument("--data", type=Path, default=ROOT / "data/freedoom1")
    ap.add_argument("--trace", type=Path, default=ROOT / "reference/trace-menus")
    ap.add_argument("--store", type=Path, default=ROOT / "data/play-store")
    ap.add_argument("--resume", action="store_true", help="keep the store from the last session")
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--seconds", type=float)
    ap.add_argument("--scripted", action="store_true",
                    help="press through the menus into E1M1, then walk and fire (for --headless tests)")
    args = ap.parse_args()

    # The game thread waits on the server many times a tic; each time it may
    # then wait for the interpreter while another thread (the Spark Connect
    # client releases finished executions in the background) holds it, up to
    # the switch interval (5 ms by default).
    sys.setswitchinterval(float(os.environ.get("SAILDOOM_SWITCH_INTERVAL", "0.0005")))
    if args.headless:
        os.environ["SDL_VIDEODRIVER"] = "dummy"
        os.environ["SDL_AUDIODRIVER"] = "dummy"
    spark = engine.connect()
    if args.resume and (args.store / "manifest.json").exists():
        store = Store(spark, args.store, None)
    else:
        import shutil
        shutil.rmtree(args.store, ignore_errors=True)
        store = Store(spark, args.store, initial_store(args.data, args.trace, args.store.parent / "play-initial"))
    backend = Backend(spark, store)
    pgshim.install_module(backend)

    sys.path.insert(0, str(args.sqldoom))
    os.chdir(args.sqldoom)
    import doom_sql
    from saildoom.backend import install
    install(doom_sql, backend)
    calls = Counter()
    seconds = Counter()
    call = backend.call

    finished = {"doom_game_tic": [], "doom_render_frame_folded": []}

    def timed(name, params):
        started = time.perf_counter()
        try:
            return call(name, params)
        finally:
            calls[name] += 1
            seconds[name] += time.perf_counter() - started
            if name in finished:
                finished[name].append(time.perf_counter())
    backend.call = timed

    if os.environ.get("SAILDOOM_LOCK_TIMING"):
        # Who waits on the backend lock, and for how long.
        waits, holds = Counter(), Counter()
        inner = backend.lock

        class TimedLock:
            def __enter__(self):
                t = time.perf_counter()
                inner.acquire()
                self.t = time.perf_counter()
                waits[threading.current_thread().name] += self.t - t
                return self

            def __exit__(self, *exc):
                holds[threading.current_thread().name] += time.perf_counter() - self.t
                inner.release()

        backend.lock = TimedLock()
        import atexit
        atexit.register(lambda: print("lock waits", dict(waits), "holds", dict(holds)))

    if args.seconds:
        def stop():
            time.sleep(args.seconds)
            import pygame
            pygame.event.post(pygame.event.Event(pygame.QUIT))
        threading.Thread(target=stop, daemon=True).start()

    if args.scripted:
        scripted_input()
    import doom_client
    try:
        doom_client.main()
    finally:
        # Steady play: the last 20 seconds, after any level start's planning.
        for name, times in finished.items():
            if times:
                recent = [t for t in times if t >= times[-1] - 20]
                print(f"{name}: {len(recent) / 20:.1f} a second over the last 20 s")
        print("\nstatement                         calls   mean ms")
        for name, n in calls.most_common():
            print(f"{name:32s} {n:6d} {1000 * seconds[name] / n:9.1f}")
        for kind, text, extra in pgshim.LOG:
            if kind != "raw":
                print(kind, text, extra)


if __name__ == "__main__":
    main()
