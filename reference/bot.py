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
# Use-activated doors, lifts and floor switches the bot presses on its way.
USABLE_SPECIALS = {1, 23, 26, 27, 28, 31, 32, 33, 34, 62, 63, 102, 103, 117, 118}
USE_REACH = 120      # look for a usable line this close
USE_COOLDOWN = 140   # tics before the same line is pressed again


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
        self.usable = []          # (line id, midpoint, v1, v2)
        lines = table("linedefs")
        lift_tags = {ld["tag"] for ld in lines if ld["special"] in (10, 21, 62, 88, 120, 121, 122, 123)}
        lifts = {sid for sid, sec in self.sectors.items() if sec["tag"] in lift_tags}
        for ld in lines:
            a, b = self.verts[ld["v1_id"]], self.verts[ld["v2_id"]]
            right, left = sides.get(ld["right_sd_id"]), sides.get(ld["left_sd_id"])
            mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            if ld["special"] in EXIT_SPECIALS and right is not None and self.exit is None:
                self.exit = (right["sector_id"], mid, a, b)
            if ld["special"] in USABLE_SPECIALS and right is not None:
                self.usable.append((ld["id"], mid, a, b))
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
        self.pressed = {}         # line id -> tic last pressed (or given up)
        self.pressing = None      # (line id, midpoint, tic started)
        self.engaged = {}         # monster id -> tics spent on it
        self.ignored = {}         # monster id -> tic until which it is ignored

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
        # Doors and switches: walk up to a usable line in front, face it, press use.
        if self.pressing is None:
            near = []
            for line_id, mid, a, b in self.map.usable:
                dist = math.dist((x, y), mid)
                front = ((b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])) < 0
                if (dist < USE_REACH and front
                        and tic - self.pressed.get(line_id, -USE_COOLDOWN) >= USE_COOLDOWN):
                    near.append((dist, line_id, mid))
            if near:
                _, line_id, mid = min(near)
                self.pressing = (line_id, mid, tic)
        if self.pressing is not None:
            line_id, mid, since = self.pressing
            dist = math.dist((x, y), mid)
            bearing = math.degrees(math.atan2(mid[1] - y, mid[0] - x))
            diff = (bearing - self.angle + 540.0) % 360.0 - 180.0
            turn = max(-10.0, min(10.0, -diff))
            fwd = 0.5 if dist > 44 and abs(diff) < 30 else 0.0
            strafe = 0.0
            if dist < 62 and abs(diff) < 8:
                use = True
            if use or tic - since > 70:
                self.pressed[line_id] = tic
                self.pressing = None
        # Face and fire at the nearest monster in clear view within 1000 units.
        # A monster it cannot hurt (behind a ledge or a window) is dropped after
        # a while, so the bot does not stand shooting at it for the whole run.
        seen = []
        for mid_, mx, my in monsters:
            if self.ignored.get(mid_, -1) > tic:
                continue
            dist = math.dist((x, y), (mx, my))
            if dist < 1000 and self.map.clear(x, y, mx, my):
                seen.append((dist, mid_, mx, my))
        if seen:
            dist, mid_, mx, my = min(seen)
            self.engaged[mid_] = self.engaged.get(mid_, 0) + 1
            if self.engaged[mid_] > 70:
                self.ignored[mid_] = tic + 400
                self.engaged[mid_] = 0
            bearing = math.degrees(math.atan2(my - y, mx - x))
            off = (bearing - self.angle + 540.0) % 360.0 - 180.0
            turn = max(-10.0, min(10.0, -off))
            fwd = fwd * 0.5
            use = False
            attack = abs(off) < 15
        self.moving = fwd > 0.5 and self.wiggle == 0
        return (skill, fwd, strafe, run, turn, attack, None, use)
