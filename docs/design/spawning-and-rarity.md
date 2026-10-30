# Scriptshot — Spawning, Elites and Rarity

> Status: **draft for review, companion to [`pillars.md`](pillars.md)** (branch `design/pillars`, PR #1). It replaces the old open question Q9 ("boss rarity target") with the owner's direction of 2026-10-30: **elite enemies for early excitement** and **rarity tiers (common / rare / legendary) for both elites and bosses**, each with distinct visuals, behaviours and rewards. Every number is a **starting value to be playtested**. Code names (`BulletPool`, `Hurtbox`, `ShotRequest`, …) refer to PR #2 (`feat/core-scaffold`); anything not on that branch is a proposal. World definitions (chunk, region, `D∞`, tier) are the ones of pillars §6.1 **as amended below**.

Nothing here limits what a player may write (P2). Elites and rare bosses are *questions your script answers*: each affix is a world rule that punishes one lazy habit (straight lines, spam of tiny bullets, a single big hit, ignoring the escorts), and some variants lean into scripts that try to skip the fight altogether (Null attacks, Equalizer, Rift). Rewards depend only on **what was killed**, never on how the player's script behaved.

## 0. Contents

1. Goals and constraints
2. Tier structure (one table every rule uses)
3. Elites: encounter model, odds, stats, affixes, the Herald
4. Boss frequency and boss rarity
5. Legendary and rare bosses: what actually changes
6. Deterministic generation (hashes, region pass, pity, persistence)
7. Rewards
8. Visual and audio language per rarity, with GL Compatibility fallbacks
9. Simulation: expected times and densities
10. Engineering notes (what to build, how to test)
11. New open questions (Q17–Q24 live in `pillars.md`)

## 1. Goals and constraints

| # | Goal | Consequence |
|---|---|---|
| G1 | The first minutes are exciting without a boss | A **first elite 60–90 s after the player leaves the tutorial range** (§3.6, the Herald) |
| G2 | Every encounter still teaches something about *your script* | Elites are a base archetype plus **1–2 affixes that counter unrestricted scripts** (§3.4) |
| G3 | Bosses are events (P5) and become rarer further out | Boss *frequency* falls with tier, while the *chance of a rare or legendary variant rises* (§4) |
| G4 | Same seed, same world, regardless of exploration order | Every roll is a pure function of `(seed, coordinates, tag)`; pity is **deterministic and ordinal**, never per-session (§6) |
| G5 | Rarity must not gate the core progression | Level I Senses come from the *first kill of any boss type at any rarity*; rare/legendary add on top (§7) |
| G6 | Minimalist, legible, accessible | Rarity is told by **shape first, outline weight second, accent colour third, a short audio sting fourth** (§8) |
| G7 | Works on GL Compatibility (desktop, web, mobile) | Cues are `_draw()` primitives and canvas blend modes; no post-process (§8.4) |

## 2. Tier structure

**Design change versus the previous `pillars.md` revision.** The earlier text used corner-aligned regions (origin region's top-left corner at the world origin) and 6-chunk tiers (12,288 px). With 8×8-chunk regions that makes a region straddle a tier boundary (tier 1 never occurred as a region-centre tier) and makes the world asymmetric. This doc, and `pillars.md` §5.2/§6.1/§6.3 as updated with it, use:

- **Tier width = 8 chunks = 16,384 px**: `T = floor(max(|x|, |y|) / 16384)` (px, `D∞`). Tier 0 is the 16×16-chunk square around the origin; tier `T` is the square ring between `D∞` 8T and 8(T+1) chunks.
- **Regions are origin-centred.** Region `(rx, ry)` = the 8×8 chunks with `cx ∈ [8rx−4, 8rx+3]`, `cy ∈ [8ry−4, 8ry+3]`; its **centre is the chunk corner `(8rx, 8ry)`** (chunk units). The world origin is the centre of region `(0,0)`. A chunk belongs to region `(floor((cx+4)/8), floor((cy+4)/8))`.
- **Region ring `k = max(|rx|, |ry|)` has centre `D∞ = 8k` chunks, so a region's tier is its ring** (`T = k`). Regions straddle a tier boundary visually (their chunks span `8k−4 … 8k+4`), but all *region* rules use the ring tier and all *chunk* rules (elites, encounters, affixes, stats) use the chunk's own tier.
- Tiers ≥ 4 share the **T4+ row** of every odds table; HP/count scaling (§5.2 of pillars) keeps growing with `T`.

| Tier | `D∞` from origin (chunks) | px | New in this tier | Straight-walk time to enter (300 px/s) |
|---|---|---|---|---|
| **T0** | 0 – 8 | 0 – 16,384 | Drifter, Swarmer; common elites (Drifter base; Splitting, Summoner) | 0 |
| **T1** | 8 – 16 | 16,384 – 32,768 | Shieldbearer, Sniper; rare elites and rare bosses; **starter boss** (`D∞` 8.5 or 9.5) | ≈ 53 s |
| **T2** | 16 – 24 | 32,768 – 49,152 | Tank, Phaser; Null-shot and Blinker affixes; legendary elites and bosses become possible (≈ 2 %) | ≈ 108 s |
| **T3** | 24 – 32 | 49,152 – 65,536 | Mirror; legendary share ≈ 16 %; legendary pity starts | ≈ 162 s |
| **T4+** | ≥ 32 | ≥ 65,536 | Highest odds row (rare ≈ 45 %, legendary ≈ 22 % of bosses) | ≈ 216 s |

## 3. Elites

### 3.1 What an elite is
An **elite** is one regular archetype with **affixes**, more HP, a visible rarity mark, a named reward, and **no respawn** (§6.5). It replaces one regular encounter group; it does not add enemy budget (an elite plus escorts uses the same points as the group it replaced). Elites are *not* bosses: no beacon, no phases, no Fragment. They exist to make the open world surprising between bosses and to teach the player what each counter-rule looks like before a boss uses it.

### 3.2 Encounter model
Pillars §6.2 gives each chunk a budget `B = 6 + 4·T`. It is now **split into encounters** placed at hashed positions: **2 per chunk in T0–T1, 3 per chunk from T2** (budget divided evenly; Swarmer groups stay one encounter). Each encounter, when the chunk loads, makes **one elite roll**:

| Tier of the chunk | Encounters per chunk | P(encounter is elite) | Share of elites that are rare | Share that are legendary | Elites per chunk (simulated, incl. pity) |
|---|---|---|---|---|---|
| T0 | 2 | 4 % | 0 % | 0 % | 0.080 |
| T1 | 2 | 5 % | 15 % | 0 % | 0.098 |
| T2 | 3 | 5 % | 27 % | 1 % | 0.152 |
| T3 | 3 | 6 % | 36 % | 2.5 % | 0.182 |
| T4+ | 3 | 6 % | 42 % | 4 % | 0.180 |

An elite encounter is **one elite of the chosen base plus escorts worth at most one third of the encounter's budget** (regular units of the tier's pool). The remaining budget is dropped. Bases (and what is excluded):

| Base archetype | From tier | Not allowed with |
|---|---|---|
| Drifter | T0 | none |
| Shieldbearer | T1 | Bulwark, Mirrored (it already has a front arc) |
| Tank | T2 | Bulwark |
| Phaser | T2 | Phasing |
| Mirror | T3 | Mirrored |

Swarmers and stationary Snipers are never elite bases (Snipers appear as escorts).

### 3.3 Rarity and stats
Rarity multiplies **after** tier scaling (HP ×(1 + 0.35·T), pillars §5.2). Damage dealt never exceeds 1 per hit for elites (pillars §5.4: nothing regular deals more than 1); **elite attack rates and count of projectiles** are what rarity scales.

| Rarity | Affixes | HP | Speed | Extra | Wake distance |
|---|---|---|---|---|---|
| **Common elite** | 1 | ×2.5 | ×1.0 | none | 700 px |
| **Rare elite** | 2 (different groups, §3.4) | ×4 | ×1.0 | its affixes run at "rare intensity" (column "Rare intensity" below) | 700 px |
| **Legendary elite** | 2 + a **named signature** (§3.5) | ×7 | ×1.1 | a signature mechanic nobody else has | 800 px |

Example: a T0 common elite Drifter has 30 × 1.0 × 2.5 = **75 HP**; a T3 rare elite Tank has 400 × 2.05 × 4 = **3,280 HP** (armor 5 still applies).

### 3.4 Affixes: world rules that counter lazy scripts, never restrict them
Every affix punishes **one habit** and rewards **one idea**. None blocks an API, takes a Sense away or limits bullet counts (P2). Affixes are in three **groups**; a rare elite takes its two affixes from **two different groups**; **Defensive** affixes are mutually exclusive with each other.

| Affix | Group | From tier | Effect (common intensity) | Rare intensity | Counters (the habit it punishes) | What solves it |
|---|---|---|---|---|---|---|
| **Bulwark** | Defensive | T1 | 120° front arc **absorbs** bullets (visible arc), like the Shieldbearer | arc 150°, rotates toward the player at 45°/s | Straight volleys from the front | Curved, looping or orbiting bullets; flanking |
| **Mirrored** | Defensive | T1 | 90° front arc **reflects** (enemy-owned, 1 damage, one reflection, pillars §5.4) | arc 120°, rotates at 90°/s | Dense straight scripts (their own volley comes back) | Indirect shots, bullets from the sides, fewer bullets per volley |
| **Phasing** | Defensive | T1 | **Absorbs** all bullets except in a 0.4 s pulse every 2.5 s (the Phaser rule) | pulse every 3.0 s, 0.3 s long | Constant streams | Bursts timed to the pulse, `sense.enemies_in` timing scripts |
| **Warded** | Defensive | T1 | While **at least one escort is alive within 400 px**, damage taken ×0.5 | ×0.35 | Ignoring escorts, tunnel vision | Triage targeting, area shots |
| **Splitting** | Spawn | T0 | On death splits into **2 halves** (40 % HP each, ×1.3 speed, no further splits) | 3 halves at 30 % HP | One huge single hit (overkill is wasted) | Sustained or area damage, follow-up |
| **Summoner** | Spawn | T0 | Every 6 s summons **2 Swarmers** (max 6 alive, they drop nothing) | every 4 s, max 8 | Tunnel vision on the elite itself | Area coverage, `sense.enemies_in` |
| **Blinker** | Offensive/Utility | T2 | After taking **≥ 15 damage within 1 s** it teleports 400 px (0.5 s telegraph ring at the target, once per 4 s) | threshold 10, 300 px, cooldown 3 s | Burst dumps of damage in one second | Sustained, tracking damage |
| **Null-shot** | Offensive/Utility | T2 | Every 5 s fires one telegraphed **Null bullet** (≥ 0.8 s warning, white-violet). It ignores the script flag `player.invulnerable` and overheal, **but respects engine i-frames** (pillars §12.1/§12.2). 1 damage | every 4 s, two bullets | Scripts that try to skip the fight (god mode, auto-heal) | Dash and movement; engine i-frames |

*Exclusions:* Splitting × Summoner (spawn overload), Blinker × Phasing (both anti-burst), plus the base exclusions of §3.2. **Affix choice** is `hash(seed, chunk, encounter, "aff", n)` over the allowed set for that tier/base, `n` = 0, 1.

Reuse of existing engine work (pillars §5.5): Bulwark, Mirrored and Phasing are **per-`Hurtbox` hit responses** (`HIT/ABSORB/REFLECT` with an arc), the same code the Shieldbearer, Mirror and Phaser need. Null-shot needs a **`null_pierce` flag** on `ShotRequest`/`BulletPool` (one bit) honoured by the player's damage path. Splitting and Summoner are enemy-side scripts. Nothing here changes the Lua API.

### 3.5 Legendary elites: named signatures
A legendary elite is a **curated combination with one bespoke twist** (one of four, chosen by hash), so each reads as a creature, not a stat block:

| Name | Base | Affixes | Signature twist |
|---|---|---|---|
| **Hydra** | Drifter (T2+) or Tank (T3+) | Splitting + Summoner (exception to the exclusion) | Halves split once more; each Summoner spawn is a half-HP Drifter |
| **Prism Knight** | Shieldbearer / Mirror | Mirrored + Warded | The reflecting arc **orbits** the body at 180°/s; reflected bullets come back at ±15° (a fan of two) |
| **Nullwalker** | Drifter / Phaser | Null-shot + Blinker | Fires a **Null ring** every 8 s (telegraphed, one gap to dash through); blinks to the player's last position instead of away |
| **Phase Choir** | Phaser | Phasing + Warded | Three escort Phasers pulse in a **fixed 0.3 s stagger** around it; the group is only vulnerable in the one gap each cycle |

### 3.6 The Herald: the guaranteed first elite
Natural elite odds alone give a **median of 75 s and a p90 of 186 s** of straight walking after the tutorial (§9), so some players would wait 3 minutes. G1 is met with a **dynamic, time-based guarantee**:

- When the player **leaves the 512 px safe zone** (or 60 s after the tutorial targets are cleared, whichever is first), start a timer of `58 + 20·u` s, `u = hash(seed, "herald")` (so 58–78 s).
- If no elite has woken by then, the **Herald** spawns **1,200 px ahead of the player's heading** (clamped to Tier 0 chunks, outside the safe zone): a **common elite, Drifter base, with one affix from {Splitting, Summoner}** (both beaten by the default script). It is announced by the common-elite audio sting.
- It spawns once per save; killing any elite or the Herald cancels it.
- **Result (simulation §9):** first elite at a **median of 64 s, p90 75 s**; 100 % within 80 s.

The Herald is the **single intentional exception to "the world is a pure function of the seed"**: its position depends on the player's heading and time. It is not saved as part of the layout, only the fact that it happened. (Open question Q21.)

## 4. Boss frequency and boss rarity

### 4.1 Reading of the owner's wish
"Bosses stay common near the start and get rarer further out" is implemented as two separate dials, both by tier:

1. **Frequency falls** with tier (a tier-dependent quota base). A player at T1 sees a beacon every **~2 min** of straight walking; at T4+ every **~5 min**.
2. **Rarity of the variant rises** with tier: from only common bosses in T0, to about one in six being rare in T1, to **~45 % rare and ~22 % legendary** at T4+.

So a "common" boss gets less common further out, and the *special* ones become the point of going far. (Open question Q17 asks whether this is what Karyu means.)

### 4.2 Quota per region (replaces the single `p_first` of pillars §6.3)
The structure of the hybrid rule is unchanged (canonical order, quota per region, distance pity); only the base probabilities depend on the region's tier `T = ring k`:

```
p_first  = BASE_FIRST[T]  + 0.05 * floor(d / 10)          # d = min(D∞ to nearest placed boss, 80); pity <= +0.40
p_second = BASE_SECOND[T]
```

| Tier | `BASE_FIRST` | `BASE_SECOND` |
|---|---|---|
| T0 | 0.30 | 0.08 |
| T1 | 0.25 | 0.06 |
| T2 | 0.18 | 0.04 |
| T3 | 0.12 | 0.03 |
| T4+ | 0.08 | 0.02 |

Simulated area per boss and the straight-walk beacon cadence (strip width 10 chunks, one chunk = 6.83 s; arithmetic as in pillars §6.3):

| Tier of the boss chunk | Chunks² per boss (simulated) | Chunks walked per new beacon (÷10) | **Time per new beacon** |
|---|---|---|---|
| T0 | 301 | 30.1 | 206 s (few bosses; the safe zone and `D∞ ≥ 4` rule apply) |
| T1 | 171 | 17.1 | **117 s** |
| T2 | 326 | 32.6 | **223 s** |
| T3 | 405 | 40.5 | **277 s** |
| T4+ | 454 | 45.4 | **310 s ≈ 5.2 min** |

### 4.3 Boss rarity odds (per boss, decided by the boss's own chunk tier)
Rolls are made **per boss in canonical order** (§6.3). Base odds, then deterministic pity:

| Tier | Rare (base) | Legendary (base) | Common = rest |
|---|---|---|---|
| T0 | 0 % | 0 % | 100 % |
| T1 | 10 % | 0 % | 90 % |
| T2 | 22 % | 3 % | 75 % |
| T3 | 33 % | 10 % | 57 % |
| T4+ | 42 % | 16 % | 42 % |

**Pity (deterministic, by boss ordinal, §6.4):** `since_rare` = bosses of tier ≥ 1 since the last rare-or-legendary one; `since_leg` = bosses of tier ≥ 3 since the last legendary one (a legendary at any tier resets it). Rare chance `+8 %` per boss in `since_rare` (cap +40 %); legendary chance `+2 %` per boss in `since_leg` (T3+, cap +20 %). **Hard guarantees:** from T2, **at least one rare-or-better in every 6 consecutive bosses**; from T3, **at least one legendary in every 12 consecutive bosses**. The starter boss is always common and not counted.

**Realised shares after pity (simulation, 40 seeds):**

| Tier | Common | Rare | Legendary |
|---|---|---|---|
| T0 | 100 % | 0 % | 0 % |
| T1 | 85.6 % | 14.4 % | 0 % |
| T2 | 65.6 % | 32.5 % | 1.9 % |
| T3 | 40.1 % | 44.1 % | 15.8 % |
| T4+ | 32.7 % | 45.5 % | 21.7 % |

(The legendary row at T2 is small by design: it is the first hint that legendaries exist.)

## 5. Rare and legendary bosses: what actually changes

Rarity never changes the boss's **type** (the Fragment and Sense it carries, pillars §4); it changes **how the fight plays**.

| Rarity | HP | Behaviour | Look |
|---|---|---|---|
| **Common** | ×1.0 | Baseline fight (pillars §5.3) | Boss hue, standard outline |
| **Rare** | ×1.2 | One **variant twist** (table below) added from phase 2 | Double outline, accent ring (§8) |
| **Legendary** | ×1.3 | The rare twist **plus Phase ★**: an extra phase with a unique mechanic (below). It is a new phase, not just more HP | Crown ticks, gold accent, slow pulse |

### 5.1 Rare variant twists (one per boss type, working titles)

| Boss (pool) | Rare twist | What it asks of the script |
|---|---|---|
| **Warden** (A) | Its roll-call ring now rotates toward the player's *last 2 s of movement* | Not standing still; strafing patterns |
| **Sower** (A) | Seeds that survive 3 s sprout a second wave | Clearing seeds early (`sense.enemy_bullets`) |
| **Prism** (A) | Weak point alternates between two faces every 4 s | Timing; `sense.boss` |
| **Lattice** (B) | The lattice rotates 20° per phase | Re-aiming; angle-aware scripts |
| **Mantle** (B) | The mantle opens a **second, smaller gap** that closes in 1 s | Burst shots through gaps |
| **Archivist** (C) | Records your **dominant pattern signature** (pillars §5.3) 5 s earlier than the Habituation rule | Changing patterns sooner |

### 5.2 Legendary Phase ★ (one per boss type): extra phase, unique mechanic
Each Phase ★ is entered at **15 % HP** (it comes *after* the normal last phase, so the fight does not change until the end) and leans into scripts that try to **skip the fight rather than solve it**. A player who simply fights it gets through it; none of it needs a particular script.

| Boss | Phase ★ | Mechanic (and the counter it expects) |
|---|---|---|
| **Warden** | **Writ**: every 6 s a **Null ring** (white-violet, 1 s telegraph, one gap) | Ignores the `player.invulnerable` flag and overheal; engine i-frames and the dash still work |
| **Sower** | **Overgrowth**: seed fields **flip bullet ownership**: a player bullet touching a field becomes enemy-owned (once, same rule as a reflection) | Scripts that pour bullets through the field; fewer, better-aimed bullets |
| **Prism** | **Refraction**: a hit on a body face spawns **3 enemy bullets** from the hit point at ±20° | Weak-point precision instead of body spam |
| **Lattice** | **Equalizer** (pillars §12.1): reads `player.hp / max_hp` and **scales its attacks to it**: overheal becomes boss damage (+1 boss tier per 2 overheal pips) | Fighting at normal HP, or at a lower one |
| **Mantle** | **Rift** (pillars §12.1): any `pos` write or position jump over 600 px opens a Rift at origin and destination that emits a telegraphed 1-damage ring and gives the boss a charge | Moving by walking and dashing |
| **Archivist** | **Echo**: for 10 s it **replays your last 8 s of bullet signatures** as enemy bullets aimed at you (enemy-owned, 1 damage) | Changing your pattern mid-fight, which is exactly what the Habituation rule already pushes you to do |

The **Eater** (pillars §12.1) stays a flavour mechanic only for the boss that carries it and is not used here (it needs a Corruption meter).

## 6. Deterministic generation

### 6.1 The hash
All rolls use **one stable integer hash**, not GDScript `hash()` (not guaranteed stable across versions and platforms): a 64-bit **splitmix64** over a 64-bit **FNV-1a** of the tag string mixed with the integer coordinates. A roll is `u = ((h >> 11) & 0x1FFFFFFFFFFFFF) / 2^53` ∈ [0, 1) (mask after shifting: GDScript `>>` is arithmetic on signed ints). Tags used here:

`"starter"`, `"boss1"`, `"boss2"`, `"bpos"`, `"brar"`, `"enc"`, `"elite"`, `"erar"`, `"eaff"`, `"eforce"`, `"herald"`.

### 6.2 What is decided where

| Decision | Inputs | Scope |
|---|---|---|
| Starter boss | `seed`, `"starter"` | Once; always common; `D∞` 8.5 or 9.5 (T1) |
| Boss count in a region | `seed`, `(rx, ry)`, `"boss1"/"boss2"`, `d` (from earlier regions only) | Region pass |
| Boss position | `seed`, `(rx, ry)`, `i`, `attempt` | Region pass |
| **Boss rarity** | the boss's canonical **ordinal** (position in the list of all bosses in canonical region order), its tier, `since_rare`, `since_leg` | Region pass |
| Encounter positions, elite roll, elite rarity, affixes | `seed`, `(cx, cy)`, encounter index, tag | Per chunk, on load |
| **Elite region pity** | the region's elites, `regions_since_rare`, `regions_since_leg` (canonical region order) | Region pass |
| Herald | `seed`, `"herald"` + the **runtime** exit time and heading | The one dynamic exception (§3.6) |

### 6.3 Region pass (pseudocode)
Regions are processed in the canonical order of pillars §6.3 (**ring `k` ascending, then `(ry, rx)` ascending**), once per save, cached. A region's result depends only on earlier regions:

```
state: placed_bosses[], since_rare = 0, since_leg = 0, regions_no_rare = 0, regions_no_leg = 0
starter = pick(hash(seed,"starter")); placed_bosses.add(starter, rarity = COMMON)

for region R in canonical order:
    T = ring(R)
    d = min(D∞(centre(R), nearest placed boss), 80)
    n = (u(R,"boss1") < BASE_FIRST[T] + 0.05*floor(d/10)) + (u(R,"boss2") < BASE_SECOND[T])
    for i in 0 .. n-1:
        c = first of 10 hashed chunk candidates in R that is >= 6 (D∞) from every placed boss and >= 4 from the origin
        if none: continue
        Tb = tier(c)
        rarity = roll_boss_rarity(Tb, since_rare, since_leg, u(R,i,"brar"))   # §4.3, including the 6/12 guarantees
        update since_rare (if Tb >= 1) and since_leg (if Tb >= 3 or rarity == LEGENDARY)
        placed_bosses.add(c, rarity)
    elites(R): for each chunk of R (not a boss chunk), for each encounter: roll elite, rarity, affixes
    if T >= 1: regions_no_rare = (R has a rare+ elite) ? 0 : regions_no_rare + 1
               if regions_no_rare >= 3:  force one RARE elite (§6.4); regions_no_rare = 0
    if T >= 3: regions_no_leg  = (R has a legendary elite) ? 0 : regions_no_leg + 1
               if regions_no_leg >= 12:  force one LEGENDARY elite; regions_no_leg = 0
```

### 6.4 Pity rules, stated once
- **Boss pity** counts bosses in canonical ordinal order, never "bosses the player has met", so two players with the same seed see the same bosses with the same rarities.
- **Elite pity** is **per region** (a region with no rare-or-better elite increments a counter; **3** such regions in a row force one rare elite in the next, from T1 on; **12** with no legendary force a legendary from T3 on). Forced elites are placed in a non-boss chunk of the region with **`D∞ ≥ 8` from the origin** (never in T0), by hash.
- **Costs:** the whole pass is cheap (ring 34 is 1,225 regions × 64 chunks × ≤3 encounters), cached once per save. On web (no threads) it runs in slices over frames while the player walks, always staying ≥ 2 rings ahead.

### 6.5 Persistence
- **Killed elites do not respawn.** Save a set of `(chunk, encounter_index)` for killed elites (a per-chunk bitmask, ≤ 3 bits). Regular enemies keep the 5-minute respawn rule of pillars §6.2. (Open question Q20.)
- **Killed bosses:** unchanged (pillars §6.3): the boss chunk becomes ordinary. Rarity is part of the generated boss, so a re-load yields the same variant until it is killed.
- The Herald is saved as a single flag (`herald_done`).

## 7. Rewards

Rewards depend **only on what was killed and its rarity**. Nothing here is conditional on how the player's script behaved.

### 7.1 Currencies and sinks
- **Shards** (dropped as small white motes that fly to the player; one number in the editor footer): an additional source of **Sense Level II**. **25 Shards = one Level II token**, spendable on any Sense whose Level I the player holds. Level I Senses, tier access and Fragments are **never** for sale.
- **Codex pages:** each affix gets a one-screen Codex page ("what this does, how people beat it") the first time it is killed (P4: learn by finding). Rare and legendary variants add a **variant page** per boss type.
- **Trophies:** cosmetic bullet trails and the player's ring accent (no stats).

### 7.2 Table

| Kill | Shards | Codex | Other |
|---|---|---|---|
| Common elite | 1 | Affix page (first kill of that affix) | none |
| Rare elite | 3 | Affix pages (first time as rare: "rare intensity" note) | none |
| Legendary elite | 10 | Signature page (first kill of each) | A **trophy** cosmetic per signature |
| **Common boss** | 5 | Boss page | **Fragment**: Level I of its Sense (first kill of this type, any rarity) |
| **Rare boss** | 10 | Boss page + variant page | Fragment if not yet owned **and Level II of that boss's Sense** (without spending Shards) |
| **Legendary boss** | 25 (= one token) | Boss page + variant page + Phase ★ page | Fragment if not owned, Level II of its Sense, and a **legend trophy** (cosmetic trail + a name line in the Codex) |

Fit with `pillars.md` §4: Fragments, Level I and Codex are untouched. A boss of a type already killed (a second legendary Warden, say) gives Shards, the variant page and trophy only. **Gating:** the first kill of a boss type at *any* rarity gives the Fragment, so a player who never meets a rare or legendary boss still gets every Level I Sense; no rarity gates tier progression. Level II also stays available through the rule already in `pillars.md` §12.4; the Shard and rare/legendary paths in this doc **add** routes, they do not replace it.

### 7.3 Pacing check (from the simulation, T4+)
With 0.18 elites per chunk (54 % common, 42 % rare, 4 % legendary) the average elite is worth ≈ 0.54·1 + 0.42·3 + 0.04·10 ≈ **2.2 Shards**, so one Level II token costs about **11 elite kills**, i.e. around 10–15 minutes of mixed exploring and fighting in the far world. Six Senses at Level II is therefore an hours-long goal, which matches the meta loop of pillars §2.

## 8. Visual and audio language per rarity

Rule: **shape and outline carry the rarity** (readable in grayscale and for colour-blind players, P3), colour is an accent, audio is a confirmation. Cues are **drawn by the enemy's own `_draw()`**, with a rarity function shared by all enemies.

### 8.1 Elites

| | Shape language | Outline | Accent (starting values) | Behaviour tell | Audio sting (synth, pentatonic) |
|---|---|---|---|---|---|
| **Common elite** | Base shape + **one thin outer ring** at 1.35× radius | 3 px (regular enemies 2 px) | white `#F2F2F2` ring; body keeps its role hue | One small **affix glyph** orbits (circle = Spawn, square = Defensive, triangle = Offensive) | Rising fifth, triangle wave, 0.4 s, on wake |
| **Rare elite** | Base shape + **double ring** with **three triangular ticks** | 4 px | cyan `#4DE1FF` rings | Two glyphs orbit; telegraphs 20 % brighter | 3-note arpeggio + a quiet shimmer tail, 0.8 s |
| **Legendary elite** | Base shape + **ring crowned with four ticks and a slow 1.5 s pulse** | 5 px | amber `#FFB347` crown | Name line under it for 2 s on wake; signature glyph | Low drone swell + 4-note motif, ambient ducked 3 dB for 2 s |

### 8.2 Bosses (cues on top of the existing boss look, pillars §8.1)

| | Cue on the boss | Beacon tick (§6.4 of pillars) | Hum (§6.4 of pillars) |
|---|---|---|---|
| **Common** | Boss hue, standard outline | Thin tick in the boss hue | Single sine |
| **Rare** | **Double outline** and one accent ring in cyan | **Double tick** | Hum plus a detuned second voice (beating) |
| **Legendary** | **Crown of ticks**, amber accent, slow pulse of the outline width (3 → 5 px) | Tick with an **amber pulse** (1.5 s) | Hum plus a fifth above, slowly swelling |

### 8.3 Clarity rules
- A rarity cue never overlaps the boss weak point or a telegraph; telegraph colours keep priority (enemy bullets stay warm `#FF5A4D`, Null attacks stay white-violet, pillars §12.1).
- Max **12 elites with cues** drawn on screen; beyond that, cues fade to the outline only (cost cap).
- Every audio cue has a visual equivalent: a 0.3 s brightening of the ring (accessibility).

### 8.4 GL Compatibility fallbacks
The project renders with **GL Compatibility on desktop, web and mobile** (`project.godot`). Nothing above requires a post-process.

| Cue | Implemented as | Compatibility-safe? | Fallback if a platform fails the QA check |
|---|---|---|---|
| Rings, ticks, crowns, glyphs, outlines | `CanvasItem._draw()` (`draw_arc`, `draw_line`, `draw_colored_polygon`) | Yes | None needed |
| Pulse | `_process` modulating `modulate.a` / line width | Yes | Static ring (no pulse) |
| Legendary halo | A low-alpha disc with a `CanvasItemMaterial` **blend mode ADD** | Yes (2D blend modes work in Compatibility; **QA to confirm on web and Android**) | Same disc with normal alpha blending and a brighter outline |
| Beacon tick | `_draw()` on the HUD layer | Yes | None |
| Boss glow / grid warp | Not used by rarity | n/a | Already covered in pillars §8.1 |
| Audio stings | `AudioStreamGenerator` | Yes; starts after the first user gesture on web | Pre-rendered short `.ogg` loops if the generator misses its budget |

## 9. Simulation

`docs/design/sim/rarity_sim.py` (Python 3 + NumPy; `python3 rarity_sim.py 40 20`, about 4 minutes) builds worlds with the exact rules above and walks 300 px/s walkers through them. Output in `docs/design/sim/results.txt`.

**Setup:** 40 seeds × 20 walks = 800 walks per model; each starts at the tutorial exit (512 px from the origin, random heading) and runs at most 30 minutes; 34 region rings; elites wake at 700 px; a boss counts as **sighted** at 5 chunks (beacon) and **reached** at 1,000 px. Models: **Straight** (constant heading, no fights) and **Wander** (heading change of N(0°, 50°) every 10 s, and a pause of 20 s / 30 s / 45 s after waking a common / rare / legendary elite, to stand in for fighting; boss times do not include the boss fight). "Found %" is the share of walks that met the target within 30 minutes; **median / p90 are over the walks that found it**; **E[t]** is a censoring-aware mean (total walked time ÷ number of finds), the right "expected" figure when part of the walks never find the target. All times are in seconds.

| Target (time from tutorial exit) | Straight: found % | Median | p90 | E[t] | Wander: found % | Median | p90 | E[t] |
|---|---|---|---|---|---|---|---|---|
| **First elite, natural only** | 100 | 75.5 s | 186 s | 88 s | 100 | 80.5 s | 252 s | 109 s |
| **First elite, with Herald** | 100 | **64 s** | **75 s** | **51 s** | 100 | **63 s** | **75 s** | **50 s** |
| **First rare elite** | 100 | 231 s (3.9 min) | 413 s | 249 s | 97.5 | 547 s (9.1 min) | 1,179 s | 669 s |
| **First legendary elite** | 66.4 | 762 s (12.7 min) | 1,518 s | 1,747 s (29 min) | 19.8 | 1,196 s | 1,651 s | 8,482 s (2.4 h) |
| First boss, sighted | 99.9 | 52 s | 361 s | 131 s | 99.5 | 73 s | 364 s | 153 s |
| First boss, reached | 99.9 | 83 s | 392 s | 161 s | 99.5 | 103 s | 394 s | 183 s |
| **First rare boss, sighted** | 98.0 | 350 s (5.8 min) | 1,005 s | 502 s (8.4 min) | 67.4 | 635 s | 1,496 s | 1,594 s (26.6 min) |
| **First rare boss, reached** | 98.0 | 381 s | 1,035 s | 532 s | 67.4 | 665 s | 1,526 s | 1,625 s |
| **First legendary boss, sighted** | 69.6 | 768 s (12.8 min) | 1,491 s | 1,601 s (26.7 min) | 16.2 | 1,179 s | 1,733 s | 10,416 s (2.9 h) |
| **First legendary boss, reached** | 69.6 | 799 s | 1,521 s | 1,632 s (27 min) | 16.2 | 1,209 s | 1,763 s | 10,446 s |

**Reading it.**
- **G1 holds:** the Herald makes the first elite arrive at **64 s median, 75 s at p90** for both movement models.
- **Rare elites** arrive after about 4 minutes of straight walking (9 minutes if wandering and fighting): "early excitement" without being routine.
- **Rare bosses** are a **6–8 minute** event of straight walking; **legendary bosses** about **one per 27 minutes of straight far-world walking** (≈ 2.9 hours for the slow wandering model). That is deliberately very rare; Q18 asks whether it is too rare for the Wander style.
- Straight-walk **beacon cadence per tier**: T1 117 s, T2 223 s, T3 277 s, T4+ 310 s (§4.2), so boss *frequency* does fall outward.
- Estimators for the legendary targets rest on few finds in a 30-minute horizon (66–70 % found for Straight, 16–20 % for Wander); treat them as order-of-magnitude, and re-run with a longer horizon if the table is tuned.

## 10. Engineering notes

1. **Pure function first.** `WorldGen.region_summary(seed, rx, ry, state)` (no node, no scene) returns bosses (chunk, type, rarity) and elite specs per chunk; the canonical-order driver holds `state`. Everything else (spawning nodes, beacons) reads it.
2. **Golden tests (CI):** for 3 fixed seeds, the summary of rings 0–6 hashes to a recorded value; plus *order-independence*: generating region rings in canonical order vs. requesting a far region first (which must walk the canonical order up to it) yields the same list.
3. **Data-driven:** `AffixDef` and `RarityDef` resources (fields per §3.4 and §3.3) so balancing is a data change; `rarity_table.tres` mirrors the tables in §2–§4 and is read by the simulation harness (a Python script that parses the `.tres` could keep doc and code in sync; optional).
4. **Engine items** (extends pillars §5.5): per-`Hurtbox` `ABSORB/REFLECT` arcs (shared with Shieldbearer/Mirror/Phaser); a `null_pierce` bit on `ShotRequest`/`BulletPool`; a bullet **owner flip** (Sower Overgrowth, Mirrored: same code path as reflection); a `signature` recorder (Archivist Echo reuses the Habituation signature buckets of pillars §5.3).
5. **Budgets:** elites and escorts count against the per-platform enemy-bullet reserve (pillars §3.3). Summoner caps (6/8 alive) and Splitting halves must respect it; Null rings are ≤ 24 bullets.
6. **Cue cost cap:** ≤ 12 cue-drawing elites on screen (§8.3); `draw_arc` segment count 32.
7. **QA checklist (GL Compatibility):** web and Android: blend-mode ADD halo; the shimmer sting from `AudioStreamGenerator`; no cue depends on a shader that is Forward+/Mobile-only.

## 11. New open questions

Added to the open list in [`pillars.md`](pillars.md): **Q17** boss frequency vs. rarity reading, **Q18** legendary frequency target, **Q19** Shards and Level II, **Q20** elite respawn/farming, **Q21** the Herald as the one dynamic exception, **Q22** beacon radius by rarity, **Q23** launch affix set, **Q24** visual cue approach and QA check on GL Compatibility.
