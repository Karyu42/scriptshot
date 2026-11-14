# Scriptshot — Vertical slice

> Status: **content spec for the first-run slice.** Companions: [`pillars.md`](pillars.md), [`spawning-and-rarity.md`](spawning-and-rarity.md), [`first-playable-elites.md`](first-playable-elites.md), [`../scripting/api.md`](../scripting/api.md). L0–L4 in the first-playable doc stay the elite-body build; this file is the rooms, lessons, regulars, rarity placements, and the boss. **Q17–Q24, Q20, and Q21 stay as decided.** Numbers are starting values to playtest.
>
> **Q25 and Q26 are Decided (CoS call, Karyu may override), 2026-11-12.** The climax is a guaranteed **common Warden** that counts as the save's starter boss, in a compact tier-0 ribbon. The D∞ 8.5 / 9.5 exception applies only inside the slice footprint.

The slice is one save, one seed, about **15–25 minutes** for a new player who follows the hints. It ends when the Warden dies: a short victory card, `sense.enemies_in` at Level I, then the north gate into the existing tier-0 stream. No leaderboards, no in-game script sharing, no Constrained mode, no Shard spending, no Level II.

Checked against `main` (open-world scene `scenes/main.tscn`: `OpenGround`, `Dummies`, `ChunkStream`, `HeraldArm`, `HeraldDirector`). Player combat already on `main` is not retuned: 5 HP pips, regen +1 pip every 3 s after 5 s without damage, hit i-frames 0.75 s, dash 160 px with 0.2 s i-frames and a 1.5 s cooldown (`Health`, `DashState`), `Main.respawn_delay` 1.5 s, `RespawnPoints`. §14 GE-4 is the canonical restatement.

## 0. Contents

1. Run shape
2. Layout
3. Regular enemies
4. Elites and rarity
5. Boss: the Warden
6. Senses (SE contract)
7. Onboarding
8. Rarity cues (Q24 option A)
9. Audio and visual notes
10. GE build list
11. SE build list
12. Build order
13. Open product decisions
14. Engineer FAQ

## 1. Run shape

Cold start at the origin in room S, `shots/default.lua` already firing (§7). Time is real until the editor opens.

| Beat | What advances it | Target |
|---|---|---|
| Lessons 1–2 in S | East dummy dies under the damage check; north and south dummies die under the fan check | 3–5 min |
| Lesson 3 in A | Shielded dummy dies | 2–4 min |
| Lessons 4–5 in B | A killing blow lands while `player.hp <= 4`; a shot with speed ≥ 640 hits the plate | 2–4 min |
| Field C | Scripted Drifters, Swarmers, Shieldbearer, and Sniper are dead | 3–5 min |
| Rare elite in D | That elite body dies (not an escort, half, or summon) | 2–3 min |
| Warden in E | Core HP hits 0 | 4–6 min |

Walking the ribbon with no fights is about **32 s** at 300 px/s (arena centre is 9,664 px east of the origin). The minute targets include fighting and editing. The stopwatch is a playtest target, not a CI fail.

Death: wait 1.5 s, then respawn. The respawn point is chosen **when the respawn happens** (Game Designer call, §2). If no arena has been cleared by then, that point is the origin. If the Warden is already dead by then, it is `(9664, 0)`, even when the death itself came before the kill. HP back to max, dash and engine i-frames cleared, **everything else kept** (script, `state`, lesson flags, open gates, shards, sense unlocks, cleared packs). A living Warden resets to 900 HP, phase 1, husks gone, aggro off. Gates that already opened stay open. There is no quick-restart key. Death plus the 1.5 s respawn is the loop.

The Warden's death is the slice victory (§5.6).

## 2. Layout

Cell = **64 px** (the `HurtboxGrid` cell). Viewport is 1280×720; 1 world unit = 1 px. Rooms are walled. Walls are `StaticBody2D` rects in the `world_walls` group, drawn by `Arena` and registered with `BulletManager` the same way sandbox walls are. The floor outside rooms stays `OpenGround`. The ribbon is a node `SliceLayout` under `Main`, **not** streamed by `ChunkStream`, so unloading a chunk does not delete a room.

```
 y-
 |     S 24x18      G1    A 20x16     G2    B 20x16     G3    C 40x32          G4    D 24x20    G5    E 30x22
 x+  [-768..768] ----> [1024..2304] ----> [2560..3840] ----> [4096..6656]   ----> [6912..8448] ----> [8704..10624]
        origin              shield           pad+plate         field packs         rare elite         Warden
                                                                 |  G0 north, shut until victory
                                                                 +-- south door, always open, Hydra alcove
```

| Space | Rect (px, x, y, w, h) | Cells | Centre |
|---|---|---|---|
| S editor / safe | `(-768, -576, 1536, 1152)` | 24×18 | `(0, 0)` |
| Corridor G1 | `(768, -64, 256, 128)` | 4×2 | |
| A pattern | `(1024, -512, 1280, 1024)` | 20×16 | `(1664, 0)` |
| Corridor G2 | `(2304, -64, 256, 128)` | | |
| B conditional | `(2560, -512, 1280, 1024)` | 20×16 | `(3200, 0)` |
| Corridor G3 | `(3840, -64, 256, 128)` | | |
| C field | `(4096, -1024, 2560, 2048)` | 40×32 | `(5376, 0)` |
| Corridor G4 | `(6656, -64, 256, 128)` | | |
| D rare | `(6912, -640, 1536, 1280)` | 24×20 | `(7680, 0)` |
| Corridor G5 | `(8448, -64, 256, 128)` | | |
| E arena | `(8704, -704, 1920, 1408)` | 30×22 | `(9664, 0)` |
| Hydra alcove | `(7104, 640, 1024, 1024)` | 16×16 | `(7616, 1152)` |

Arena centre `(9664, 0)` is chunk `(4, 0)` (`WorldGen.chunk_of`). That chunk's centre is `(4.5, 0.5)` in chunk units, **D∞ 4.5, tier 0**. It is not a legal seed starter (those sit at D∞ 8.5 or 9.5). **Decided (CoS call, Karyu may override), Q26:** that distance exception applies only inside the slice footprint.

**Footprint** (procedural anchors whose point lies inside are dropped): `Rect2(-768, -1024, 11392, 2688)`. Chunks that only overlap the rect still spawn encounters whose anchors fall outside it. `WorldGen.chunk_encounters` is otherwise unchanged, including tier ≥ 1 returning nothing.

**Safe disk.** Euclidean 512 px, no hostile spawns, same as today. Room S's walls sit outside that disk. The three `TrainingDummy` nodes stay at `(300, 0)`, `(-150, 260)`, `(-150, -260)`, 40 HP, radius 22, non-hostile, respawn. They stay **plain**. The absorb dummy is in room A, which replaces the first-playable L4 note that would have swapped an origin dummy.

**Respawn and the field packs (Game Designer calls).** `field_drifters`, `field_swarmers`, `field_shield`, and `field_sniper` are the absent-since times of room C's four packs. A missing key defaults to **0**, so the pack is present. There are no per-lesson timestamps. The respawn point is read when the 1.5 s respawn fires, not when HP hits 0: if the Warden is dead by then, the player returns at `(9664, 0)` even though the death came first. There is no quick-restart key. Death and that respawn, keeping everything, are the loop.

**Walls and gates.** A room rect is the room's outer edge. Its walls are **16 px** thick and sit inside that rect. A corridor rect is the clear **128 px** passage; its side walls sit just outside it. Each shut gate G1–G5 is a **4 px** wall at the corridor's midpoint, colour `#3a4152` (G1 is `Rect2(894, -64, 4, 128)`). An open gate leaves the passage clear. **G0** has no corridor: it is a **16 px** segment of room C's north wall, x **5200–5456**. No key, no lock icon.

| Gate | Opens when | Stays open |
|---|---|---|
| G1 | Lessons 1 and 2 passed | yes, including after death |
| G2 | Lesson 3 passed | yes |
| G3 | Lessons 4 and 5 passed | yes |
| G4 | All four scripted packs in C are dead (Herald not required) | yes |
| G5 | The room-D elite **body** has died | yes |
| G0 (north wall of C, x `[5200, 5456]`, y `= -1024`) | Warden dead. The open bit is saved at the kill tick; the wall lifts on dismiss (§5.6) | yes |
| Alcove door (south wall of D, x `[7500, 7628]`) | Always open | — |

G0 is the join to the procedural world. Past it, `ChunkStream` runs the existing tier-0 rules (2 encounters, Drifter + Swarmer, 4% common elite, elites never respawn, 5-minute regular absence). This slice does **not** turn on tier-1 chunk spawns and does **not** implement the region boss pass. It does write `starter_consumed = true` on the Warden kill so that pass, when it lands, does not place a second starter. **Decided (CoS call, Karyu may override), Q25:** this common Warden counts as the save's starter boss.

**Herald redirect (`SliceLayout.redirect_herald`).** `HeraldDirector` still uses `58 + 20·u` seconds and the 1,200 px heading step, then this redirect. While **G0 is shut**, a point already in open room C is kept. Any other point, including one outside the footprint, goes to **`(4700, 180)`** inside C. After G0 opens, a point in open C or outside the rooms (outside the footprint, or the open ground between them) keeps its place; a point in another room, a corridor, or touching a slice wall or shut gate still goes to `(4700, 180)`. That is the spawn the ribbon uses. `(4500, 880)` is not a spawn point. The 800 px gap (spawning §3.6) is the open-world readability rule for seeded candidates. It does not move this redirect, and it does not move, hide, or sleep a pack. A pack that wakes and joins the fight is intended pressure. Still one Herald, still `herald_done`, still not a chunk bit.

## 3. Regular enemies

Four archetypes. Drifter and Swarmer are the bodies already in `RegularEnemy`. Shieldbearer and Sniper are the two additions (stats from pillars §5.1, tier-0 values, no ×1.35). `Turret` and `Mirror` stay sandbox fixtures; do not retune them into these.

| Enemy | HP | Move | Attack | Telegraph | Draw | Script it invites |
|---|---|---|---|---|---|---|
| **Drifter** | 30 | 90 px/s toward the player once within 700 px | Contact 1 pip. No shot | None | Fill `#7DA2FF`, radius 16, outline 2 px `#E7E9EE` | Any shot. The damage lesson |
| **Swarmer** | 6 | 140 px/s, erratic (every 0.4 s, aim ±60°) | Contact 1 pip. No shot | None | Fill `#7DE0C3`, radius 8, outline 2 px | A fan. One group is one target cluster |
| **Shieldbearer** | 60 | 70 px/s toward the player, wake 700 px | Contact 1 pip. 120° front arc **absorbs** (bullet gone, 0 damage), facing the player each frame, no turn cap | The arc itself, body hue at 40% alpha, radius = body + 8 | Fill `#C9A7FF`, radius 20, outline 2 px | `spin`, or a shot spawned off to the side. Straight `ctx.aim` does 0 |
| **Sniper** | 20 | Still. No contact | One bullet, 600 px/s, damage 1 pip, radius 5, lifetime 1.2 s, colour `#FF5A4D`. The **2.4 s** is windup start to windup start (below) | **0.8 s** line in `#FFD166` from the body to the player's position at the start of the windup. The bullet then travels that locked line. It does not home | Fill `#FFD166`, radius 14, outline 2 px | Move off the line (dash). A shot with `lifetime * speed` past 600 px, so you can fire and leave |

**Game Designer call (GE PR #100).** The Sniper's **2.4 s** runs from windup start to windup start, with the **0.8 s** telegraph inside it, the same shape as the Warden Lance. A windup starts only while the player is within 600 px. If the player is out of range when a windup is due, it starts on the first tick they are back in range, and at least 2.4 s after the last start. There is no extra first delay. If the player leaves the 600 px range during the windup, the shot still fires on the locked line.

Scripted packs in C (not chunk encounters, so they do not use the chunk bitmask). Keys in the save: `field_drifters`, `field_swarmers`, `field_shield`, `field_sniper`.

| Pack | Where | Bodies |
|---|---|---|
| Drifters | anchor `(4700, 0)` | 3, formation radius 22 (`RegularEnemy` Drifter formation) |
| Swarmers | anchor `(5400, -200)` | 10 (inside the 8–14 band) |
| Shieldbearer | `(5600, 320)` | 1 |
| Sniper | `(6200, -400)` | 1 |

Idle drift for Drifters and Swarmers matches the first-playable slice (40 px/s inside 96 px of the anchor) until wake. They do not enter the 512 px disk. Contact is `Health.try_damage(1)` (1 pip) with no pierce flag.

**Game Designer call (GE PR #100).** Shieldbearer and Sniper do not idle-drift. They hold their spot until they wake. Absence works like `ChunkStream`. The absent-since time is stamped on the tick the pack's last member dies, even with the player inside C. The **300 s** clock restarts each time the player leaves C while the pack is gone. Staying in C never brings a pack back. Re-entering early leaves it gone, and the next exit restarts the 300 s. G4 stays open when a pack returns.

## 4. Elites and rarity

Q23 affixes only: **Splitting, Summoner, Bulwark, Phasing, Null-shot**. Mirrored, Warded, and Blinker stay later. Rarity multipliers are spawning §3.3, applied after tier HP ×(1 + 0.35·T). Damage the elite deals stays ≤ 1 pip per hit.

| Rarity | Affixes | HP | Speed | Wake |
|---|---|---|---|---|
| Common | 1 | ×2.5 | ×1.0 | 700 px |
| Rare | 2, different groups | ×4 | ×1.0 | 700 px |
| Legendary | 2 + signature | ×7 | ×1.1 | 800 px |

**Odds inside the slice**

| Where | Rule |
|---|---|
| Footprint | No `hash_u` elite roll. The bodies below are placements, like the tutorial dummies. They do not set a chunk bit |
| Outside the footprint, tier 0 | Unchanged: 2 encounters, `hash_u(seed, cx, cy, i, "elite") < 0.04`, rarity forced common, Drifter, one of {Splitting, Summoner}. Rare = 0, legendary = 0. Elites never respawn (Q20) |
| Tier ≥ 1 | Still no spawns (`ChunkStream` / `WorldGen`). This slice does not open them |

| Placement | Tier stamp | Rarity | Base | Affixes | HP / speed | Shards | Respawn |
|---|---|---|---|---|---|---|---|
| Herald (existing) | 0 | common | Drifter | Splitting **or** Summoner, the existing `herald` / `eaff` roll | **75** / 90. HP stays 75 | 1 | never (`herald_done`) |
| Natural elites outside the footprint | 0 | common | Drifter | Splitting or Summoner | 75 / 90 | 1 | never (chunk bit) |
| Room D | 0 (authored, not rolled) | rare | Drifter | **Bulwark + Summoner** (Defensive + Spawn; not an excluded pair) | 30 × 4 = **120** / 90 | 3 | never (`slice_rare_dead`) |
| Alcove | 0 | legendary | Drifter | **Hydra**: Splitting + Summoner, the exclusion exception | 30 × 7 = **210** / 99 | 10 | never (`hydra_dead`). Skipping it is the 15–25 min path |

**Summoner columns (PR #83 at `8caedde0`).** Common, including the Herald and a natural T0 Summoner elite: every **6 s**, max **2** alive, **1 HP** each (one BasicShot hit, and one Straight hit). Rare: every **4 s**, **2** per wave, max **8** alive, **1 HP** Swarmers. Legendary Hydra has its own column: **2** every **6 s**, max **6** alive, each a **105 HP** Drifter (§4). Herald HP stays **75**.

**Game Designer call (GE PR #104, revision 2).** Summons spawn at radius **48 px** from the elite, on a **60°** flank arc (±30° around ±90° from the line to the player, so 60–120° off that line). Each wave puts one body on each flank. The angle is jittered per summon serial, using the deterministic `hash_u(world_seed, chunk.x, chunk.y, encounter_index, serial, "summon", "arc")` rather than runtime RNG, so later waves on the same flank land at different angles. If the spawn point is inside a wall, it slides inward along the same ray until clear, without re-rolling the angle. After spawning, each add holds at its own point: its side (±90° off the player-to-elite line) plus its own hashed arc offset, **20 px** outside the player's edge. Adds keep swarming from the flanks, out of the firing lane, and no two share a hold point. Up to about half a radius of overlap is acceptable, with no separation steering. This covers common, rare, and Hydra summons.

Seed 1 rolls Summoner (`hash_u(1, "herald", "eaff")` ≥ 0.5). Issue #81 has two checks. Both use these times. No standoff distance is required.

| Weapon | Where | Time to kill |
|---|---|---|
| Straight starter, cooldown 0.25 s | about **220 px**, strafing | **≤ 25 s** |
| Spread starter, or the split starter | same | **≤ 15 s** |

1. **Isolated Summoner Herald.** The Herald alone, no other pack in the fight.
2. **Slice.** The first Herald in walled room C, seed 1, in `scenes/main.tscn`. Measured once GE row 6 (the room C redirect) has landed.

Room D rare intensity (spawning §3.4): Bulwark arc **150°**, absorb; Summoner every **4 s**, **2** per wave, max **8** alive, each a **1 HP** Swarmer, no drops. The escort, summons, and any split halves grant no shard and no gate. G5 watches the elite body only.

**Game Designer call (GE PR #101).** The elite spawns at room D's centre `(7680, 0)`. The escort spawns at `WorldGen.escort_position`, **48 px** further from the origin, which for this centre is `(7728, 0)`. It wakes when the player crosses G4's gate line (`x` ≥ G4's west edge, **6782**), or on the usual **700 px** wake, whichever comes first. The first Summoner wave comes **4 s** after wake, and no summon timer runs while it is asleep. The Bulwark starts facing west toward G4 and turns toward the player at **45°/s**, even before wake. There is no name line for the rare elite. Only legendaries get the 2 s name line (spawning §8.1).

Hydra's Summoner is its own legendary column (PR #83 at `8caedde0`), not the common column and not the rare one. Splitting: 2 halves at 40% HP (84) and ×1.3 speed (129 px/s); **each half splits once more** into 2 at 40% of the half (34 HP) and ×1.3 again (167 px/s); those do not split. Summoner: every **6 s**, **2** bodies, max **6** alive, and each summon is a **105 HP** Drifter (90 px/s, radius 16), not a Swarmer. No cue and no shard on halves or summons. Name line `Hydra` for 2 s on wake. The alcove does not gate G5.

Phasing is on the first-run path: the Warden's phase-2 husks use it (§5). Null-shot is the one Q23 affix **not** on that path:

| Affix | Common intensity (the one to ship) | Where the player meets it in this slice |
|---|---|---|
| Bulwark | 120° absorb, no turn cap | Shieldbearer, and the room-A dummy. Rare intensity is room D only |
| Phasing | Absorb except a **0.4 s** pulse every **2.5 s**; outline brightens while open | Warden phase-2 husks (§5). Also the L4 forced Drifter |
| Null-shot | Every 5 s, one bullet, damage 1 pip, telegraph ≥ 0.8 s, colour `#EDE4FF`, `ShotRequest.pierces_script_invuln = true`. Respects engine i-frames, ignores the script invulnerability flag | L4 forced Drifter only. The common Warden does not fire one |

Exclusions to keep encoded (`AffixCatalog.allows_pair`): Splitting × Summoner, except Hydra.

## 5. Boss: the Warden

Pool A, tier 0–1, the boss that unlocks `sense.enemies_in` (api.md Sense table). The slice fights the **common** version only. Working hue `#3D7EFF`. Body radius **48** (≥ 3× the player's 14 px). Outline 3 px `#E7E9EE`. Boss glow is the existing `RarityCue` common-boss disc (`HALO_BOSS_GLOW`), not bloom. `GridWarpFallback.add_chunk` on the arena rect while the core is alive; remove it on death.

**HP 900.** Phase 2 starts the first tick HP is **≤ 630** (70%). Phase 3 starts the first tick HP is **≤ 360** (40%). **Game Designer call (GE PR #96):** body damage stays **×0.1**, and the armor does **not** absorb shots. A hit on the armor ring still lands, at ×0.1. The weak point is a **70° gap** in that ring and takes full damage. The gap's centre is the bearing from the player **through** the core (the far side), turning at a capped rate. It is drawn as a missing arc plus a white tick at the gap's centre. Two hurtboxes: body radius 48 at ×0.1, and a radius-16 hurtbox at `core + away * 40` at ×1 with priority over the body (pillars §5.5). Shots whose muzzle is inside the body and outside that gap wedge hit the body.

The core does not chase. It and the husks are solid to walking. Dash still passes through enemies (pillars §5.4) and not through walls.

### 5.1 Why nearest is the wrong tool

Husks are the decoys. `kind = "husk"`. The core is the only `kind = "warden"`.

While any husk is alive, one husk is locked to the player's bearing at **orbit radius 150**, turn rate **90°/s**, and the others sit on that same circle at equal spacing. **Game Designer call (GE PR #96):** when the lock husk dies, the lock moves at once to the living husk closest to the player's bearing, and the others re-space on the circle. A respawned husk takes the lock only when no other husk is alive. It then starts on the far side and turns toward the player at **90°/s**. A player who walks into the husk (they are solid) stays outside it, so the husk centre is closer than the core centre and `sense.nearest_enemy` returns that husk. A dash can cross the ring. Inside about 75 px of the core the core's centre is nearer; steering at that centre still hits armor at ×0.1, because the gap is on the far side. The query stays honest: nearest centre, no special case that hides the Warden. The starter homing snippet (§6.3) turns toward whatever centre `sense.nearest_enemy` returned and keeps its speed.

The gap is on the far side of the core, so a shot aimed at the core's centre hits armor (×0.1) or the near husk. Manual aim at the white tick still kills the boss: the Sense is not required. `sense.enemies_in` is what lets a script **choose** the warden and aim at `pos + away * (radius + 10)`.

### 5.2 Husks and the tithe

| | Phase 1 (HP > 630) | Phase 2 (HP ≤ 630) | Phase 3 (HP ≤ 360) |
|---|---|---|---|
| Husks | 3 | 4 | 2 |
| Extra | none | The two on the player's side **phase** (below). Outline brightens while open | Keep the lock husk plus one other (below). Phasing turns off |

Husk: HP **40**, radius **16**, fill `#9BB6E0`, outline 2 px, contact 1 pip, no shot, no rarity cue. Respawn **8 s** after death, on the far side of the circle. Killing a husk **heals the core 50 HP** if the core is still above 0. **Game Designer call (GE PR #96):** that heal is clamped to **900**. The core does not overheal. Telegraph of the heal: the husk flashes white for 0.35 s, a line draws to the core, the core's ring pulses. The first time this happens in the save, one line appears by the core for 1.5 s: `It feeds.` Save flag `seen_it_feeds`. A death reset does not show it again. A hit that takes the core to 0 is a kill; husk deaths in that same tick do not heal a dead core.

**Game Designer call (GE PR #97), phase 2.** The phasing pulse starts closed. It first opens at **2.1 s** (open **2.1–2.5 s**), then every **2.5 s** for **0.4 s**. The two player-side husks share one clock. A respawned phasing husk joins that clock and does not reset it.

**Game Designer call (GE PR #97), phase 3.** Going from 4 husks to 2, keep the lock husk plus the living husk closest to the player's bearing among the rest. The others despawn with a **0.3 s** fade: no white flash, no heal line, no tithe. Phasing turns off on the survivors. The respawn cap is **2** alive in phase 3.

This is the common-tier counter to a cheat-like script. `player.invulnerable`, overheal, and a `pos` write do not identify the core, do not stop the tithe, and do not pull the gap onto the player. The common Warden sets **no** `pierces_script_invuln` flag. Null attacks, the Equalizer, the Rift, and the Eater stay on the bosses pillars §12.2 and spawning §5.2 already give them. Engine i-frames (0.75 s hit, 0.2 s dash) and the script flag both block every attack in this fight.

Habituation (pillars §5.3) is on for this fight behind the flag `boss_habituation`, **default true**. Q6 stays open; the flag is how that question is honored. 24 angle buckets of 15°. **Game Designer call (GE PR #97):** speed bands are **0–400 / 400–700 / 700–1000 / 1000+** px/s, and an edge belongs to the upper band, so the default 760 px/s shot sits inside a band. The angle bucket is the bullet's world-frame velocity angle at impact. Habituation applies to the Warden core's hurtboxes only (body and gap, not husks). More than 70% of hits in one signature over 10 s: damage taken falls 10% per 5 s, floor ×0.4, recovers 20% per 5 s when the signature changes. With the flag off, the gap and the tithe still define the fight.

### 5.3 Attacks

Every Warden attack deals **1 pip**. None is a 2-pip hit. Bullets are enemy-owned, colour `#FF5A4D`. Telegraphs use the boss hue and are at least 0.5 s. Phase changes shake the camera ≤ 3 px (`FollowCamera.add_trauma`).

| Phase | HP | Attack | Timing | Telegraph | Bullets |
|---|---|---|---|---|---|
| 1 Roll-call | HP > 630 | **Lance** | **Game Designer call (GE PR #96):** the **2.4 s** runs from windup start to windup start. The **0.6 s** telegraph is inside that interval. The first windup starts **1.0 s** after aggro | 0.6 s line to the player's position at windup start | 1 bullet along that locked line, 320 px/s, radius 6, lifetime 3 s |
| 2 Choir | 360 < HP ≤ 630 | **Fan** | every 3.2 s after the first windup (below) | 0.7 s, 5 lines across a 70° arc aimed at the player at windup start | 5 bullets, 260 px/s, radius 5, lifetime 3 s, evenly across that arc |
| 3 Name | HP ≤ 360 | **Broken ring** | every 5.5 s after the first windup (below) | 0.9 s. 24 dots on a circle radius 420 around the arena centre. For the first 0.5 s the 50° gap tracks the player; then it locks | The other dots become bullets moving outward at 180 px/s, radius 5, lifetime 4 s. The locked gap is empty |

Gap turn cap: **120°/s** in phases 1–2, **240°/s** in phase 3.

**Game Designer call (GE PR #97).** The first Fan or Broken ring after a phase change starts its windup **1.0 s** after the phase-change tick. On a phase change, the previous phase's attack stops. A telegraph already in progress is cancelled and fires no bullets.

The fight **aggros** when the player's centre crosses `x = 8736` (one step inside E). Before that the core is drawn, hurtboxes off, husks unspawned, so a shot through the corridor does not start the tithe. Leaving the arena does not reset aggro. Death does (§1).

### 5.4 Rare and legendary, not built in this slice

Same type, same Sense. HP ×1.2 rare (1080), ×1.3 legendary (1170). From phase 2, the rare twist (spawning §5.1) rotates the roll-call ring toward the player's movement over the last 2 s. Legendary adds Phase ★ **Writ** at 15% HP: every 6 s a Null ring, white-violet `#EDE4FF`, 1.0 s telegraph, one gap, `pierces_script_invuln`, damage 1 pip, engine i-frames still block it. Cues for those tiers are §8. Do not build the twists or Writ in this slice. A rare kill would grant Level II. **Decided (CoS call, Karyu may override), Q25:** this fight is always common, so the slice does not roll rarity and does not grant Level II.

### 5.5 Boss bar

**Game Designer call.** The bar is on the body, not a screen widget, and it has **no gap**. It is a plain **2 px** arc at radius **78**, boss hue, that starts at 12 o'clock and fills clockwise to `hp / 900`, drawn under the core. The **70°** weak-point gap belongs only to the armor ring: it tracks facing and never shrinks with HP. Phase changes tick the arc (a 0.15 s white flash). Gone when the fight is over.

### 5.6 Reward

The victory card below is built in GE row 10, not in the HUD row (row 11).

**Game Designer call (GE PR #103).** When core HP hits 0, the kill tick emits `GameEvents.enemy_killed`, then `boss_defeated("warden")`. On that same tick every enemy bullet fades out over **0.2 s** and deals no damage.

Also on that tick, one save write stores the Sense grant (`sense_enemies_in = 1`), `RespawnPoints.register_arena_cleared(Vector2(9664, 0))`, shards **+5**, `warden_dead`, `starter_consumed`, and the G0 open bit. The card is presentation only.

1. Husks despawn. 1.2 s: the core's ring scales to 0. Time scale stays 1 during this.
2. **Fragment.** `SenseBook.grant(&"enemies_in", 1)` **is** the Warden's Fragment: Level I of `enemies_in`. The grant is in the kill-tick write above. Level II is not granted. There is no separate inventory item. Playtest check: after the kill tick the field is non-nil and the save int is 1.
3. Shards +5 (common boss, spawning §7.2), in that same write. The white mote is deferred, the same as the elite stub. Row 10 ships without it.
4. Then the card. Time scale **0**. Line 1 is **28 px** and line 2 is **20 px**, **8 px** apart, `#F2F2F2`, centred in the playable band: `The Warden is down.` / `sense.enemies_in`. Dismissing needs a fresh press of Fire or E after the card appears. Input is ignored for the first **0.4 s**. E does not open the editor here. On dismiss, time scale returns to 1 and G0's wall lifts. The `enemies_in` toast and Codex page wait until that dismiss (§6.3). If the player quits before dismissing, those two fire on the next load, because the Codex-once flag is not set yet. On load, `warden_dead` means G0 is open.

A second kill cannot happen; the core does not respawn.

## 6. Senses (SE contract)

Names are the api.md table. Do not add new sense names. `sense` is a table from the first frame. An unearned field is `nil`, so `sense.nearest_enemy and sense.nearest_enemy(...)` is safe. For this whole slice, `sense.enemy_bullets`, `sense.terrain`, `sense.boss`, and `sense.world` stay `nil`.

Level II is **later**. It comes from a rare or legendary kill of that boss, or from 25 Shards, not from a clean kill (api.md, corrected). This slice never sets a sense level above 1 and has no spend UI. **Game Designer call (SE PR #98):** in the slice, a save with any Sense level above 1 loads as Level I, because the slice has no Level II.

### 6.1 Who unlocks what

| Field | Unlocks | Persists |
|---|---|---|
| `sense.nearest_enemy(pos, range?, opts?)` | The third `GameEvents.enemy_killed` with `first_death` true. SE's `SenseBook` counts. Dummy deaths count. Lessons 1–2 kill the three origin dummies first, so those three first deaths are the grant. A respawned dummy's later death has `first_death` false and does not count | Save flag `sense_nearest`. Permanent for the slot |
| `sense.enemies_in(pos, r, opts?)` | Common Warden's death, Level I only | Save int `sense_enemies_in = 1`. Permanent for the slot |

Kill counting is owned by SE. GE emits `GameEvents.enemy_killed(kind, rarity, tier, pos, first_death)` on every death, including dummies (`kind` `"dummy"`; `rarity` `""`; `tier` `0`; `pos` the death position). `first_death` is true the first time that body dies and false after it respawns. Hostiles use the same signal: `kind` as in §6.2, `rarity` `""` for a regular or a husk and `common` / `rare` / `legendary` for an elite, `tier` the body's tier stamp. GE does not count and does not grant `nearest_enemy`.

`SenseBook` (autoload or a child of `Main`) subscribes to that signal, increments on `first_death` only, and calls `grant(&"nearest_enemy", 1)` at 3. It also exposes `grant(id, level)`, `level(id) -> int`, `unlocked(id) -> bool`, and signal `granted(id, level)`. `SaveGame` stores the two fields. The Lua env is built from the book **before** the first `on_fire` after a load. A reload with the flag already set does not grant again.

### 6.2 Return shapes

Queries read `HurtboxGrid`. `query_circle` only walks the cell under the point; GE adds `query_radius(center, radius, layer_mask)` that walks every cell the circle covers and returns the target refs. The query sees bodies registered in the live grid (the camera window). That window is the range limit. No extra gameplay cap.

**Call budget.** None beyond the script time budget. Calling the query from `on_fire`, or from `on_tick` on a handful of bullets, is the supported path. Calling it from every bullet of a large fan is how a script hits the 3 ms budget; the budget already reports that. Do not add a sense-call quota.

**Entity, Level I** (both senses): `e.id` (int, stable for the life of that body), `e.pos` (`vec2`), `e.radius` (px), `e.kind` (string), `e.rarity` (string), `e:alive()` (bool). `e.rarity` is `""` for regulars, husks, and dummies, and otherwise `"common"`, `"rare"`, or `"legendary"`. `e.vel`, `e.hp`, and `e.hp_max` are `nil`. Speed is not a Level I field. Players cannot write these fields.

`kind` in this slice: `drifter`, `swarmer`, `shieldbearer`, `sniper`, `husk`, `warden`, `dummy`. Halves are `drifter`. Hydra summons are `drifter`. Summoner adds are `swarmer`.

`opts.exclude`: a table keyed by `e.id` **or** by an entity table returned this tick. `opts.filter(e)` is a Lua function; a filter error skips that candidate and prints one plain error line (§7.5).

`nearest_enemy`: the living candidate with the smallest distance from `pos` to the **centre**. Level I clamps `range` to **600** and defaults a missing range to **600**, the same rule as `enemies_in`. A larger request does not error. Returns the entity or `nil`. Level II lifts that clamp the same way `enemies_in` does. It still does not add `vel`, `hp`, or speed.

`enemies_in`, Level I:

- `r` above **600** clamps to 600. No error.
- Returns an array, nearest first, length ≤ **256** (api.md limits). Past 256, keep the nearest and show one editor note, `sense list truncated`.
- Each element is the Level I entity above. Positions are the point of the Sense; `kind` is how a script tells a husk from the Warden.

Level II, not shipped, for the Codex footnote only: `enemies_in` would add `vel`, `hp`, `hp_max` and would stop clamping `r` to 600. `nearest_enemy` Level II stops clamping `range` to 600 and does not add those fields.

### 6.3 How an unlock feels

One-time, the first transition of that flag from off to on. Reloading a save where the flag is already set does not repeat it. For `enemies_in`, the toast and Codex wait until the victory card is dismissed. Quitting before that dismiss leaves the Codex-once flag unset, so the next load still shows them once (§5.6).

1. **Codex page**, one screen in the editor, about ten lines, an annotated snippet. Not a modal over the arena.
2. **Autocomplete:** the name was grey. It draws in the editor's normal token colour and stays at the top of the sense list for the rest of the session. `nearest_enemy` greys as `3 kills` until then. `enemies_in` greys as `found at: ???` until the Warden dies. The other four senses stay grey `found at: ???`.
3. **Toast**, 2.5 s, bottom centre, `#F2F2F2`: `sense.nearest_enemy` or `sense.enemies_in`. No button.

`nearest_enemy` page. The palette inserts `scripting/starters/homing.lua` as it is on PR #92 at `e850a08`. The call takes `{x, y}` and reads `e.pos.x` / `e.pos.y`. `on_batch` steers the direction and then restores the shot's original speed. `pull = 1800` is the one `-- <- tweak me` number. 1800 is the lowest value that still hits at speed 400, because the turning radius grows with speed squared. `b:steer_toward` is a later helper, not this slice.

```lua
-- Homing: shots steer toward the nearest enemy.
-- needs: sense.nearest_enemy
return {
  name = "Homing",
  cooldown = 0.45,
  on_fire = function(ctx) spawn { angle = ctx.aim, speed = 280, damage = 4, lifetime = 2.5 } end,
  on_batch = function(v, dt)
    local nearest = sense.nearest_enemy  -- nil until you earn it
    if not nearest then return end
    local pull = 1800  -- <- tweak me: how hard shots turn
    for i = 0, v.n - 1 do
      local e = nearest({ x = v.px[i], y = v.py[i] }, 400)
      if e then
        local dx, dy = e.pos.x - v.px[i], e.pos.y - v.py[i]
        local f = pull * dt / (math.sqrt(dx * dx + dy * dy) + 1)
        local vx, vy = v.vx[i] + dx * f, v.vy[i] + dy * f
        local k = math.sqrt((v.vx[i] ^ 2 + v.vy[i] ^ 2) / (vx * vx + vy * vy + 1e-9))  -- keep the speed
        v.vx[i], v.vy[i] = vx * k, vy * k
      end
    end
  end,
}
```

SE acceptance for that file, against a stationary dummy at **220 px**, fire rate **0.25 s**: at least **90%** of shots hit, and no shot orbits for more than **1 s**. While strafing, at least **70%** hit. SE measured **100% / 0.27 s / 100%**.

`enemies_in` page, `scripting/codex/enemies_in.lua`. Same `{x, y}` call shape. No `steer_toward`. It looks the Warden up once per batch, from the first shot. If that body is within 600 px of that first shot, every shot in the batch steers toward it.

```lua
-- sense.enemies_in(pos, r)  · earned: the Warden
-- Gives every enemy within r of pos, nearest first: a list you can loop over.
--   r      up to 600 px (a bigger r counts as 600)
-- Each entry is the same as sense.nearest_enemy's: e.pos.x, e.pos.y,
-- e.radius, e.kind, e.rarity, e.id and e:alive(). No speed, no hp.
-- The closest body is not always the one you want. Here the shots skip
-- the husks and push toward the Warden itself (e.kind == "warden").
-- Insert this snippet, save, and fire near the Warden's ring.
-- Level II (later, not in this build) adds speed and hp and lifts the
-- 600 px limit.

-- Warden seeker: shots push toward the Warden, not the nearest husk.
-- needs: sense.enemies_in
return {
  name = "Warden seeker",
  cooldown = 0.45,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 280, damage = 4, lifetime = 2.5 }
  end,
  on_batch = function(v, dt)
    local query = sense.enemies_in  -- nil until you earn it
    if not query or v.n == 0 then return end
    -- One look per batch (from the first shot), not one per shot.
    local core = nil
    for _, e in ipairs(query({ x = v.px[0], y = v.py[0] }, 600)) do
      if e.kind == "warden" then core = e break end
    end
    if not core then return end
    for i = 0, v.n - 1 do
      local dx, dy = core.pos.x - v.px[i], core.pos.y - v.py[i]
      v.vx[i], v.vy[i] = v.vx[i] + dx * dt, v.vy[i] + dy * dt  -- <- tweak me: dt * 2 turns harder
    end
  end,
}
```

Native `homing = { target = "nearest" }` stays as api.md describes it: accepted and ignored until a radius query exists. The slice's teaching path is the `on_batch` file above. `docs/scripting/examples/homing.lua` stays the long native-homing draft, not the palette row. Per-bullet `on_hit`, `b:split`, `hit.normal`, and `b:steer_toward` are post-slice.

## 7. Onboarding

Diegetic and short. The only standing prompt is `E edits.` for the first 8 s (controller: the edit face button already in pillars §2; touch: the edit button). Editor time scale **0.15** while it is open (Q5 option A, the recommendation). Q5 stays open; this slice does not re-ask it. The world keeps moving at that scale. PC hot reload watches **only the equipped file**. The editor's file picker is what equips a file. Saving some other file from outside the editor shows the toast `shots/<f>.lua saved (not equipped)` and does not reload the weapon.

The editor is the same control in every room, owned by `Main`, not by room S. Lessons do not replace the equipped script when you walk through a door. A palette row inserts a starter if the player asks. The equipped file on minute 1 is `shots/default.lua` (the straight starter).

**Checkers** read the world (HP, hit speed, aim angle). The game does not parse Lua to decide a gate. QA scripts are the exception: lesson 3's test supplies a file that contains `local function`.

**Failure.** There is no fail state and no lockout. The gate stays shut. One hint line, 18 px, `#C9D2E0`, bottom centre, once per lesson, after the wait in the table. It arms again only after the next successful save. A script error uses §7.5 and does not advance the lesson. Dummies respawn, so the player can retry. `Health.regen_enabled = false` while the player's centre is inside B, so lesson 4 is not waited out.

| # | Room | Starter (what they have, or what the row inserts) | Goal | Checker | Hint, if still open | Hint after |
|---|---|---|---|---|---|---|
| 1 | S | Straight, §7.1. `damage` is 1 | A bigger number | East dummy `(300,0)` reaches 0 HP within **4 s** of the trigger being held. Damage 1 needs ~10 s at cooldown 0.25, so it fails. Damage 4 passes (~2.5 s) | `The damage number.` | 25 s |
| 2 | S | Spread, §7.1 | One aim, several shots | In a 3 s window, north and south dummies each take damage, and `ctx.aim` stays within **0.4 rad** of its value at the start of the window. Passing also requires all three origin dummies to have died at least once (three `first_death` events; that is the `nearest_enemy` grant) | `One aim, more than one target.` | 25 s |
| 3 | A | The function stub, §7.2, inserted only if they pick the row. Their script is left in place | The shielded dummy dies | Dummy at `(1800, 0)`, 40 HP, radius 22, non-hostile, **120° absorb arc facing west** (toward the door), static. Straight shots deal 0. Dies at least once | `Bend the shot. Put it in a function.` | 30 s |
| 4 | B | Their script. The page shows the branch, §7.2 | Fire only while hurt | Pad `Rect2(2700, -80, 160, 160)`: on entry, if `hp == 5`, a 0.6 s ring on the player, then `try_damage` for 1 pip. Dummy at `(3200, 0)` has its hurtbox off while `hp > 4`. **Pass:** that dummy's killing blow happens while `player.hp <= 4` | `Read player.hp.` | 30 s |
| 5 | B | Their script, speed 480 until they edit | Save the equipped file, and the next shot is faster | Plate at `(3500, 0)`, 16×64 px. Pass when a **player bullet** overlaps it with speed ≥ **640** after `script_saved(file_name, origin)` for the equipped file (`origin` `editor` or `file`). `unequipped_file_saved` does not pass it | `Save the file.` | 20 s |

G1 needs 1 and 2. G2 needs 3. G3 needs 4 and 5, in either order.

### 7.1 Minute-1 palette

Five rows. The first four insert immediately. Homing is visible and grey, insert disabled, until `sense_nearest` (§6.3).

The five files are `scripting/starters/`. Straight is copied once into the equipped `shots/default.lua`. Numbers match those files. Per-bullet `on_hit`, `b:split`, and `hit.normal` are not in this editor; split is a weapon-level `on_hit` plus `b:spawn_child`.

Straight:

```lua
-- Straight: one shot along your aim, every `cooldown` seconds.
-- Save (Ctrl+S) and the next shot uses your numbers.
return {
  name = "Straight",
  cooldown = 0.25,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 480, damage = 1 }  -- <- tweak me: damage
  end,
}
```

Spread:

```lua
-- Spread: five shots in a fan, one aim.
return {
  name = "Spread",
  cooldown = 0.30,
  on_fire = function(ctx)
    for i = -2, 2 do  -- <- tweak me: -3, 3 for seven shots
      spawn { angle = ctx.aim + i * 0.16, speed = 460, damage = 2 }
    end
  end,
}
```

Spiral (`docs/scripting/examples/spiral.lua` stays the long form):

```lua
-- Spiral: three arms that turn a little more every shot.
local t = 0
return {
  name = "Spiral",
  cooldown = 0.08,
  on_fire = function(ctx)
    t = t + 0.22  -- <- tweak me: how far the arms turn per shot
    for arm = 0, 2 do
      spawn { angle = ctx.aim + t + arm * (TAU / 3), speed = 340, damage = 2 }
    end
  end,
}
```

Split. The pieces appear at the hit and fly back the way the shot came. `hit.x` / `hit.y` are the hit point. `b:spawn_child(x, y, vx, vy, lifetime)` spawns one piece.

```lua
-- Split: when a shot hits, it bursts into pieces right where it hit.
return {
  name = "Split",
  cooldown = 0.40,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 420, damage = 3 }
  end,
  on_hit = function(b, hit)
    local pieces = 3  -- <- tweak me: how many pieces
    local back = math.atan(-b.vy, -b.vx)  -- fly back the way the shot came
    for i = 1, pieces do
      local a = back + (i - (pieces + 1) / 2) * 0.4
      b:spawn_child(hit.x, hit.y, math.cos(a) * 280, math.sin(a) * 280, 1.2)
    end
  end,
}
```

Homing: the block in §6.3.

### 7.2 Stubs the hints show

Lesson 3, the row `Function`:

```lua
local function volley(ctx)
  spawn { angle = ctx.aim + 0.9, speed = 420, damage = 4, spin = 2.2 }
end
return {
  cooldown = 0.22,
  on_fire = function(ctx)
    volley(ctx)
  end,
}
```

`spin` 2.2 rad/s is enough to walk a shot around the 120° arc before it expires. An offset angle without `spin` also passes if it actually hits. The checker does not care which.

Lesson 4, the line the hint is about (not auto-inserted):

```lua
if player.hp < 5 then
  spawn { angle = ctx.aim, speed = 480, damage = 4 }
end
```

Setting `player.hp = 5` in the script keeps the dummy's hurtbox off. That is the lesson, not a bug.

### 7.3 Hot reload

Time scale stays **0.15** while the editor is open.

- The file picker equips. An in-game save of the equipped file writes it, emits `script_saved(file_name, editor)`, and reloads at the next frame boundary, before the next `on_fire`.
- PC watches **only that equipped file** (polled about every 0.5 s). A change emits `script_saved(file_name, file)`. A good write reloads. A broken write keeps the last good weapon and still emits `script_saved`. The editor line is §7.5.
- Lesson 5 passes on `script_saved` for the equipped file only. Cold start does not emit it. `weapon_swapped(file_name, origin)` is the equip (`origin` `start`, `editor`, or `file`) and is not the lesson-5 pass.
- A save of any other `shots/` file emits `unequipped_file_saved(file_name)` and does not reload. That signal drives only the toast `shots/<f>.lua saved (not equipped)`, at most once per file per 3 s, whether or not the editor is open. It never passes a lesson.
- In-flight shots keep the callbacks they spawned with, and at most **3** script versions stay alive. **Game Designer call (SE PR #95):** a save is never refused. When a 4th version arrives while all 3 kept versions still have hooked shots in flight, the oldest version's in-flight shots drop their script hooks and fly on as plain bullets. They keep their speed, damage, lifetime, and look. They get no more steering, `on_hit`, or `on_batch`. The drop is silent, with no toast. `script_saved` still fires, so lesson 5 is never blocked.
- **Game Designer call (SE PR #95):** every save starts the new script version with fresh top-level globals, whether or not shots are in flight. Nothing at file scope carries over. Data meant to survive a save goes in `state`.
- **Game Designer call (SE, `state` follow-up to #95).** `state` is a per-weapon sandbox global that starts as `{}`. On every save, idle or with shots in flight, the new version gets a copy of the plain data in `state` (numbers, strings, booleans, nested tables). Within one copy, a table referenced twice stays shared. A cycle is cut at the back-reference with a warning. Functions and userdata are dropped with a warning in the editor's problems list. `state` is filled in before the new file runs. If the file's top level reassigns `state` (for example `state = {}`), that wins, and that is how a player resets it. Idiom: `state.n = state.n or 0`. A failed save leaves the running version's `state` untouched. Shots still in flight from older versions keep their own `state`. `state` survives death and respawn. It is not written to the save file in the slice.
- **Game Designer call (SE PR #102).** Only string, number, and boolean keys are copied. Table keys are dropped with a warning. Caps: at most **32** nested tables, **8,192** entries, and **256 KiB** encoded. Past a cap, the rest is cut, with one editor warning. Metatables are not copied. `state` belongs to the weapon, so equipping a different `shots/` file carries it over too. The `x = state.x or default` idiom handles keys from another script, and `state = {}` resets.

### 7.4 Out of this slice

Capability prompt (§7.1 of pillars), touch symbol row, and controller token cursor are first-release editor work and are **not** gates for this path. Ship a text area, save, the palette, the console line, and autocomplete highlight. Phone pairing stays later (Q13).

### 7.5 Error tone

The visible line is one sentence, plain language, with the line number. The game keeps running.

| Case | Line | What keeps running |
|---|---|---|
| Syntax or load error | `line 4: expected ')'. Still running the last good script.` | The previous weapon. No new shot starts from the broken file |
| Runtime error in a callback | `line 9: attempt to index a nil value. Still running the last good script.` | The game. That callback is skipped until the next save (api.md). Other callbacks still run |
| Timeout (instruction or 50 ms) | `line 12: script timeout. Still running the last good script.` | Same as api.md: the write to `player` from that call is not committed. Three timeouts suspend the script until the next save |

The traceback stays in the console behind that line, for anyone who opens it. The line itself does not include the stack. The game does not crash and does not close the editor.

## 8. Rarity cues (Q24 option A)

Option A, restated so GE can wire it and QA can re-run [issue #24](https://github.com/Karyu42/scriptshot/issues/24). Shape and outline carry the rarity. Colour is an accent. Audio is a confirmation. Every audio cue has a 0.3 s ring brighten. Cues are `_draw()` plus at most one additive disc. No Forward+/Mobile-only effect. Renderer is `gl_compatibility`.

`src/fx/` already draws this (`RarityCue`, `RaritySting`, `RarityPhrases`, `HaloDisc`, `EliteCue`, `GridWarpFallback`). Linux Compatibility passed the shape rows on 2026-11-09 (`6a67560`). **Wire the tiers onto the bodies this slice spawns.** Do not redraw the gallery. The legendary **3 dB duck** and the boss **proximity hum** stay **INCOMPLETE / deferred**. The 2 s boss one-shots in `RarityPhrases` are gallery previews, not the hum.

### 8.1 Elites

| | Shape | Outline | Accent | Tell | Sting (`AudioStreamGenerator`, else the `.ogg`) |
|---|---|---|---|---|---|
| Common | Base shape + **one** ring at **1.35×** radius | **3 px** (regulars are 2 px) | Ring `#F2F2F2`. Body keeps its role hue | One glyph, orbit 1.6×, 6 px, 90°/s. Circle = Spawn, square = Defensive, triangle = Offensive | Triangle, **440 Hz → 660 Hz**, **0.4 s**, on wake. This pitch is pinned |
| Rare | **Double ring** (outer at 1.58×, the radius `RarityCue` already uses) + **three** triangular ticks | **4 px** | Cyan `#4DE1FF` | Two glyphs. Telegraphs ×1.2 brightness. **No disc** | 0.8 s: triangle 440, 523.251, 659.255 (0.15 s each), then sine 880 quiet for the rest |
| Legendary | Ring **crowned with four ticks**, pulse **1.5 s** | **5 px** | Amber `#FFB347` | Name line for **2 s** on wake. Signature glyph. Additive disc, low alpha, `BLEND_MODE_ADD`, behind the body | 2 s: sine drone 110, swelling; from 0.55 s a triangle motif 440, 523.251, 587.33, 659.255. **No 3 dB duck** |

`draw_arc` segments **32**. At most **12** elites draw the full cue; the rest draw the outline only. Bosses do not take a slot.

### 8.2 Bosses

| | On the body | Beacon tick | Hum |
|---|---|---|---|
| Common | Boss hue, outline **3 px**, no rarity ring. Glow = the larger low-alpha disc `RarityCue` already builds for `TIER_BOSS_COMMON` | **One** thin tick in the boss hue, edge of screen, while the boss is alive and within 5 chunks. The slice Warden qualifies as soon as the player is in the ribbon | **Deferred.** Do not ship it |
| Rare | **Double outline** + one cyan accent ring | **Double** tick | Deferred. Preview one-shot only |
| Legendary | **Four** crown ticks, amber, outline width pulses **3 → 5 px** over 1.5 s | Tick with an amber pulse, 1.5 s | Deferred. Preview one-shot only |

A cue never covers the weak-point tick or a telegraph. Enemy bullets stay `#FF5A4D`. Null (not used by the common Warden) stays `#EDE4FF`.

### 8.3 Fallbacks, and what QA still re-runs

| If this fails | Use |
|---|---|
| Additive blend on a platform | Same disc, normal alpha, outline 1 px brighter (`RarityCue.halo_add_enabled = false` already does this) |
| Pulse cannot run | Static ring, no pulse |
| `AudioStreamGenerator` misses budget, or web autoplay rejects it | The pre-rendered `.ogg` for that tier. Stings start after the first user gesture on web |
| Grid warp | Already the fallback: `GridWarpFallback` vertex offset ≤ 3 px, or a brightness pulse. No post-process |

Issue #24 acceptance, still the bar: sections A–E pass, or fail with the fallback in use, on **Web and Android**. Linux shape rows are done. Still open there: listened audio (glitches, latency), the Web gesture-gated playback, the Android and Web ADD-halo look, the deferred hum, and the export reporting Compatibility. Closing #24 is QA's, after those builds are exercised. This slice's GE gate is: room D shows the rare row, the alcove shows the legendary row, the Warden shows the common-boss row, and a forced `halo_add_enabled = false` still reads.

## 9. Audio and visual notes

Minimal, on the palette already in pillars §8. Background `#0B0D10`, grid `#161A20` (rooms may use `Arena`'s `#171a21` / `#1f232c`). Player `#F2F2F2` with the 12 px core. Player bullets default white. Enemy bullets `#FF5A4D`. One hue per role (§3, §5). No textures, no sprites, no new shader. Trails stay the bullet smear already in `bullet.gdshader`.

Slice-only sounds, all synthesized, all optional for the first playable combat pass:

| Event | Sound |
|---|---|
| `spawn` | Existing shot voice if it is in; otherwise silence. Do not block the slice on it |
| Player hit | Short tick |
| Absorb | A drier tick than a hit, so a 0 reads in audio |
| Phase change | One triangle blip, a fifth above the last, ≤ 0.2 s. Camera shake ≤ 3 px |
| Fragment | A low tone, once, under the toast |
| Editor error | No sting. The line in §7.5 is the feedback |

Silence is fine. No music bed. No hum (deferred). No duck.

## 10. GE build list

Ordered. Each row is done when its acceptance passes. Dependencies are other rows or a named system already on `main`.

1. **Ribbon.** `SliceLayout` under `Main` with the rects in §2, walls in `world_walls`, gates as removable wall segments. Acceptance: a headless walk from `(0,0)` to `(9664,0)` is blocked at each shut gate and clear when that gate's flag is forced. Footprint rect drops anchors inside it; an anchor just outside still spawns. Depends: `Arena` draw, `BulletManager` walls, `ChunkStream`.
2. **Packs in C (Game Designer calls, GE PR #100, §3).** Drifter, Swarmer (existing scenes), plus `scenes/shieldbearer.tscn` and `scenes/sniper.tscn` with the numbers in §3. Acceptance: Shieldbearer arc absorbs a straight shot and takes damage from the side; Sniper waits 0.8 s, then the bullet follows the locked line at 600 px/s for 1 pip; contact from a Drifter is 1 pip and 0 during the 0.75 s i-frames. Each hostile death emits `GameEvents.enemy_killed` (§6.1). `collide_walls` applies to every regular enemy and Summoner add while the ribbon is on. Depends: row 1, and row 3 for the arc.
3. **Absorb arc.** Per-hurtbox response `ABSORB` with facing and arc, `DespawnReason.ABSORBED`, as first-playable L4. Acceptance: the L4 Bulwark test, and the room-A dummy. Include `REFLECT` in the enum; do not ship Mirrored. Depends: `Hurtbox`.
4. **Room A dummy and room B pad/plate.** Numbers in §7. Acceptance: straight shots deal 0 to the shielded dummy; a shot with `spin` 2.2 kills it; the pad deals 1 pip after 0.6 s and only when HP is 5; the plate reports the overlapping bullet's speed. Every dummy death, including the three in S, emits `GameEvents.enemy_killed` with `kind` `"dummy"`; a respawned dummy's later death has `first_death` false. Depends: rows 1 and 3.
5. **Lesson flags and gates (Game Designer calls, §2).** `SliceProgress` saved on `SaveGame`: `slice_lesson` bits, gate bits, and the absent-since times of room C's four packs (`field_drifters`, `field_swarmers`, `field_shield`, `field_sniper`). A missing key is 0, so that pack is present. No per-lesson timestamps. Death does not clear the flags. The respawn point is chosen when the 1.5 s respawn happens. Acceptance: the §7 checkers, then G1–G4 open in order; a death while the Warden is still alive respawns at the origin with G1–G3 still open; a death whose 1.5 s ends after the Warden is dead respawns at `(9664, 0)`. There is no quick-restart key. Depends: rows 1–4, `RespawnPoints`, `Main.respawn_delay`.
6. **Herald redirect.** Acceptance: while G0 is shut, a Herald point that is not in open C becomes `(4700, 180)`; after G0 opens, a point outside the footprint keeps its place; `herald_done` still blocks a second. The slice half of the #81 times is measured in `scenes/main.tscn` once this row has landed. Depends: `HeraldDirector`, row 1.
7. **Room D rare elite (Game Designer calls, GE PR #101, §4).** 120 HP Drifter, Bulwark rare + Summoner rare, escort, cue tier rare, `slice_rare_dead`, shards +3, G5. Acceptance: the elite spawns at `(7680, 0)` and the escort at `WorldGen.escort_position`, 48 px further from the origin (`(7728, 0)`). Wake is the first of `x` ≥ G4's west edge (6782) or the 700 px wake. The first Summoner wave is 4 s after wake, and no summon timer runs while it is asleep. The arc is 150°, starts facing west toward G4, and turns toward the player at 45°/s even before wake. There is no name line. Summons cap at 8; killing a summon does not open G5; reload does not respawn the body. Depends: rows 3 and 5, `EliteEnemy`, `RarityCue` rare tier.
8. **Warden phase 1.** 900 HP, gap, 3 husks, Lance, aggro line at `x = 8736`, tithe 50, solid bodies. Acceptance: before aggro, shots deal 0; with the player pressed against the near husk from outside, the nearest centre is that husk; a shot into the core centre deals ×0.1 and a shot into the gap tick deals full damage; a husk death adds 50 HP unless the core hit 0; Lance telegraph is 0.6 s, the bullet has `pierces_script_invuln` false, it deals 1 pip, and it deals 0 during a dash. Depends: rows 1 and 5.
9. **Phases 2–3 and Habituation flag (Game Designer calls, GE PR #97, §5.2–§5.3).** Fan, phasing husks, broken ring, turn caps, `boss_habituation` default true. Acceptance: phase 2 starts the first tick HP ≤ 630, and the first Fan windup starts 1.0 s after that tick; a Lance telegraph in progress is cancelled and fires no bullets. The shared phasing clock starts closed, opens at 2.1–2.5 s, then every 2.5 s, and a respawned husk does not reset it. Entering phase 3 keeps the lock husk plus the living husk closest to the player's bearing; the other two fade for 0.3 s with no flash, no heal line, and no tithe; phasing is off and the respawn cap is 2. The first Broken-ring windup starts 1.0 s after that tick. The ring has a 50° gap and its bullets deal 1 pip. Speed bands are 0–400 / 400–700 / 700–1000 / 1000+ px/s, edges in the upper band, so a 760 px/s shot is inside a band. The angle bucket is the world-frame velocity angle at impact, and only the core's body and gap hurtboxes count. With the flag on, a single signature loses damage as §5.2; with the flag off, a single signature does not. Depends: row 8.
10. **Victory and the open world (Game Designer calls, GE PR #103, §5.6).** The §5.6 sequence, G0, `register_arena_cleared`, `starter_consumed`, shards +5. Acceptance: the kill tick emits `enemy_killed`, then `boss_defeated("warden")`, and every enemy bullet fades over 0.2 s and deals no damage. That tick's one save write stores `sense_enemies_in = 1`, `RespawnPoints.register_arena_cleared`, shards +5, `warden_dead`, `starter_consumed`, and the G0 open bit. The card is presentation only: line 1 is 28 px, line 2 is 20 px, 8 px apart, `#F2F2F2`, centred in the playable band, time scale 0. A fresh Fire or E press after the card appears dismisses it; input is ignored for the first 0.4 s, and E does not open the editor. G0's wall lifts on dismiss. On load, `warden_dead` means G0 is open. Quitting before dismiss leaves the Codex-once flag unset, so the `enemies_in` toast and Codex page fire on the next load; otherwise they wait until dismiss. There is no white mote. A respawn that happens after the kill is `(9664, 0)`, including a death that started before the kill and whose 1.5 s ends after it (Game Designer call, §2). A fresh `chunk_encounters` outside the footprint is unchanged. `sense_enemies_in` is 1 only after `SenseBook.grant` (SE row 6 can stub the grant). Depends: row 8. Phase 2–3 are not required for this row.
11. **HUD (Game Designer calls, §5.5 and §14).** Pips, dash arc, sense marks, boss arc. The §5.6 victory card is row 10, not this row. Acceptance: 5 pips track `Health` on the radius-20 ring; up to 5 extra violet pips, then a violet `+N` (`N = hp - 10`) and no further pips; sense marks are 4 px in diameter and fill only when the book says so; the dash arc matches `DashState.cooldown_left`; the boss arc is a gapless 2 px stroke at radius 78, from 12 o'clock clockwise to `hp / 900`, and is absent when the Warden is dead. The armor ring's 70° gap is not this arc. Depends: `Health`, `DashState`, row 8, SE's `SenseBook`.
12. **Hydra alcove, Phasing, Null-shot, and summon spacing (Game Designer call, GE PR #104 revision 2, §4).** Row 12 lands in steps: summon spacing first (#104), then the alcove placement, `hydra_dead`, the Null-shot L4 test, and Phasing after #100–#103. Acceptance for the spacing step: a wave puts one body on each flank, at radius 48 px, on a 60° arc (±30° around ±90°, so 60–120° off the line to the player). The angle is `hash_u(world_seed, chunk.x, chunk.y, encounter_index, serial, "summon", "arc")`, so a later wave on the same flank lands at a different angle, and it is not runtime RNG. A point inside a wall slides inward along that ray until clear, and the angle is not re-rolled. After spawning, each add holds at its own point: its side plus its own hashed arc offset, 20 px outside the player's edge. At the rare cap of 8, no two adds share a hold point. Up to about half a radius of overlap is acceptable, with no separation steering. This covers common, rare, and Hydra summons. The later steps keep the rest: Hydra's halves split twice and stop; summons are 105 HP Drifters, max 6, 2 every 6 s; `hydra_dead` sticks; Null-shot still pierces script invulnerability and not a dash, and is not fired by the Warden. Depends: rows 7 and 9. Not on the path to row 10.
13. **Cue wiring.** Room D uses `TIER_ELITE_RARE`, alcove `TIER_ELITE_LEGENDARY` with signature name `Hydra`, Warden `TIER_BOSS_COMMON`, including the edge tick and `GridWarpFallback`. Acceptance: §8.3's GE gate, plus the existing `tests/unit/test_rarity_cue.gd` still passes. Depends: rows 7, 10, 12.

## 11. SE build list

The editor's shot API is `spawn`, `on_fire`, a weapon-level `on_hit`, `b:spawn_child`, and `on_batch` (§7.1, the files in `scripting/starters/`). Per-bullet `on_hit`, `b:split`, `hit.normal`, and `b:steer_toward` are post-slice. Pillars' `shoot` / `on_die` spellings stay accepted aliases where the binding already has them. `ScriptHost` is the loader (`scripting/script_host.gd`).

1. **Equip a file.** `shots/default.lua` is the straight starter. `Main` runs it through `ScriptHost` instead of `BasicShot` when the file loads. Acceptance: a missing file falls back to `BasicShot` and prints one line; a good file fires a 480 px/s shot on the trigger. Depends: `ScriptHost`, `ShotPattern`.
2. **Editor shell.** Toggle on E, time scale 0.15 while open, text area, save, palette of the five §7.1 rows. Acceptance: saving a `damage` change affects the next shot without leaving the scene; time scale is 1 when the editor is shut; homing's row does not insert while `sense_nearest` is false. Depends: row 1. Q5 stays the open question for the 0.15 value.
3. **Errors and hot reload.** §7.5 and §7.3. Acceptance: a syntax error leaves the last good weapon firing and the line contains `line` plus `Still running the last good script.`; a PC write to the equipped file reloads; a broken write does not; a PC write to a different `shots/` file shows `shots/<f>.lua saved (not equipped)` and leaves the weapon alone. A fourth save while three versions still have hooked shots is accepted: the oldest shots become plain, there is no toast, and `script_saved` still fires. Time scale is 0.15 while the editor is open. Depends: row 1.
4. **Lesson hooks.** Lesson 5 passes only on `script_saved(file_name, origin)` for the equipped file (`origin` `editor` or `file`). `unequipped_file_saved(file_name)` is the toast and never passes a lesson. `weapon_swapped(file_name, origin)` is unchanged (`start`, `editor`, or `file`). Do not parse student source for gates. Acceptance: GE row 5 can be driven by `script_saved` from this editor. Depends: rows 2–3, GE row 5.
5. **`sense.nearest_enemy`.** `SenseBook` owns the count. It subscribes to `GameEvents.enemy_killed` (§6.1), increments only when `first_death` is true (dummy deaths count; a respawned dummy does not), and grants at 3. Level I clamps and defaults `range` to 600. SE makes the field non-nil and fires the toast, Codex page, and autocomplete highlight. GE does not count and does not call `grant` for this Sense. Acceptance: before 3 `first_death` events the field is `nil` and the homing row is grey; the third origin-dummy first death grants it; `e.hp` is `nil` and `e.rarity` is `""` on a dummy; reload keeps the field. Homing file from §6.3, stationary dummy at 220 px, fire every 0.25 s: at least 90% of shots hit and no shot orbits longer than 1 s; while strafing, at least 70% hit (measured 100% / 0.27 s / 100%). Depends: GE `query_radius`, GE rows 2 and 4, SE rows 2–3.
6. **`sense.enemies_in` Level I.** Grant only from the Warden. Clamp `r` to 600, cap 256, `kind` set, no vel/hp. Codex snippet §6.3, toast, autocomplete. Acceptance: the field is `nil` through the whole ribbon until the core dies; after the grant, a script that filters `kind == "warden"` steers at the core while a husk is nearer the player; a rare-tier flag is never set. Depends: row 5, GE row 10.
7. **Footer.** The save's `shards` integer, one number, no spend control. Acceptance: room D's death shows +3. Depends: GE rows 7 and 10.

Rows 1–3 are the early playable script loop. Row 5 lands with the dummy deaths. Row 6 waits on the boss.

## 12. Build order

The first playable combat run does not wait on Senses or on phase 3.

| Step | Who | Produces |
|---|---|---|
| 1 | GE 1 | Walk the ribbon with `BasicShot`, gates forced from a debug flag |
| 2 | SE 1–3 | The straight starter, save, hot reload, the error line. `BasicShot` no longer the default |
| 3 | GE 2–6, SE 4 | Field, absorb, lessons, Herald redirect. A player can clear C |
| 4 | GE 8, 10 | Phase-1 Warden, victory card, G0, respawn at the arena. **This is the first full run** |
| 5 | SE 5–6, GE 11 | `nearest_enemy` can already be in from the dummies; `enemies_in` and the HUD land here |
| 6 | GE 9, 12, 13, SE 7 | The rest of the fight, Hydra, Null-shot test, cues, shard footer |

## 13. Product decisions

Q25 and Q26 are **Decided (CoS call, Karyu may override)** on 2026-11-12. **Not open:** which Sense the Warden grants. That is `sense.enemies_in`, Level I, in the api.md table. `nearest_enemy` stays the free Sense after 3 `first_death` kills. Q5, Q6, Q7, Q14, Q15, Q27, and Q28 stay as they are in pillars. Q17–Q24 stay decided.

### Q25. Is the slice's first boss a guaranteed common Warden, or a seed roll?

- **A. Guaranteed common Warden** in the handcrafted arena. Rarity is not rolled. This kill is the starter boss for the save: always common, not in the pity ordinal, and the seed's pool-A pick is not placed.
- **B. Seed-rolled pool A** (Warden, Sower, or Prism), always common, on the legal starter slot (pillars §6.3). The slice cannot promise `enemies_in`.
- **C. Guaranteed Warden whose rarity uses the tier-1 boss table** (about 10% rare, 0% legendary). A rare kill grants Level II of `enemies_in`, which this slice does not build.

**Decided (CoS call, Karyu may override): A.** A guaranteed common Warden that counts as the save's starter boss.

### Q26. Where does that arena sit?

- **A. Compact ribbon in tier 0.** Arena centre `(9664, 0)`, chunk `(4, 0)`, centre D∞ 4.5. This one boss does not use the D∞ 8.5 / 9.5 rule. Outside the footprint that rule is unchanged.
- **B. The seed's legal starter chunk,** centre D∞ 8.5 or 9.5. Rooms S–D stay as in §2; the walk from D to the arena is procedural tier 0.
- **C. Compact Warden plus the seed starter later.** Two first bosses.

**Decided (CoS call, Karyu may override): A.** A compact arena at the end of the tier-0 ribbon. The distance exception applies only inside the slice footprint.

## 14. Engineer FAQ

### GE

**1. How does the run start and progress, what starts the boss, what ends it?**
Start at `(0, 0)` in room S, straight script firing, no hostile inside 512 px. Progress is the lesson gates, then the four packs in C, then the rare elite, then the arena (§1, §2). Lesson 2 requires the three origin dummies to have died once. Those are three `first_death` events. SE's `SenseBook` counts them and grants `nearest_enemy`. GE only emits `GameEvents.enemy_killed`. The boss aggros when the player crosses `x = 8736` after G5 is open. **Boss kill = the victory card in §5.6, then G0.** **Death = 1.5 s, respawn, keep everything.** The point is chosen when the respawn happens: the origin if the Warden is still alive, `(9664, 0)` if the Warden is already dead, even when the death came first. There is no quick-restart key. A living boss resets to 900 HP.

**2. Look, HP, phases, arena.**
Common Warden, hue `#3D7EFF`, radius 48, outline 3 px, glow disc from `RarityCue` (no bloom). **900 HP.** Phase 1 from 900, phase 2 at 630, phase 3 at 360. Arena rect `(8704, -704, 1920, 1408)`, centre `(9664, 0)`. Attacks, husks, and the tithe are §5.

**3. The Sense: mechanics, how it is shown, does it persist?**
`sense.enemies_in` Level I, positions (and `id`, `radius`, `kind`) within 600 px, cap 256. Shown once as a Codex page, a highlighted autocomplete row, and a toast `sense.enemies_in`. **It persists in the save** (`sense_enemies_in = 1`). Level II is not granted. `nearest_enemy` persists the same way. SE's `SenseBook` grants it at the third `GameEvents.enemy_killed` with `first_death` true. Dummy first deaths count. A respawned dummy does not.

**4. Player numbers.**
Max HP **5** pips. Contact **1 pip**. Enemy bullet **1 pip**. Every Warden attack in this slice deals **1 pip**. Hit i-frames **0.75 s**. Regen **+1 pip** every **3 s** after **5 s** without damage. Dash **160 px**, with **0.2 s** i-frames and a **1.5 s** cooldown. Own bullets never hurt the player. A reflected bullet is enemy-owned, `#FF5A4D`, and deals 1 pip.

**5. Enemy mix, density, tier odds.**
On the path: 3 Drifters, 10 Swarmers, 1 Shieldbearer, 1 Sniper, the Herald if it arms, 1 rare elite, 1 optional Hydra, 1 Warden. Outside the footprint, tier 0 stays 2 encounters per chunk, 4% common elite, 0% rare, 0% legendary. Tier ≥ 1 still spawns nothing. Room D and the alcove are placements, not rolls (§4).

**6. HUD.**
All of it is drawn on the player or the boss, not as a panel.

| Element | Draw |
|---|---|
| HP | **Game Designer call.** 5 pips on a ring radius **20** around the player. Filled white, empty hollow. Overheal continues in violet on that same ring, up to **5** extra pips (**10** total). Past that, a violet `+N` label, **10 px**, centred just below the ring, where `N = hp - 10`, and no more pips are drawn |
| Dash | Arc radius 24, stroke 2 px, fraction `1 - cooldown_left / 1.5`. Hidden when the dash is ready |
| Sense icons | **Game Designer call.** Two marks **4 px in diameter** at local `(0, 28)` and `(0, 36)`. Top is `nearest_enemy`, bottom is `enemies_in`. Hollow until that flag is set, then filled `#F2F2F2`. No Level II mark |
| Boss bar | **Game Designer call.** The gapless radius-78 arc in §5.5: 2 px, starts at 12 o'clock, fills clockwise to `hp / 900`. The 70° weak-point gap is only on the armor ring. Gone when the fight is over |
| Rarity tag | The cue itself (§8): ring count, tick count, outline weight. Common shows **no** text. **Game Designer call (GE PR #101):** only a legendary gets the 2 s name line (spawning §8.1). The rare elite has none. `Hydra` is the alcove elite's line. No `COMMON` chip |

### SE

**Senses in the slice.** `nearest_enemy` after 3 kills. `SenseBook` counts `GameEvents.enemy_killed` and grants it. Only `first_death` counts. Dummy deaths count: the three origin dummies' first deaths are the three, because lessons 1–2 kill them before any other body. A respawned dummy (`first_death` false) does not count. `enemies_in` at Level I after the Warden. The other four fields stay `nil`.

**Level II.** Not in this slice. When it exists later, it comes from a rare or legendary kill of that boss, or from 25 Shards (Q19). Not from a clean kill.

**How an unlock feels.** A Codex page with the snippet, the new `sense.*` name highlighted in autocomplete, and a one-time toast. Persisted, so a reload does not toast again.

**Minute-1 starters.** Straight (equipped), spread, spiral, split-on-hit, and homing. Homing is listed and locked until `nearest_enemy`.

**Errors.** Short plain language with the line number. The game keeps running on the last good script. The line ends with `Still running the last good script.`
