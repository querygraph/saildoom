"""A player stand-in that walks a level toward its exit, for recording gameplay.

This is the human at the keyboard, not part of the engine: it only produces
the eight-field command the client sends each tic. From the map's lines it
builds the sector graph (two-sided lines a player can step through, doors
included), finds the shortest route of sectors from the start to the exit
line, and walks it through the midpoints of the portal lines. It presses use
when it stalls (doors) and at the exit switch, and it fires when a monster
stands near the crosshair with a clear line to it.
"""

import collections
import math
from pathlib import Path

import pyarrow.compute as pc
import pyarrow.parquet as pq

EXIT_SPECIALS = {11, 51, 52, 124, 197, 198}  # S1/W1 exits (normal and secret)


class Map:
    def __init__(self, data, map_id, noclip=False):
        self.noclip = noclip
        def table(name):
            t = pq.read_table(Path(data) / f"{name}.parquet")
            return t.filter(pc.equal(t.column("map_id"), map_id)).to_pylist()
        self.verts = {v["id"]: (v["x"], v["y"]) for v in table("vertexes")}
        sides = {s["id"]: s for s in table("sidedefs")}
        self.sectors = {s["id"]: s for s in table("sectors")}
        self.walls = []           # lines that block a walking player now
        self.portals = collections.defaultdict(list)  # (a, b) -> [line midpoints]
        self.exit = None
        lines = table("linedefs")
        lift_tags = {ld["tag"] for ld in lines if ld["special"] in (10, 21, 62, 88, 120, 121, 122, 123)}
        lifts = {sid for sid, sec in self.sectors.items() if sec["tag"] in lift_tags}
        for ld in lines:
            a, b = self.verts[ld["v1_id"]], self.verts[ld["v2_id"]]
            right, left = sides.get(ld["right_sd_id"]), sides.get(ld["left_sd_id"])
            mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            if ld["special"] in EXIT_SPECIALS and right is not None and self.exit is None:
                self.exit = (right["sector_id"], mid, a, b)
            if right is None or left is None or ld["flags"] & 1:
                self.walls.append((a, b))
                continue
            fs, bs = self.sectors[right["sector_id"]], self.sectors[left["sector_id"]]
            if abs(fs["floor_height"] - bs["floor_height"]) > 24 and not ({fs["id"], bs["id"]} & lifts):
                self.walls.append((a, b))
                if not self.noclip:
                    continue
            self.portals[(fs["id"], bs["id"])].append((math.dist(a, b), mid))
            self.portals[(bs["id"], fs["id"])].append((math.dist(a, b), mid))
            gap = min(fs["ceil_height"], bs["ceil_height"]) - max(fs["floor_height"], bs["floor_height"])
            if gap < 56:
                self.walls.append((a, b))   # a closed door, until used

    def hops(self, start):
        prev = {start: None}
        queue = collections.deque([start])
        while queue:
            s = queue.popleft()
            for (a, b) in self.portals:
                if a == s and b not in prev:
                    prev[b] = a
                    queue.append(b)
        return prev

    def route(self, start, goal):
        prev = {start: None}
        queue = collections.deque([start])
        while queue:
            s = queue.popleft()
            if s == goal:
                break
            for (a, b) in self.portals:
                if a == s and b not in prev:
                    prev[b] = a
                    queue.append(b)
        if goal not in prev:
            return []
        path, s = [], goal
        while s is not None:
            path.append(s)
            s = prev[s]
        path.reverse()
        points = []
        for a, b in zip(path, path[1:]):
            points.append(max(self.portals[(a, b)])[1])  # the widest portal
        return points

    def clear(self, x, y, tx, ty):
        for (x1, y1), (x2, y2) in self.walls:
            d = (tx - x) * (y2 - y1) - (ty - y) * (x2 - x1)
            if abs(d) < 1e-9:
                continue
            t = ((x1 - x) * (y2 - y1) - (y1 - y) * (x2 - x1)) / d
            u = ((x1 - x) * (ty - y) - (y1 - y) * (tx - x)) / d
            if 0 < t < 1 and 0 <= u <= 1:
                return False
        return True


class Bot:
    """noclip=True: the recording turns on IDCLIP and IDDQD, so the bot tours
    every sector through every two-sided line and cannot get stuck or die."""

    def __init__(self, data, map_id, seed=1, noclip=False):
        self.map = Map(data, map_id, noclip=noclip)
        self.points = None
        self.last = None
        self.stuck = 0
        self.wiggle = 0
        self.moving = False
        self.angle = 0.0
        self.sector = None
        self.visited = set()
        self.goal = None
        self.goal_tic = 0

    def observe(self, snap):
        here = (snap["x"], snap["y"])
        self.angle = snap["angle"]
        if self.moving and self.last is not None and math.dist(here, self.last) < 1.5:
            self.stuck += 1
        else:
            self.stuck = 0
        self.last = here

    def plan(self, sector):
        """Route to the nearest sector not visited yet (by portal hops); when
        every reachable sector has been seen, start the tour again, heading
        first for the farthest one."""
        prev = self.map.hops(sector)
        order = []
        for s in prev:
            depth, t = 0, s
            while prev[t] is not None:
                depth, t = depth + 1, prev[t]
            order.append((depth, s))
        order.sort()
        candidates = [s for depth, s in order if depth > 0 and s not in self.visited]
        if not candidates:
            self.visited = {sector}
            candidates = [s for depth, s in reversed(order) if depth > 0]
        self.goal_tic = 0
        for s in candidates:
            points = self.map.route(sector, s)
            if points:
                self.goal, self.points = s, points
                return
        self.goal, self.points = None, []

    def command(self, tic, skill, monsters=(), sector=None):
        if sector is not None:
            self.visited.add(sector)
        self.goal_tic += 1
        if sector is not None and (self.points is None or not self.points
                                   or sector == self.goal or self.goal_tic > 150):
            if self.goal is not None and self.goal_tic > 150:
                self.visited.add(self.goal)   # unreachable for now
            self.plan(sector)
        x, y = self.last
        fwd, strafe, turn, run, attack, use = 0.0, 0.0, 0.0, True, False, False
        target = None
        while self.points:
            tx, ty = self.points[0]
            if math.dist((x, y), (tx, ty)) < 40:
                self.points.pop(0)
                continue
            target = (tx, ty)
            break
        if target is None and self.wiggle == 0:
            self.wiggle = 24          # nowhere routed to: wander a little
        if self.wiggle > 0:
            self.wiggle -= 1
            strafe = 1.0 if (self.wiggle // 6) % 2 else -1.0
            fwd = 0.5
        elif target is not None:
            bearing = math.degrees(math.atan2(target[1] - y, target[0] - x))
            diff = (bearing - self.angle + 540.0) % 360.0 - 180.0
            turn = max(-8.0, min(8.0, -diff))  # positive turn_degrees turns right (clockwise)
            fwd = 1.0 if abs(diff) < 35 else 0.0
            if self.stuck >= 5:
                use = True              # a door in the way, perhaps
                self.wiggle = 18
                self.stuck = 0
        # Face and fire at the nearest monster in clear view within 700 units.
        seen = []
        for mx, my in monsters:
            dist = math.dist((x, y), (mx, my))
            if dist < 700 and self.map.clear(x, y, mx, my):
                seen.append((dist, mx, my))
        if seen:
            dist, mx, my = min(seen)
            bearing = math.degrees(math.atan2(my - y, mx - x))
            off = (bearing - self.angle + 540.0) % 360.0 - 180.0
            turn = max(-10.0, min(10.0, -off))
            fwd = min(fwd, 0.3)
            attack = abs(off) < 12
        self.moving = fwd > 0.5 and self.wiggle == 0
        return (skill, fwd, strafe, run, turn, attack, None, use)
