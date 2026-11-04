#!/usr/bin/env python3
"""Simulation for docs/design/spawning-and-rarity.md.

World generation follows the doc: chunk 2048 px, region 8x8 chunks, canonical region order (ring, then (ry, rx)),
tier = floor(max(|x|,|y|)/16384 px) by D-inf (8 chunks per tier); regions are centred on the world origin, starter boss, tier-dependent boss quota with distance pity,
boss rarity with deterministic world pity, elite encounters with rarity and region-level elite pity.
Walkers move at 300 px/s (requires numpy). Output: results.txt. Run: python3 rarity_sim.py [seeds] [walks_per_seed]
"""
import math, random, sys, statistics as st

CHUNK = 2048.0
TIER_PX = 16384.0   # one tier = 8 chunks = one region ring
HORIZON = 30 * 60
SPEED = 300.0
WAKE = 700.0            # elite wake / engage distance (px, Euclidean)
BEACON = 5 * CHUNK      # boss beacon radius (px, Euclidean)
ARRIVE = 1000.0         # "arrived at boss" distance (px)

# ---- parameters (the doc tables) -------------------------------------------------
BOSS_P_FIRST = [0.30, 0.25, 0.18, 0.12, 0.08]       # base by tier (index min(T,4))
BOSS_P_SECOND = [0.08, 0.06, 0.04, 0.03, 0.02]
BOSS_PITY_STEP = 0.05                                # +5% per 10 chunks of d
# boss rarity base odds (rare, legendary) by tier
BOSS_RARE = [0.00, 0.10, 0.22, 0.33, 0.42]
BOSS_LEG = [0.00, 0.00, 0.03, 0.10, 0.16]
BOSS_RARE_PITY, BOSS_LEG_PITY = 0.08, 0.02           # per boss since last rare+ / legendary
BOSS_RARE_FORCE = 6                                  # tier>=2: >=1 rare+ in any 6 consecutive bosses
BOSS_LEG_FORCE = 12                                  # tier>=3: >=1 legendary in any 12 consecutive bosses
# elites
ENC_PER_CHUNK = [2, 2, 3, 3, 3]
ELITE_P = [0.04, 0.05, 0.05, 0.06, 0.06]             # per encounter
ELITE_RARE = [0.00, 0.15, 0.27, 0.36, 0.42]          # share of elites that are rare
ELITE_LEG = [0.00, 0.00, 0.01, 0.025, 0.04]         # share of elites that are legendary
ELITE_RARE_FORCE_REGIONS = 3                         # tier>=1: forced rare elite after 3 regions without rare+
ELITE_LEG_FORCE_REGIONS = 12                         # tier>=3: forced legendary after 12 regions without legendary
HERALD_MIN, HERALD_MAX = 58.0, 78.0                  # seconds of exploration before the Herald is placed
HERALD_TRAVEL = 2.0                                  # seconds from placement (1,200 px ahead) to wake distance


# chunk area of each tier band (D-inf in chunks: T0 <8, T1 8-16, T2 16-24, T3 24-32, T4+ >=32) for the simulated world
def tier_area(T, rings=34):
    half = rings * 8 + 4
    lim = [8, 16, 24, 32, half]
    lo = 0 if T == 0 else lim[T - 1]
    hi = lim[T]
    return (2 * hi) ** 2 - (2 * lo) ** 2


def tier_of(x_px, y_px):
    return min(int(max(abs(x_px), abs(y_px)) // TIER_PX), 4)


def dinf(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))


class World:
    def __init__(self, seed, rings=34):
        rnd = random.Random(seed)
        self.rnd = rnd
        self.bosses = []   # dict(c=(cx+.5,cy+.5), rarity=0/1/2, tier)
        self.elites = {}   # (cx,cy) -> list of (x,y,rarity)
        self.herald_delay = rnd.uniform(HERALD_MIN, HERALD_MAX)
        boss_chunks = []
        # starter boss: D-inf 8.5 or 9.5 chunks from origin (tier 1), always common
        cands = [(cx, cy) for cx in range(-10, 10) for cy in range(-10, 10)
                 if max(abs(cx + .5), abs(cy + .5)) in (8.5, 9.5)]
        c = rnd.choice(cands)
        self._add_boss((c[0] + .5, c[1] + .5), forced_common=True)
        since_rare = 0
        since_leg = 0
        regs = []
        for k in range(rings + 1):
            ring = [(rx, ry) for rx in range(-k, k + 1) for ry in range(-k, k + 1) if max(abs(rx), abs(ry)) == k]
            ring.sort(key=lambda r: (r[1], r[0]))
            regs += ring
        self.since_rare_b = 0
        self.since_leg_b = 0
        self.reg_no_rare = 0
        self.reg_no_leg = 0
        self.boss_log = []
        self.region_tiers = {T: 0 for T in range(5)}
        for (rx, ry) in regs:
            ctr = (8 * rx, 8 * ry)          # region centre, chunk units (origin-centred regions)
            T = tier_of(ctr[0] * CHUNK, ctr[1] * CHUNK)
            self.region_tiers[T] += 1
            d = min(min(dinf(ctr, b['c']) for b in self.bosses), 80)
            pf = BOSS_P_FIRST[T] + BOSS_PITY_STEP * math.floor(d / 10)
            n = (rnd.random() < pf) + (rnd.random() < BOSS_P_SECOND[T])
            region_boss_chunks = set()
            for _ in range(n):
                for _try in range(10):
                    cc = (8 * rx - 4 + rnd.randrange(8) + .5, 8 * ry - 4 + rnd.randrange(8) + .5)
                    if all(dinf(cc, b['c']) >= 6 for b in self.bosses) and dinf(cc, (0, 0)) >= 4:
                        self._add_boss(cc)
                        region_boss_chunks.add((int(math.floor(cc[0])), int(math.floor(cc[1]))))
                        break
            self._gen_elites(rx, ry, T, region_boss_chunks)

    def _add_boss(self, cc, forced_common=False):
        T = tier_of(cc[0] * CHUNK, cc[1] * CHUNK)
        r = 0
        if not forced_common and T >= 1:
            sr = getattr(self, 'since_rare_b', 0)
            sl = getattr(self, 'since_leg_b', 0)
            leg_p = BOSS_LEG[T] + (min(BOSS_LEG_PITY * sl, 0.20) if T >= 3 else 0.0)
            rare_p = BOSS_RARE[T] + min(BOSS_RARE_PITY * sr, 0.40)
            u = self.rnd.random()
            if T >= 3 and sl >= BOSS_LEG_FORCE:
                r = 2
            elif T >= 2 and sr >= BOSS_RARE_FORCE:
                r = 2 if u < leg_p else 1
            elif u < leg_p:
                r = 2
            elif u < leg_p + rare_p:
                r = 1
        # pity counters: the rare counter counts bosses of tier >= 1, the legendary counter bosses of tier >= 3
        if not forced_common and T >= 1:
            self.since_rare_b = 0 if r >= 1 else getattr(self, 'since_rare_b', 0) + 1
        if not forced_common and (T >= 3 or r == 2):
            self.since_leg_b = 0 if r == 2 else getattr(self, 'since_leg_b', 0) + 1
        self.bosses.append({'c': cc, 'rarity': r, 'tier': T})

    def _gen_elites(self, rx, ry, T, boss_chunks):
        rnd = self.rnd
        have_rare = False
        have_leg = False
        placed = []
        for dx in range(8):
            for dy in range(8):
                cx, cy = 8 * rx - 4 + dx, 8 * ry - 4 + dy
                if (cx, cy) in boss_chunks or (cx, cy) in self._boss_chunk_set():
                    continue
                if max(abs(cx + .5), abs(cy + .5)) < 0.26 * 2:   # keep the 512 px safe zone free
                    pass
                Tc = tier_of((cx + .5) * CHUNK, (cy + .5) * CHUNK)
                for _ in range(ENC_PER_CHUNK[Tc]):
                    if rnd.random() < ELITE_P[Tc]:
                        u = rnd.random()
                        r = 2 if u < ELITE_LEG[Tc] else (1 if u < ELITE_LEG[Tc] + ELITE_RARE[Tc] else 0)
                        x = (cx + rnd.random()) * CHUNK
                        y = (cy + rnd.random()) * CHUNK
                        placed.append(((cx, cy), x, y, r))
                        have_rare |= r >= 1
                        have_leg |= r == 2
        # deterministic region-level pity (canonical order)
        if T >= 1:
            if have_rare:
                self.reg_no_rare = 0
            else:
                self.reg_no_rare += 1
            if self.reg_no_rare >= ELITE_RARE_FORCE_REGIONS:
                self._force(rx, ry, 1, placed, boss_chunks)
                self.reg_no_rare = 0
                have_rare = True
        if T >= 3:
            if have_leg:
                self.reg_no_leg = 0
            else:
                self.reg_no_leg += 1
            if self.reg_no_leg >= ELITE_LEG_FORCE_REGIONS:
                self._force(rx, ry, 2, placed, boss_chunks)
                self.reg_no_leg = 0
        for key, x, y, r in placed:
            self.elites.setdefault(key, []).append((x, y, r))

    def _boss_chunk_set(self):
        return {(int(math.floor(b['c'][0])), int(math.floor(b['c'][1]))) for b in self.bosses[-3:]}

    def _force(self, rx, ry, r, placed, boss_chunks):
        rnd = self.rnd
        for _ in range(20):
            cx, cy = 8 * rx - 4 + rnd.randrange(8), 8 * ry - 4 + rnd.randrange(8)
            if (cx, cy) not in boss_chunks and max(abs(cx + .5), abs(cy + .5)) >= 8:   # forced elites sit in a chunk of tier >= 1
                placed.append(((cx, cy), (cx + rnd.random()) * CHUNK, (cy + rnd.random()) * CHUNK, r))
                return


def walk(world, rnd, model, targets):
    """Returns dict target-> time (s) when first met. Starts at tutorial exit (512 px radius)."""
    ang = rnd.uniform(0, 2 * math.pi)
    x, y = 512 * math.cos(ang), 512 * math.sin(ang)
    heading = ang
    t = 0.0
    pause = 0.0
    res = {}
    since_turn = 0.0
    engaged = set()
    bosses = world.bosses
    herald_t = world.herald_delay
    herald_done = False
    horizon = HORIZON
    import numpy as np
    bpos = np.array([[b['c'][0] * CHUNK, b['c'][1] * CHUNK] for b in bosses])
    brar = np.array([b['rarity'] for b in bosses])
    need = sum(2 if 'boss' in n else 1 for n in targets)
    while t < horizon and len(res) < need:
        # movement
        if pause > 0:
            pause -= 1.0
        else:
            x += math.cos(heading) * SPEED
            y += math.sin(heading) * SPEED
        t += 1.0
        since_turn += 1.0
        if model == 'wander' and since_turn >= 10.0:
            heading += rnd.gauss(0, math.radians(50))
            since_turn = 0.0
        # elites near
        cx0, cy0 = int(x // CHUNK), int(y // CHUNK)
        for cx in range(cx0 - 1, cx0 + 2):
            for cy in range(cy0 - 1, cy0 + 2):
                for i, (ex, ey, r) in enumerate(world.elites.get((cx, cy), ())):
                    if (cx, cy, i) in engaged:
                        continue
                    if math.hypot(ex - x, ey - y) <= WAKE:
                        engaged.add((cx, cy, i))
                        if model == 'wander':
                            pause = max(pause, [20, 30, 45][r])
                        for name, test in (('elite', lambda r: True), ('rare_elite', lambda r: r >= 1),
                                           ('legendary_elite', lambda r: r == 2)):
                            if name in targets and name not in res and test(r):
                                res[name] = t
        # herald (guaranteed early common elite)
        if not herald_done and t >= herald_t and 'elite_herald' in targets:
            herald_done = True
            res['elite_herald'] = t + HERALD_TRAVEL
        # bosses: sighting (beacon) and arrival
        dist = np.hypot(bpos[:, 0] - x, bpos[:, 1] - y)
        near = np.nonzero(dist <= BEACON)[0]
        for i in near:
            r = int(brar[i]); dd = float(dist[i])
            for name, test in (('boss', lambda r: True), ('rare_boss', lambda r: r >= 1),
                               ('legendary_boss', lambda r: r == 2)):
                key = name + '_sight'
                if name in targets and key not in res and test(r):
                    res[key] = t
                    res[name + '_arrive'] = t + max(dd - ARRIVE, 0) / SPEED
    return res


def summarize(vals, horizon=HORIZON):
    """found %, conditional mean/median/p90 of the walks that found it, and a censoring-aware mean
    (total walked time / number of finds, the exponential MLE), which is the better 'expected time'
    when only part of the walks find the target inside the horizon."""
    n_all = len(vals)
    got = sorted(v for v in vals if v is not None)
    if not got:
        return None
    total = sum(v if v is not None else horizon for v in vals)
    return {'found_%': 100.0 * len(got) / n_all, 'median_of_found': st.median(got),
            'p90_of_found': got[int(0.9 * (len(got) - 1))], 'expected_s(MLE)': total / len(got)}


def main():
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    walks = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    targets = {'elite', 'rare_elite', 'legendary_elite', 'elite_herald', 'boss', 'rare_boss', 'legendary_boss'}
    out = {m: {} for m in ('straight', 'wander')}
    dens = {T: [0, 0] for T in range(5)}
    region_count = {T: 0 for T in range(5)}
    boss_r = {T: [0, 0, 0] for T in range(5)}
    elite_r = {T: [0, 0, 0] for T in range(5)}
    for s in range(seeds):
        w = World(s)
        for T, n in w.region_tiers.items():
            region_count[T] += n
        # densities
        for b in w.bosses:
            boss_r[b['tier']][b['rarity']] += 1
        for key, lst in w.elites.items():
            for (x, y, r) in lst:
                elite_r[tier_of(x, y)][r] += 1
        rnd = random.Random(10_000 + s)
        for m in out:
            for _ in range(walks):
                res = walk(w, rnd, m, targets)
                for k in ('elite', 'rare_elite', 'legendary_elite', 'elite_herald',
                          'boss_sight', 'boss_arrive', 'rare_boss_sight', 'rare_boss_arrive',
                          'legendary_boss_sight', 'legendary_boss_arrive'):
                    out[m].setdefault(k, []).append(res.get(k))
        # combined: first elite with herald
        for m in out:
            first = []
            for a, h in zip(out[m]['elite'][-walks:], out[m]['elite_herald'][-walks:]):
                cand = [v for v in (a, h) if v is not None]
                first.append(min(cand) if cand else None)
            out[m].setdefault('first_elite_with_herald', []).extend(first)
    print('seeds', seeds, 'walks/seed', walks)
    print('\n== bosses by tier of the boss chunk: counts (common, rare, legendary), share %, chunks^2 per boss ==')
    for T in range(5):
        tot = sum(boss_r[T])
        area = tier_area(T) * seeds
        print(T, boss_r[T], [round(100 * v / tot, 1) for v in boss_r[T]] if tot else None, 'chunks2/boss %.0f' % (area / tot if tot else 0))
    print('\n== elites by tier: counts, share %, elites per chunk ==')
    for T in range(5):
        tot = sum(elite_r[T])
        print(T, elite_r[T], [round(100 * v / tot, 2) for v in elite_r[T]] if tot else None, 'per chunk %.3f' % (tot / (tier_area(T) * seeds)))
    for m in out:
        print('\n== model', m, '(seconds from tutorial exit; found%% within 30 min) ==')
        for k in ('elite', 'first_elite_with_herald', 'rare_elite', 'legendary_elite', 'boss_sight', 'boss_arrive',
                  'rare_boss_sight', 'rare_boss_arrive', 'legendary_boss_sight', 'legendary_boss_arrive'):
            s_ = summarize(out[m][k])
            print('%-24s' % k, {a: round(b, 1) for a, b in s_.items()} if s_ else None)


if __name__ == '__main__':
    main()
