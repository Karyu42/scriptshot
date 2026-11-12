# Scriptshot — First playable: elites slice

> Status: **build-order slice for implementation.** Companion to [`spawning-and-rarity.md`](spawning-and-rarity.md) (full elites/rarity spec) and [`pillars.md`](pillars.md) (combat, world, decisions log). This file covers **only the first playable minutes**: safe zone, T0 regulars, the Herald, T0 common elites, then the rest of the Q23 affix set. It does not retune rarity, odds, or affixes. **Every number is a starting value** already fixed in those two docs, except the slice defaults in §5 (gaps those docs do not pin). Do not reopen Q17–Q24, Q20 (elites never respawn), or Q21 (the Herald is the one seed-purity exception). The first-run content past this file (rooms, lessons, the common Warden, `enemies_in`) is [`vertical-slice.md`](vertical-slice.md). Bosses stay out of L0–L4.

Checked against `main` @ `aa83001` (through merged PR #15). Engineering is currently on hybrid C++ bullets + M1 Lua. L0–L3 do not wait on that work: they sit on the GDScript body/bullet core already on `main` (`Health`, dash, reflect, `TrainingDummy`, `ShotRequest.pierces_script_invuln` from PR #4). Scripts may write player state; this slice adds no bans, marks, leaderboards, or in-game script sharing.

## 0. Contents

1. Out of scope
2. Build layers
3. Data contracts
4. Acceptance checklist
5. Open blockers (defaults, so engineering can proceed)
6. Escalate

## 1. Out of scope

Ship none of these in this slice. They stay specified in the companion docs.

| Deferred | Where it already lives |
|---|---|
| Rare and legendary **elites** (rolls, pity, forced elites, double rings, ticks, crowns) | spawning §3.2–§3.3, §6.4, §8.1 |
| Legendary signatures. **Hydra** is the one signature whose affixes exist after Q23 (Splitting + Summoner, the exclusion exception, Drifter T2+ / Tank T3+). It is still legendary and out of this slice. Prism Knight, Nullwalker, Phase Choir need Mirrored, Blinker, or Warded | spawning §3.5 |
| Affixes **Mirrored, Warded, Blinker** | spawning §3.4, Q23 |
| T1+ archetype pool (Shieldbearer, Sniper, Tank, Phaser, Mirror) and T1+ chunks | pillars §5.1–§5.2 |
| Bosses, boss rarity, beacons, hum, grid warp, Habituation, Null rings, Equalizer, Rift, Eater. Not this file; the handcrafted common Warden is [`vertical-slice.md`](vertical-slice.md) | pillars §5.3, §6.3–§6.4, §12; spawning §4–§5 |
| Full region pass, ordinal boss pity, elite region pity, golden hashes of rings 0–6 | spawning §6, §10.2 |
| `RarityDef` / `rarity_table.tres` for rare and legendary rows | spawning §10.3 |
| Codex pages, trophies, Sense Level I/II, Shard **spending** (25 = one token). A **stub Shard counter** is in L3; nothing spends it | spawning §7; pillars §4, §12.4 |
| Constrained mode | pillars §11, Q10–Q11 |
| In-game editor, hot reload, capability prompt, leaderboards, in-game script sharing | pillars §2, §7, §10; Q15/Q16 |
| Sparse terrain blocks, `sense.terrain` | pillars §6.1 |
| Web/Android cue QA (legendary additive halo, `AudioStreamGenerator` on device). Shapes and the legendary halo are in code; device QA is still open ([issue #24](https://github.com/Karyu42/scriptshot/issues/24)). The halo is legendary-only (spawning §8.4): rare keeps the double ring, three ticks, and 4 px outline. The legendary 3 dB duck and the boss proximity hum are **INCOMPLETE / deferred** | spawning §10.7, Q24 |
| Tutorial **shielded** dummy (needs an absorb arc). Three plain targets ship in L0. The shield is the room-A dummy in [`vertical-slice.md`](vertical-slice.md), not one of the origin three | pillars §2 step 4 |

## 2. Build layers

Each layer is playable on its own. Do not start a layer before the previous layer's checklist rows pass. **L4 is optional for the very first build** and still inside Q23 (it is not a later-rarity feature).

Two cuts forced by `main` (no absorb arc on `Hurtbox`; Lua gameplay is not in `src/` yet):

- L0 targets are plain `TrainingDummy` nodes. The shielded dummy is L4, placed in room A of the vertical slice (the origin three stay plain).
- "Default/example script" means `BasicShot` (`src/player/basic_shot.gd`: 1 damage, interval 0.11 s) until `shots/default.lua` is wired. Both Herald affixes are solvable by that single bullet. Summoner columns: **common** 2 alive, 1 HP, every 6 s; **rare** 4 s, 2 per wave, max 8; **legendary** (Hydra) 6 s, 2 per wave, max 6, 105 HP Drifters. Do not retune `BasicShot` or `Health`. Herald HP stays 75.

Combat already on `main`, do not retune: 5 HP, regen +1 / 3 s after 5 s quiet, 0.75 s hit i-frames, dash 160 px / 0.2 s i-frames / 1.5 s cooldown, reflected bullets are enemy-owned and deal 1, respawn keeps everything (`Main.respawn_delay` 1.5 s, `RespawnPoints`).

### L0 — Safe zone and tutorial range

| Rule | Value |
|---|---|
| Safe zone | Euclidean **512 px** from the origin. **No spawns** (regular, elite, Herald, boss). Tutorial targets are scripted placements, not spawns |
| Targets | **3** `TrainingDummy`: 40 HP, body radius 22, respawn, non-hostile (no contact damage). About **300 px** from the origin. Slice placement: angles 0°, 120°, 240° (positions `(300, 0)`, `(-150, 260)`, `(-150, -260)` within a few px) |
| Herald arm | Start **one** timer when the player **first** leaves the safe zone (distance > 512), **or** 60 s after the tutorial targets are cleared, **whichever is first**. Cleared = each of the three has reached 0 HP at least once; a respawn does not un-clear. Re-entering the disk does not reset the timer. The timer length is L2 |
| Not in L0 | Editor prompt, time-slow, shielded dummy, hostile spawns |

### L1 — T0 regulars (Drifter + Swarmer)

Only **T0** chunks spawn. `T = floor(max(|x|, |y|) / 16384)`. A chunk with `T ≥ 1` spawns nothing in this slice.

| Rule | Value |
|---|---|
| Chunk | 2048×2048 px. Active ring: the **3×3** chunks with Chebyshev chunk-distance ≤ 1 from the player's chunk. Unload the rest |
| Budget | `B = 6 + 4·T` → **6** in T0, split evenly into **2 encounters** (3 points each). Drifter = 1, Swarmer group = 3. Points and the 2-encounter split are specified; which pack fills the 3 points is a §5 default |
| Drifter | 30 HP, 90 px/s toward the player once woken, contact damage 1, no shot. Fill `#7DA2FF`, **2 px** outline, `_draw()` circle |
| Swarmer | Group of 8–14, 6 HP each, 140 px/s erratic, contact damage 1, no shot, no drops. Fill `#7DE0C3`, 2 px outline, smaller circle. One group = one encounter |
| Wake | Idle until the player is within **700 px** Euclidean. Then use the move rule above |
| Contact | Overlap of player radius (14, the drawn body) and the enemy radius calls `Health.try_damage(1)` with **no** pierce flag. Engine i-frames and script invulnerability both block it. Tutorial targets do not |
| Respawn | A **regular** encounter that is empty when its chunk unloads stays gone until that chunk has been **continuously outside** the active ring for **5 min**, then the next load spawns it again from the same hash. Coming back earlier leaves it empty and the out-streak restarts on the next unload. **Elite encounters do not use this timer** (L3) |
| Bullet window | `BulletManager.world_bounds` is still `Rect2(-1312, -752, 2624, 1504)`. A fight 1,200 px out leaves that rect. Before L2 is playable, **re-centre that same rectangle on the camera** (pillars §6.1). Do not grow the sim |

### L2 — Herald (spawning §3.6, exact)

The Herald is the **one** seed-purity exception (Q21). Layout rolls stay pure functions of `(seed, coordinates, tag)`. Only this spawn depends on heading and time. Persist the flag, not the position.

Arm the timer in L0. Duration:

```
u = WorldGen.hash_u(seed, "herald")     # [0, 1)
delay = 58 + 20 * u                      # [58, 78) s
```

When the timer fires:

1. If `herald_done` is already set, do nothing.
2. If any elite has **woken** (player within 700 px of it) or any elite has been **killed** since arming, **cancel**: set `herald_done`, do not spawn.
3. Otherwise spawn **one** Herald and set `herald_done` immediately (a reload cannot spawn a second).

Spawn:

| Field | Value |
|---|---|
| Place | **1,200 px** along the player's heading, then clamp into T0 and outside the safe zone (§5 has the clamp) |
| What | **Common elite, Drifter base, exactly one affix** from {Splitting, Summoner}. No escorts. Not a chunk encounter: its death does **not** set a chunk bit |
| Stats | T0 common: HP `30 × 1.0 × 2.5 = 75`, speed `90 × 1.0`, wake 700 px, contact damage 1 |
| Affix roll | `hash_u(seed, "herald", "eaff")` over the two-affix set, uniform (§5 tags) |
| Splitting | On death, **2 halves**: 40% HP each (30), speed ×1.3 (117 px/s), no further splits, no Shard, no elite bit. Already awake |
| Summoner | Every **6 s**, **2** summons, max **2** alive, **1 HP** each. They spawn at **±90°**, spread along that flank so a wave does not stack, and drift to hold about **20 px** off the player's flank, out of the firing lane. They drop nothing |
| Cue | Common elite: thin ring at **1.35×** body radius, outline **3 px**, ring `#F2F2F2`, body keeps Drifter hue, one orbiting **circle** glyph (Spawn). On wake: rising-fifth triangle sting, **0.4 s**, plus a **0.3 s** ring brighten (the visual equivalent) |
| Once | One per save. Killing the Herald does not clear the flag (it is already set). Killing any other elite first also sets it (step 2) |

A quit mid-timer does **not** save the remaining time (only `herald_done` is saved). On load, if the flag is clear and the player is already outside the safe zone, arm immediately.

### L3 — T0 common elites

Per encounter, when the chunk **loads** (pure function of seed and chunk; no region state):

| Roll | T0 rule |
|---|---|
| Encounter count | 2 (indices 0 and 1). Bit 2 of the kill mask stays reserved for the later 3-encounter tiers |
| Elite? | `hash_u(seed, cx, cy, i, "elite") < 0.04` |
| Rarity | **Always common.** Do not roll `"erar"`. Hardcode rare = 0 and legendary = 0 (skip the roll) |
| Base | Drifter only |
| Affix | One, uniform over {Splitting, Summoner} via `hash_u(seed, cx, cy, i, "eaff", 0)`. Same numbers as the Herald |
| Escorts | At most **one third** of the encounter budget (1 point) of T0 regulars. A Swarmer group costs 3 and **cannot** escort. Remaining points are dropped. How the 1 point is spent: §5 |
| Budget | The elite **replaces** the regular pack. It does not add points on top |
| Wake / damage | 700 px; damage dealt per hit stays ≤ 1 (contact is 1) |
| Kill | Set bit `i` of that chunk's mask when the **elite body** dies (not when a half, summon, or escort dies). Halves and summons despawn with the chunk and are not saved |
| Respawn | A set bit never spawns again, including across unload and process restart (Q20). Escorts of that encounter stay gone with it. Regular encounters in the same chunk still use the L1 5-minute rule |
| Cue | Same common-elite ring, 3 px outline, circle glyph, sting + 0.3 s brighten as L2. `draw_arc` segment count **32**. Cap cue-drawing elites at **12** on screen; past that, outline only |
| Shard stub | `shards += 1` on that elite-body death only. No mote, no spend UI, no Codex |

Boss chunks are not known until the region pass exists. Do not block L3 on it. When a chunk is later marked as a boss chunk, spawn neither regulars nor elites there (the boss replaces them). Until then every T0 chunk uses the table above.

### L4 — Q23 affix engine (optional for the very first build)

Still first-playable, **after** L3. Not rolled in T0. Bulwark and Phasing are T1+; Null-shot is T2+. This layer adds the behaviors and a **forced-affix test scene** (a Drifter elite with the affix set in data). It does not open T1/T2 spawns and does not add Shieldbearer or Phaser to the pool.

`Hurtbox` on `main` is a full circle and always emits `hit`. Pillars §5.5: a per-hurtbox response `HIT / ABSORB / REFLECT` with facing and arc, evaluated at the contact point, plus `DespawnReason.ABSORBED`. This slice **tests ABSORB**. Include `REFLECT` in the enum so Mirrored does not need a second rewrite later; do not ship the Mirrored affix, and do not require a reflect test here. Reflected bullets already hurt (PR #4); leave that path alone.

| Affix | Common intensity (ship this) | Test |
|---|---|---|
| **Bulwark** (Defensive, T1) | **120°** front arc **absorbs** (bullet gone, no damage). Arc is visible. Facing = toward the player each frame (common intensity has no turn cap; the 45°/s cap is rare-only and unused) | A straight shot into the arc despawns and deals 0. A shot that hits outside the arc deals damage |
| **Phasing** (Defensive, T1) | Body **absorbs** all bullets except during a **0.4 s** pulse every **2.5 s**. Outline brightens during the pulse | Shots outside the pulse deal 0; shots during the pulse deal damage |
| **Null-shot** (Offensive, T2) | Every **5 s**, one enemy bullet, **1** damage, **≥ 0.8 s** telegraph, white-violet. `ShotRequest.pierces_script_invuln = true` (the `null_pierce` flag; already on `main`). Ignores the script flag `player.invulnerable` and overheal. **Respects engine i-frames** (hit 0.75 s, dash 0.2 s) | With script invulnerability on, the bullet still deals 1. During a dash, it deals 0 |

Telegraph drawing is unpinned beyond "≥ 0.8 s warning"; §5 gives a line so it can be built. Rare intensity (wider arc, slower pulse, two Null bullets) is data on `AffixDef` and **not executed** while rarity is hardcoded common.

Once ABSORB exists, the absorb dummy is the shielded target in room A of [`vertical-slice.md`](vertical-slice.md). The three origin dummies stay plain. (This replaces the earlier note that would have swapped one L0 dummy.) It stays non-hostile and is still not a spawn.

## 3. Data contracts

The hash and the encounter spec touch no node and no scene. Spawning code reads the spec and instances bodies.

### `WorldGen.hash_u(seed, ...parts) -> float`

One function for every roll in this slice. **Not** GDScript `hash()` (not stable across versions). **Not** `random.Random` in `docs/design/sim/rarity_sim.py` (that file is a cadence sim; its Herald delay is a uniform draw, not this hash).

Spec (spawning §6.1): 64-bit FNV-1a of the tag, mixed with the integer coordinates, then splitmix64, then

```
u = ((h >> 11) & 0x1FFFFFFFFFFFFF) / 2^53    # [0, 1)
```

The doc names the finalizer and not the byte layout. §5 pins the layout for this slice. Implement it once, next to a unit test with the vectors in §5.

Tags used here (from spawning §6.1's list): `"herald"`, `"elite"`, `"eaff"`, `"enc"`. `"erar"` and `"eforce"` are unused while rare/legendary stays 0. `"aff"` in spawning §3.4 means this same affix roll; call it `"eaff"`.

### Specs

`WorldGen.chunk_encounters(seed, cx, cy) -> Array[EncounterSpec]`

Pure. No `state` argument. T ≥ 1 returns `[]` in this slice.

`EncounterSpec` (RefCounted or a plain dictionary, one type either way):

| Field | Type | Meaning |
|---|---|---|
| `chunk` | `Vector2i` | `(cx, cy)` |
| `index` | `int` | 0 or 1 |
| `anchor` | `Vector2` | World px |
| `is_elite` | `bool` | |
| `rarity` | `int` | `0` common. No other value in this slice |
| `base` | `StringName` | `&"drifter"` when elite; regular packs use `members` |
| `affix_ids` | `Array[StringName]` | Length 1 when elite, else empty |
| `members` | `Array` | `{archetype: StringName, count: int}` regulars or escorts |
| `points_spent` | `int` | ≤ 3 |

`WorldGen.region_summary(seed, rx, ry, state)` stays the spawning §10 signature for the later boss pass. It is **not** a dependency of L0–L3. When it lands, it should call `chunk_encounters` and then drop encounters on boss chunks and apply pity. Pity must not change a T0 roll (forced elites are never in T0).

### `AffixDef` (Resource)

One `.tres` per affix, including the three L4 affixes, so balancing stays data. Fields below are the common-intensity columns of spawning §3.4. Rare-intensity fields may exist and must be unread while L3 hardcodes common.

| id | group | min_tier | Common parameters |
|---|---|---|---|
| `splitting` | Spawn | 0 | halves = 2, hp_fraction = 0.40, speed_mul = 1.3, resplit = false |
| `summoner` | Spawn | 0 | interval = 6, count = 2, max_alive = 2, summon_hp = 1, drop = false. Rare column: 4 s, 2 per wave, max 8 |
| `bulwark` | Defensive | 1 | arc_deg = 120, response = ABSORB, turn_deg_per_s = 0 |
| `phasing` | Defensive | 1 | period = 2.5, open = 0.4, response = ABSORB outside the pulse |
| `null_shot` | Offensive | 2 | interval = 5, bullets = 1, warning = 0.8, damage = 1, `pierces_script_invuln` = true |

Exclusions to encode even though this slice never rolls a pair: Splitting × Summoner, and the base exclusions in spawning §3.2. Hydra is the later exception, not a row in this table.

### Save fields

No save file exists on `main`. Slice file: `user://save.cfg` (ConfigFile). One slot.

| Key | Type | Set when |
|---|---|---|
| `world_seed` | int | First launch, then sticky. Tests pass a seed in and skip the random draw |
| `herald_done` | bool | Herald spawns, or the Herald is cancelled because an elite woke or was killed first. Default false |
| `elite_kills` | list of `{cx: int, cy: int, bits: int}` | `bits` is **≤ 3 bits** (0–7). T0 uses bits 0 and 1. Missing key = 0 |
| `regular_absent` | list of `{cx, cy, index, since_unix}` | L1 five-minute rule. Absent rows only |
| `shards` | int | +1 per elite body (Herald included). Default 0 |

Do not store Herald position, timer remainder, live HP, or script-behavior marks.

## 4. Acceptance checklist

Playable checks. Headless scene tests are enough for the rows marked *test*; the grayscale row is a look check.

**L0**

- [ ] Cold start at the origin: no hostile body inside 512 px. *test*
- [ ] Three dummies sit near 300 px, die, respawn, and never deal damage.
- [ ] Leaving the disk arms the Herald timer once. Killing all three dummies arms a 60 s clock if the player has not left. The earlier one wins. Walking back inside does not restart it. *test*

**L1**

- [ ] A T0 chunk loads 2 encounters, only Drifters and Swarmers, budget 3 each. A T1 chunk loads nothing. *test*
- [ ] Bodies match the palette in grayscale well enough to tell Drifter from Swarmer (hue plus size) with a 2 px outline.
- [ ] An idle pack does not chase at 701 px and does chase at 699 px. Contact deals 1, then 0 during the 0.75 s i-frames.
- [ ] Clear a regular encounter, leave its chunk, return before 5 min: still empty. Return after 5 min out: the same pack is back. *test*

**L2**

- [ ] With natural elite rolls forced off, **every seed**: leave the safe zone before the tutorial-clear clock, Herald **spawns** in `[58, 78)` s (`u` is in `[0, 1)`). Walking toward it wakes it about 500 px later (~1.7 s at 300 px/s), still inside 80 s of the arm. *test*
- [ ] With rolls on: if a natural elite wakes or dies first, `herald_done` is set and no Herald appears; otherwise the Herald still spawns by 78 s. *test*
- [ ] The Herald is a 75 HP Drifter with Splitting or Summoner, outside the safe zone and inside T0, including when the player is near the T0 edge. *test*
- [ ] Both affixes die to `BasicShot` (or `default.lua` if it is wired) without editing: Splitting produces exactly two non-splitting halves; Summoner never exceeds 2 summons, and one hit kills each.
- [ ] Reload after the Herald spawns or is cancelled: it does not spawn again. A reload **during** the countdown may restart the countdown (`herald_done` was still false).
- [ ] Ring, circle glyph, and 3 px outline read in grayscale. The 0.3 s brighten plays even if the sting is inaudible.

**L3**

- [ ] Elite iff `hash_u(seed, cx, cy, i, "elite") < 0.04`. Every elite row is common, Drifter, and Splitting or Summoner. A scan of `cx, cy` in `[-2, 2]` for seeds 1, 2, and 42 returns zero rare and zero legendary. *test*
- [ ] Kill an elite, unload the chunk, reload the process: that encounter is absent; a regular encounter in the same chunk can still respawn under L1. *test*
- [ ] `shards` increases by 1 for the elite body and by 0 for halves, summons, escorts, and regulars. *test*
- [ ] Same seed, same `chunk_encounters` output, asked in any chunk order. *test*

**L4** (only if the layer is in the build)

- [ ] Forced Bulwark Drifter: the 120° arc absorbs; the open side does not.
- [ ] Forced Phasing Drifter: vulnerable only in the 0.4 s window.
- [ ] Forced Null-shot: script `invulnerable` does not stop the bullet; dash i-frames do; `pierces_script_invuln` is set. *test*
- [ ] T0 `chunk_encounters` still never returns these three affixes. *test*
- [ ] The room-A dummy (vertical slice) shows a static absorb arc and still does not shoot or deal contact damage. The three origin dummies stay plain.

## 5. Open blockers

Underspecified in the companion docs. These defaults are **slice choices so the build can proceed**. They are not new rarity rules and not owner decisions. Change them in one place (`WorldGen` / the enemy scene) if playtests disagree.

### Hash byte layout

FNV-1a 64 (offset `14695981039346656037`, prime `1099511628211`), then the splitmix64 **avalanche only** (no added gamma):

```
z = fnv
z = (z xor (z >> 30)) * 0xBF58476D1CE4E5B9
z = (z xor (z >> 27)) * 0x94D049BB133111EB
z = z xor (z >> 31)
```

All products mod 2^64. Shifts on `z` are logical. In GDScript, `>>` is arithmetic: mask after the shift, as spawning §6.1 already requires for `u`.

Payload bytes: int64 little-endian `seed`, then for each part a `0x1F` separator and either UTF-8 (string) or int64 little-endian (int, two's complement).

Pinned vectors (`u` and, for `"herald"`, the delay):

| Call | `u` | Notes |
|---|---|---|
| `hash_u(1, "herald")` | 0.3877327727 | delay 65.7547 s |
| `hash_u(42, "herald")` | 0.8668172005 | delay 75.3363 s |
| `hash_u(1, "herald", "eaff")` | 0.8750332294 | ≥ 0.5 → Summoner under the uniform rule |
| `hash_u(1, 0, 0, 0, "elite")` | 0.2137598812 | ≥ 0.04 → not elite |

Uniform affix rule: sort the allowed ids (`splitting`, `summoner`), index `floor(u * n)`.

### Regular packs, escorts, anchors

- Encounter **0** = one Swarmer group (3 points). Encounter **1** = 3 Drifters. Every T0 chunk shows both archetypes. No new probability. An elite roll **replaces** that pack.
- Swarmer count = `8 + floor(hash_u(seed, cx, cy, i, "enc", "n") * 7)` (8 through 14).
- Erratic move: every 0.4 s, heading = direction to the player plus a uniform ±60° from `hash_u`, speed 140.
- Idle, before wake: drift at 40 px/s inside 96 px of the anchor.
- Elite escort: **always** the 1 legal point, as 1 Drifter, 48 px from the anchor. That is the maximum spawning §3.2 allows, not an extra body.
- Radii: Drifter 16 px, Swarmer 8 px, Splitting half 12 px. Glyph 6 px, orbit at 1.6× body radius, 90°/s.
- Anchor: inset the chunk by 256 px. Draw `x` and `y` from `hash_u(..., "enc", "x"|"y", salt)`. Reject a point with distance < 512, up to 8 salts. If all eight fail, use the inset-rectangle point farthest from the origin (always outside the disk).
- Herald heading: velocity if speed ≥ 20 px/s, else the aim direction, else `Vector2.RIGHT`.
- Herald clamp: start at `pos + heading * 1200`. If `max(|x|, |y|) > 16384 - 64`, scale toward the origin onto that square. If distance to origin < 512, push back out along the same vector to 512. (512 px is inside T0, so the second step cannot leave T0.)
- Sting: triangle wave, 440 Hz → 660 Hz (a fifth) over 0.4 s. Null-shot colour `#EDE4FF` (no white-violet hex is specified) and a line telegraph for 0.8 s, then the bullet along that line.
- New-game seed: `randi()`, stored. Tests inject the seed.

## 6. Escalate

None. Q17–Q24 stay as in the pillars decisions log. The §5 defaults are local and reversible; they do not need an owner or Chief of Staff call to start L0.
