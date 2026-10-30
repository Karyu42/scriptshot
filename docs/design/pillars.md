# Scriptshot — Design Pillars

> Status: **proposal / draft for review.** Written when the repo contained only `README.md` and `LICENSE` (commits `e2ad1c3`, `e6f9c6a`; no issues or PRs). Nothing below describes existing code. Every number is a **starting value to be playtested**, not a law. Items marked **[DECISION]** need the project owner.

Scriptshot is a top-down, minimalist, twin-stick shooter (Godot 4 + Lua, MIT) where **you write the shot**. Your Lua script *is* your weapon, and nothing in the language is taken away from you. The world grows into an open world of regular enemies in which, rarely, a boss spawns instead. Bosses are the only points of interest.

---

## 1. What makes it unique

1. **The weapon is a program, with no leash.** Other games let you tune a weapon; here you write it. Spirals, homing swarms, bullets that spawn bullets, bullets that read the world: if you can express it in Lua, it fires.
2. **Challenge lives in the world, not in the sandbox.** We never limit what you may write. We make the world push back: armor that punishes spam, shields that punish straight lines, bosses that punish repetition.
3. **Every enemy and boss is a question your script answers.** Encounters are small puzzles with many valid solutions, not DPS checks. A boss kill is an *idea* you had, tested live.
4. **Edit while the world is hostile.** The script editor is in-game, hot-reloads in under one frame, and keeps the fight going (slowed). Iteration happens under pressure and is the core thrill.
5. **Minimalism makes code legible.** With almost no art noise, you can *see* your script's geometry. The game looks like the math you wrote.
6. **Shots are shareable artifacts.** A shot is a small text file. People can trade, read, fork and remix them (it's open source, so the culture should be too).

### Pillars (rules for every design decision)

| # | Pillar | Test: "does this feature…" |
|---|---|---|
| P1 | **Code is the weapon** | …make writing code more rewarding? If it replaces code with menus, cut it. |
| P2 | **No restrictions on the player, only pushback from the world** | …add a limit on what the player can write? If yes, reject. Express it as an enemy, a rule of physics, or a cost the world imposes instead. |
| P3 | **Legible minimalism** | …add visual/audio noise that hides the player's bullets? Cut or simplify. |
| P4 | **Discovery over tutorials** | …teach by showing and letting the player find it? No wall-of-text tutorials. |
| P5 | **Bosses are events** | …make a boss rarer, bigger, more memorable? Regular enemies exist to make the boss feel special and to give you something to test scripts on. |
| P6 | **Fast loop, deep ceiling** | A new player fires a custom shot in <60 s; an expert can still find new tricks after 50 h. |

---

## 2. Core loop

### Moment-to-moment (seconds)
Move (left stick / WASD), aim (right stick / mouse), hold fire. Firing triggers your script; the script decides what leaves the barrel.

### Encounter loop (minutes)
```
 explore → meet enemies → notice what your shot is bad at → edit script (live) →
 kill / survive → find a boss beacon → fight boss (learn its rules) → win a Fragment →
 new capability for your scripts → explore further out
```

### Meta loop (hours)
Fragments (see §4) unlock new *inputs and ideas* for your scripts; further from the origin, enemies are stronger and bosses more demanding. This makes you rewrite your shot from scratch, not just grind numbers.

### First 5 minutes (target flow)
1. Spawn at world origin with a default script visible on-screen (`shots/default.lua`), firing a single bullet.
2. Prompt: *"Press E to edit."* Time slows to 15% and a small editor opens beside the arena. The default script has two commented lines to tweak (`count`, `spread`).
3. Edit → save → the shot changes **immediately, without leaving the world**.
4. 3–4 weak enemies appear. One is a Shieldbearer (see §5): a straight shot bounces off, inviting a curved one.
5. At ~4 min a faint **boss beacon** (§6) appears at the screen edge. The player has found their first goal without a tutorial.

---

## 3. Scripting model (proposed API shape)

> The repo currently has no Lua integration. How Lua is bound to Godot 4 (GDExtension binding such as `lua-gdextension` vs. a hand-rolled binding) is an engineering decision to be made when scripting work starts; this doc defines the **player-facing contract** only.

A shot script is a Lua file in `shots/` returning a table of callbacks. Only `on_fire` is required.

```lua
-- shots/default.lua
return {
  -- called every time the fire trigger fires (rate set by `cooldown`)
  cooldown = 0.25,                       -- seconds
  on_fire = function(ctx)
    shoot{ angle = ctx.aim, speed = 480, damage = 10 }
  end,
}
```

```lua
-- shots/spiral.lua : 3-arm spiral that tightens over time
local t = 0
return {
  cooldown = 0.05,
  on_fire = function(ctx)
    t = t + 0.18
    for arm = 0, 2 do
      shoot{ angle = ctx.aim + t + arm * (math.pi * 2 / 3), speed = 320, damage = 3 }
    end
  end,
}
```

```lua
-- shots/seeker.lua : a bullet that steers toward the nearest enemy (needs the "nearest enemy" Sense, see §4)
return {
  cooldown = 0.5,
  on_fire = function(ctx)
    shoot{
      angle = ctx.aim, speed = 260, damage = 14, life = 3,
      update = function(b, dt)            -- optional per-bullet hook
        local e = sense.nearest_enemy(b.pos)
        if e then b:turn_toward(e.pos, 4 * dt) end
      end,
    }
  end,
}
```

**API surface (v0 proposal)**

| Always available (never gated) | Notes |
|---|---|
| Full Lua language: functions, closures, coroutines, tables, `math`, `string`, `table` | No limits on loops, recursion, or state. |
| `shoot{angle, speed, damage, life, radius, color?, update?, on_hit?, on_die?}` | `on_die` may call `shoot` → bullets spawning bullets. |
| `ctx`: `aim`, `pos`, `vel`, `hp`, `time`, `dt`, `shot_count` | Player's own state. |
| Persistent per-script `state` table | Survives respawn; saved in the save file. |

| Granted by Fragments (§4) | Examples |
|---|---|
| **Senses** (world information fed to code) | `sense.nearest_enemy`, `sense.enemies_in(r)`, `sense.enemy_bullets`, `sense.terrain`, `sense.boss` (phase, weak point), `sense.world` (seed, chunk coords) |

**Engine-side safeguards (technical, not player-facing limits).** To keep the game running we need a hard ceiling on simultaneously live bullets (starting value **4,000**) and a per-frame Lua time budget (starting value **4 ms**, then the script is paused for the frame and a small `!` shows in the editor). These are performance guarantees, not design limits; surfaced honestly in the editor ("bullet cap reached") so P2 stays intact. The cap itself is an **[open question]** (see Q5 under "Biggest open design questions").

---

## 4. Discovering and growing scripting power

### Design goal
The language and the shot API are **never** locked. What grows over time is *what the world tells your code* and *how much you understand what you can do*. Players keep exploring because every boss hands out a new way to **perceive** the world, which turns old scripts into new possibilities.

### Options considered **[DECISION]**

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A. Open Book** | Everything available from minute 1. Progress is purely knowledge: bosses drop *Codex pages* (docs, examples). | Purest read of "no restrictions". | Weak reward loop; players who read the docs get nothing from bosses; steep cliff for non-programmers. |
| **B. Senses & Codex** *(recommended)* | The language and the whole *output* side (`shoot`, bullet hooks, state) are open from minute 1. **Input** side grows: bosses drop **Senses** (world data feeds) plus **Codex pages** (annotated examples). | Honors "no restrictions" on writing; gives concrete, exciting rewards; each Sense changes what *kinds* of scripts are interesting (homing, dodging, boss-weak-point targeting). | Technically a gate on information; a player can still write the same code, but `sense.boss` returns `nil` until earned. Must be communicated clearly. |
| **C. Heat budget** | Everything open, but a Heat meter limits sustained bullet output; boss drops raise capacity or add cooling. | Familiar, easy to balance. | Limits what you can write per second, which conflicts with P2. Turns scripting into optimization of a meter. |

**Recommendation: B.** It keeps P2 truthful (you can write anything), delivers a tangible reward per boss, and every new Sense makes the *player's own code* more powerful, not a stat sheet. A is folded in for free via Codex pages. We should avoid C's cap on output; the world's armor and adaptation rules (§5) do that job instead.

### Sense progression (starting list)
| Tier | Sense | Unlocked by | What it enables |
|---|---|---|---|
| 0 | `ctx` (self), nothing else | Start | Fixed-pattern shots (spirals, fans, shotguns) |
| 0 | `sense.nearest_enemy` | **Free after first 3 kills** (teaches that senses exist) | Basic homing |
| 1 | `sense.enemies_in(r)` | Boss #1 | Area logic, triage targeting |
| 1 | `sense.enemy_bullets` | Boss #2 | Bullet-eating / deflect shots |
| 2 | `sense.terrain` | Boss #3 | Ricochet, wall-hugging bullets |
| 2 | `sense.boss` (phase, weak point, telegraphs) | Boss #4 | Precision boss-killing scripts |
| 3 | `sense.world` / persistent `state` across deaths | Boss #6+ | Long-term learning scripts, "memory" |

Bosses are **not** a fixed list; each boss type has a *Fragment* it drops once per save; Fragment order is not enforced (open world), so each tier is gated by distance (§6) rather than count.

### Discoverability (P4)
- **Codex pages** drop with Fragments: a 10-line annotated Lua example, never more than one screen.
- **Hints in the world**: enemies visibly telegraph their rules (a shield arc is drawn; an armored tank has a thick outline).
- **Editor affordances**: autocomplete lists *locked* Senses greyed with "found at: ???" so players know there's more to find.
- **Failure teaches**: when an armored enemy shrugs off your hit, a damage number reads `0` and the armor value flashes.

### Why keep exploring
1. Bosses are the only POIs, and each carries a unique Fragment: *no boss, no new Sense*.
2. Further from origin = tougher tiers = need for better scripts = need for new Senses.
3. Boss encounters are **puzzles with several solutions**; solving one in a way you didn't expect is its own reward (Codex "alternate solution" entries record notable ones).
4. Shot sharing (§7) and a per-boss "best time + script hash" board give mastery goals.

---

## 5. Challenge with unrestricted scripting

**Principle:** if a player can write a script that trivializes content, that is acceptable *only after* they discovered the idea, and the world should always have a next layer that makes them rethink. Challenge comes from enemy behavior and world physics; **never** from banning APIs.

### 5.1 Regular enemy archetypes (starting values; HP is at Tier 0)

| Enemy | HP | Move | Rule | What it pressures in your script |
|---|---|---|---|---|
| **Drifter** | 30 | 90 px/s toward player | none | Baseline: any shot works |
| **Swarmer** (groups of 8–14) | 6 | 140 px/s, erratic | dies to anything; surrounds | Area coverage, spread |
| **Shieldbearer** | 60 | 70 px/s | 120° front arc blocks bullets (visible arc) | Angles, curved or looping bullets, flanking |
| **Tank** | 400 | 50 px/s | **Armor 5**: each hit's damage is reduced by 5 (min 0) | Bullet damage per hit. 3-damage spam does **0**; big/slow bullets win |
| **Sniper** | 20 | stationary, 600 px range | Draws a 0.8 s telegraph line, then one hit for 25 | Movement, bullet range |
| **Phaser** | 80 | 100 px/s | Invulnerable except a 0.4 s pulse every 2.0 s | Timing, `sense.enemies_in`, burst scripts |
| **Mirror** | 50 | 80 px/s | Reflects bullets that strike its front head-on | Indirect shots, bullets that hit from the side |

Armor is the key anti-spam rule: it makes damage **per bullet** matter, so one cannot win by multiplying trivial bullets, yet it doesn't cap bullet count.

### 5.2 Tier scaling
Tier `T = floor(distance_from_origin / 4096 px)`. Per tier: HP ×(1 + 0.35·T), enemy count per encounter ×(1 + 0.15·T), new archetype pool opens at T1 (Shieldbearer, Sniper), T2 (Tank, Phaser), T3 (Mirror), and **combinations** appear from T2 (e.g., Shieldbearers escorting a Sniper).

### 5.3 Bosses (rules that matter for scripting)
- **Phases (3–4)** keyed to HP thresholds; each changes the attack set and the weak point.
- **Weak point**: only a specific part (e.g., rotating core) takes full damage; the rest takes ×0.1. Requires aiming or `sense.boss`.
- **Adaptation ("Habituation")**: the boss tracks the *pattern signature* of your recent bullets (angles bucketed into 24 × 15° sectors, speeds into 4 bands). If one signature makes up >70% of hits over 10 s, damage taken falls 10% per 5 s (floor ×0.4), recovering at 20%/5 s when you change patterns. Result: **players are pushed to edit scripts mid-fight**, the core unique thrill, without any restriction on code. Randomness spreads the signature, which is a legitimate counter-strategy (balanced by Armor and weak points).
- **Hazards authored as bullets** so the player's own sensing scripts (`sense.enemy_bullets`) can read and counter them.
- **Telegraphs**: every dangerous attack shows a ≥0.5 s warning in the boss's color (P3).

### 5.4 Player vulnerability
Player HP **100**, no regen except 1 pickup type dropped by regular enemies (+10, 8% drop). Contact = 15, bullet = 10, Sniper = 25. No i-frames beyond 0.4 s after a hit. Death rules are an **[open question]** (Q4).

---

## 6. Open world and rare bosses

### 6.1 World structure
- **Infinite, chunked, seeded.** Chunk size **2048×2048 px**. Active ring: 3×3 chunks around the player; others are unloaded and regenerated deterministically from `(world_seed, chunk_x, chunk_y)`.
- **Same seed = same world** (so seeds can be shared; see §7).
- **No landmarks other than bosses** in this version: terrain is empty ground with sparse, minimal obstacles (a few static blocks per chunk, needed for later `sense.terrain`).
- Origin is a safe zone: radius 512 px, no spawns.

### 6.2 Regular spawn rule
When a chunk is first loaded, roll an **encounter budget** `B = 6 + 4·T` points. Spend points on archetypes allowed by tier: Drifter 1, Swarmer group 3, Shieldbearer 3, Sniper 3, Tank 5, Phaser 4, Mirror 4. Enemies start idle (wander) until the player is within 700 px. Cleared chunks respawn after 5 min of being out of the active ring (so the world feels alive but not farmed forever).

### 6.3 Boss spawn rule ("a boss spawns *instead*")
When a chunk is **first generated**, make one boss roll *before* the regular spawn roll:

```
boss_chance(n) = min(0.5% + 0.25% · n, 8%)    where n = new chunks generated since last boss
if roll < boss_chance(n):  chunk becomes BOSS CHUNK (no regular enemies) ; n = 0
else:                      regular spawns (§6.2)                          ; n += 1
```
Plus hard rules: **no two boss chunks within 6 chunks of each other**, and **no boss chunk within 4 chunks of the origin**.

Simulated outcome of the odds above (100k trials): **mean ≈ 25 newly generated chunks between bosses, median 23, 95th percentile 51, rare worst cases >100.** At 220 px/s a 2048 px chunk takes ~9 s to cross, so while exploring in a straight line that's roughly one boss per 4–6 minutes; much less if the player lingers. Tunable: lower `base` and `step` to make bosses rarer.

- **Determinism caveat:** a pity counter based on chunk-generation order makes the world depend on the player's travel order, so the same seed would not give the same boss layout. Q3 below proposes a deterministic alternative (per-region quotas); the pity formula above is the baseline to compare against.
- **Boss chunk persists** until the boss is killed; after that it never respawns that boss in this save (Fragment already earned), and the chunk becomes ordinary.
- **Boss types** are selected by tier: T0–1 boss pool A (3 bosses), T2–3 pool B, T4+ pool C. A launch target of **6 distinct handcrafted bosses**, with procedurally varied colors/parameters.

### 6.4 Finding bosses without markers (P3, P4)
There is no map icon. Boss presence is **sensed**:
- A low-frequency audio hum that rises with proximity (audible within 3 chunks).
- A faint, slowly rotating **edge-of-screen tick mark** in the boss's color that points toward the nearest undefeated boss within 5 chunks.
- The ground grid **bends subtly** near a boss chunk (a post-process warp, ≤3 px displacement).

---

## 7. Sharing and community (low cost, high identity)
- Shots are plain `.lua` files; a **share code** is a compressed, base64 copy of one script plus metadata (name, author, Senses required). Importing shows the full source before enabling.
- **Seed sharing**: the same seed gives the same chunk and boss layout (subject to Q3).
- Later (not in scope now): in-repo `community-shots/` folder via PRs.

> **Safety note.** The language is open, but loading someone else's script runs code on the player's machine. Imported scripts should run with `os`, `io`, `debug`, `package`, and `load*` from files **disabled** (the player's own scripts may opt in). This is a security measure, not a gameplay restriction; it needs owner sign-off (Q2).

---

## 8. Visual and audio direction

### 8.1 Visual
- **Shapes only.** Circles, lines, triangles, squares; no textures, no sprites. Everything is drawn from vector primitives (`_draw()` / shaders), anti-aliased.
- **Palette** (starting values): background `#0B0D10`; faint grid `#161A20`; player white `#F2F2F2`; player bullets bright white by default (script may set `color`); enemy bullets warm `#FF5A4D`; enemies each a single cool or neutral hue by *role*: Drifter `#7DA2FF`, Swarmer `#7DE0C3`, Shieldbearer `#C9A7FF`, Tank `#8C8C8C`, Sniper `#FFD166`, Phaser `#F28FD0`, Mirror `#E8E8E8` outline. Bosses: one saturated hue each, larger than anything else (≥3× player size), with a glow.
- **Readability rule (P3):** enemy bullets are always warmer and brighter than the background, player bullets cooler/white. Bullet count never hides the player: the player has a 12 px white core with a thin dark halo at all times.
- **Juice, minimal:** 2-frame hit flash, tiny screen shake (≤3 px) only on boss phase changes, bullets leave a 6-frame fading trail so the *path of your script* is visible (this is the signature look).
- **Editor UI:** monospace font, same palette, syntax highlighting in 4 colors; no chrome beyond a 1 px border.
- **Camera:** fixed zoom (1 world unit = 1 px at 1080p), slight lead toward the aim direction (≤80 px).

### 8.2 Audio
- **Generative, tonal, sparse.** No samples needed at first: synthesized sine/triangle plucks.
- **Your script has a voice:** each `shoot` call triggers a pluck whose pitch maps to bullet speed and whose duration maps to bullet life, quantized to a pentatonic scale so dense scripts sound harmonic, not noisy. Voice count is capped (e.g., 16) with the rest folded into a quiet shimmer.
- **Ambient bed:** a slow drone that shifts key with Tier; silence is welcome.
- **Bosses:** each has a short layered motif that *adds a stem per phase*; the beacon hum (§6.4) is the first stem, so approaching it is audibly "the music starting".
- **Feedback sounds:** hit ticks, armor "clink" (distinct from damage, so a `0` hit is audible), a clear low tone when a Fragment is earned.
- **Accessibility:** colorblind-safe palette check, audio cues have visual equivalents, volume sliders per bus (music, shots, world).

---

## 9. Scope guide (what to build first)
Sequenced so that each step is playable:
1. Player movement + aim + one hardcoded `shoot`.
2. Lua binding: load `shots/default.lua`, `on_fire`, hot reload, in-game editor.
3. Drifter + Swarmer + player HP.
4. Chunked world, seed, regular spawns (§6.2).
5. Armor/Shield/Mirror archetypes.
6. First boss + Fragment + `sense.*` gating + Codex.
7. Boss spawn rule + beacon (§6.3–6.4).
8. Audio voices from scripts; visuals polish; share codes.

---

## Biggest open design questions

Each needs a decision; recommendation is given. Items tagged **[Karyu]** need the project owner's decision.

### Q1. How does scripting power grow? **[Karyu]**
- **A. Open Book:** everything available, progress is knowledge (Codex only).
- **B. Senses & Codex:** output side fully open, input data (Senses) unlocked by bosses. 
- **C. Heat budget:** open API but a resource caps sustained output.
- **Recommendation: B.** It's the only option that gives bosses a concrete, script-changing reward while keeping "you can write anything" true. (§4)

### Q2. What does "no restrictions" mean for the Lua environment? **[Karyu]**
- **A. Full Lua stdlib for everyone** (incl. `os`, `io`, `load`), maximum freedom, but shared scripts can read/write files.
- **B. Full language, with OS-touching libs off for *imported* scripts; your own scripts may opt in** (trust prompt).
- **C. Game-API-only sandbox for all scripts** (no `io`/`os`/`load` anywhere).
- **Recommendation: B.** Keeps true freedom for the author, safety for a sharing culture.

### Q3. Boss spawn: pity timer vs deterministic world
- **A. Pity timer (§6.3 formula):** guarantees pacing, but the world depends on exploration order, so seeds don't reproduce layouts.
- **B. Region quotas (hash per 8×8-chunk region):** worlds are reproducible; pacing varies but is bounded by region size.
- **C. Hybrid:** B for placement, plus a small pity bump (+1% per 10 chunks without a boss) computed from distance travelled in a region, not chunk order, so determinism remains.
- **Recommendation: C.** Reproducible seeds are a core sharing feature (§7) and the pity bump protects feel. **[Karyu]** if "rare" should mean ~1 per 25 chunks (current) or notably rarer.

### Q4. Death and stakes **[Karyu]**
- **A. Respawn at origin, keep everything:** low stakes, encourages experiments.
- **B. Respawn at origin, lose 50% of current-tier *progress* (regular-enemy drops), keep Fragments and scripts.**
- **C. Permadeath (per run), meta-progress via Codex only.**
- **Recommendation: A for the first release; revisit B after playtests.** Experiments are the point of the game; punishing them conflicts with P1/P6. Boss fights should feel high-stakes through difficulty, not loss.

### Q5. Editing while the world is hostile
- **A. Time slows to ~15% while the editor is open** (recommended start).
- **B. Full pause** (safer, kills tension and the live-edit thrill).
- **C. Real-time, world keeps running** (maximum tension, hard on touch/laptops).
- **D. Setting:** let the player choose. 
- **Recommendation: A as default, D later** as an accessibility setting; also decide the **bullet/CPU ceilings** (starting 4,000 bullets / 4 ms) and how we communicate them (P2).

### Q6. Boss "Habituation" mechanic: is it too punishing or exploitable?
- **A. Keep as specified** (§5.3), tune on playtests.
- **B. Soft version:** adaptation reduces damage only to the *dominant* pattern, floor ×0.6.
- **C. Drop it:** rely on armor, weak points, and phases.
- **Recommendation: A, prototyped behind a flag.** It's the most distinctive way to create tension *without* limiting code, but needs playtest to avoid feeling like "the boss punishes me for finding something that works".

### Q7. Where do bosses sit in the long-term open world?
- **A. Bosses stay the only POIs** (current brief) with escalating tiers.
- **B. Add POIs after the first release** (shops, ruins) that sell/teach Senses.
- **Recommendation: A for now**, as specified, designing the Fragment/Codex systems so B can be added later without redoing progression.

### Q8. Scope and platform
- **A. Desktop (Win/Linux/macOS), keyboard+mouse and gamepad** (recommended).
- **B. + mobile/web** (Godot export is possible, but the in-game code editor is hostile on touch).
- **Recommendation: A**, with web export as a stretch goal for share-a-shot demos. **[Karyu]**
