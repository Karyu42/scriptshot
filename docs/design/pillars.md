# Scriptshot — Design Pillars

> Status: **draft for review, revision 2 (owner decisions of 2026-10-30 folded in).** Written when the repo contained only `README.md` and `LICENSE` (commits `e2ad1c3`, `e6f9c6a`; no issues or PRs). Nothing below describes existing code. Every number is a **starting value to be playtested**, not a law. Resolved questions live in the **Decisions log** below; the questions still open are at the end of the doc (question IDs are stable, so Q1–Q4 and Q8 are resolved and absent from the open list).

Scriptshot is a top-down, minimalist, twin-stick shooter (Godot 4 + Lua, MIT) where **you write the shot**. Your Lua script *is* your weapon, and nothing in the language is taken away from you. It ships on PC (mouse + keyboard), controller, web and mobile. The world grows into an open world of regular enemies in which, rarely, a boss spawns instead. Bosses are the only points of interest.

---

## Decisions log (2026-10-30)

Decided by the project owner. Everything else in this doc stays a proposal.

| ID | Decision | Where it lands |
|---|---|---|
| Q1 | **Main mode: fully open API, bosses unlock Senses (option B).** A **separate, planned game mode** with deliberately limited scripting power (budgets, unlockable API, stat-driven, possibly RPG-style) is added as a future mode, **not in the first release**. | §4, §11 |
| Q2 | **Maximum freedom.** The player's own scripts get **full Lua, including opt-in OS and file access**. The *only* engine-level guard rails are those that prevent crashes and hangs (instruction/time budgets, memory caps, error isolation, entity cap). **Script sharing is in**: any script from another player shows a clear malicious-code warning before it runs; OS and file access are **off by default for imported scripts** and the player may enable them explicitly. | §3.2, §7 |
| Q3 | **Boss spawn: hybrid** of deterministic region quotas plus a distance-based pity bump (former option C). Same seed = same bosses. | §6.3 |
| Q4 | **Death: respawn at origin, keep everything** (former option A). | §5.4 |
| Q8 | **All platforms: PC mouse + keyboard, controller, web and mobile.** | §10 (and design implications in §3.2, §8, §9) |

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
| P2 | **No restrictions on the player, only pushback from the world** | …add a limit on what the player can write? If yes, reject. Express it as an enemy, a rule of physics, or a cost the world imposes instead. (Sole exception: the crash/hang guards in §3.2.) |
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
2. Prompt: *"Press E to edit"* (controller: a face button; touch: an edit button). Time slows to 15% and a small editor opens beside the arena (on small touch screens it opens full-screen with the arena frozen at 15% in a corner preview; see §10). The default script has two commented lines to tweak (`count`, `spread`).
3. Edit → save → the shot changes **immediately, without leaving the world**.
4. 3–4 weak enemies appear. One is a Shieldbearer (see §5): a straight shot bounces off, inviting a curved one.
5. At ~4 min a faint **boss beacon** (§6) appears at the screen edge. The player has found their first goal without a tutorial.

---

## 3. Scripting model (proposed API shape)

### 3.1 Player-facing API

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
| Full Lua language and standard library (own scripts; `os`/`io` opt-in, see §3.2) | No design limits on loops, recursion, or state. Only the crash/hang guards of §3.2. |
| `shoot{angle, speed, damage, life, radius, color?, update?, on_hit?, on_die?}` | `on_die` may call `shoot` → bullets spawning bullets. |
| `ctx`: `aim`, `pos`, `vel`, `hp`, `time`, `dt`, `shot_count`, `device` (`"kbm"`, `"pad"`, `"touch"`) | Player's own state; `device` lets a script adapt (e.g., wider autoaim cone on touch) without the engine granting any input-based advantage. |
| Persistent per-script `state` table | Survives respawn; saved in the save file. |

| Granted by Fragments (§4) | Examples |
|---|---|
| **Senses** (world information fed to code) | `sense.nearest_enemy`, `sense.enemies_in(r)`, `sense.enemy_bullets`, `sense.terrain`, `sense.boss` (phase, weak point), `sense.world` (seed, chunk coords) |

### 3.2 Script environment and the only engine guard rails

**The player's own scripts get full Lua**: the whole standard library including `os`, `io`, `debug`, `package`, `load`/`loadstring`/`dofile`, `require` of local files, and any other library the binding exposes. `os`/`io`/file access is **opt-in per script**: a script declares what it needs in its returned table, e.g. `needs = {"os", "io"}`, and the player confirms once per script in the editor (a clear one-line prompt, remembered per script).

```lua
return {
  needs = {"io"},            -- opt-in; shown in the editor header and in the share code
  on_fire = function(ctx)
    local f = io.open("shots/log.txt", "a"); f:write(ctx.time, "\n"); f:close()
    shoot{ angle = ctx.aim, speed = 480, damage = 10 }
  end,
}
```

**The sole engine-level guards (they exist to prevent crashes and hangs, never to shape gameplay):**

| Guard | Starting value | Behaviour |
|---|---|---|
| **Per-frame time budget** for all script callbacks | 4 ms on PC (tune per platform; see §10) | When exceeded the remaining callbacks are skipped for that frame, and a small `!` appears in the editor with the measured time. The game never drops below its frame floor because of a script. |
| **Instruction budget per callback** (watchdog against infinite loops, e.g., Lua count hook) | 5,000,000 VM instructions per callback invocation | The callback is aborted with an error (`script timeout`) and the game keeps running. 3 consecutive timeouts suspend that script until it is saved again. |
| **Memory cap** per script (separate Lua allocator accounting) | 128 MB on PC, lower on web/mobile | Allocation beyond the cap raises a Lua error inside the script; the script is suspended and the editor shows the usage. |
| **Error isolation** | always on | Every callback (`on_fire`, `update`, `on_hit`, `on_die`) runs in a protected call. A Lua error never crashes the game; it prints to the editor console with file/line and disables only that callback until the next save. The previous working version can be restored with one key. |
| **Live-bullet entity cap** (to keep the physics/renderer alive) | 4,000 on PC (lower on web/mobile, §10) | New `shoot` calls beyond the cap are dropped, and the editor shows "bullet cap reached". This is a performance ceiling, not a design limit; we expect to raise it as the engine is optimized. |

Everything else is *not* restricted: loops, recursion, coroutines, global state, bullet counts below the cap, file and OS access (with opt-in). If a guard is hit, the player is told exactly which one and why (P2 stays honest).

**Provenance.** The game keeps a flag per script file: *own* (authored in the local editor or hand-placed in `shots/`) or *imported* (arrived through a share code, a download, or a link). Imported scripts are stored in `shots/imported/` with their metadata. Rules for them are in §7.

**Platform notes.** OS/file capability depends on the platform: on **web** there is no real OS or file access (see §10), and mobile OSes sandbox file access to the app's data folder. A script that declares `needs` the platform cannot satisfy still loads, but those libraries are `nil` and the editor says why. The `needs` list travels with the script so other players can see portability before running it.

---

## 4. Discovering and growing scripting power

### Design goal
The language and the shot API are **never** locked. What grows over time is *what the world tells your code* and *how much you understand what you can do*. Players keep exploring because every boss hands out a new way to **perceive** the world, which turns old scripts into new possibilities.

### Options considered (**decided 2026-10-30: B for the main mode**)

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A. Open Book** | Everything available from minute 1. Progress is purely knowledge: bosses drop *Codex pages* (docs, examples). | Purest read of "no restrictions". | Weak reward loop; players who read the docs get nothing from bosses; steep cliff for non-programmers. |
| **B. Senses & Codex** *(chosen for the main mode)* | The language and the whole *output* side (`shoot`, bullet hooks, state) are open from minute 1. **Input** side grows: bosses drop **Senses** (world data feeds) plus **Codex pages** (annotated examples). | Honors "no restrictions" on writing; gives concrete, exciting rewards; each Sense changes what *kinds* of scripts are interesting (homing, dodging, boss-weak-point targeting). | Technically a gate on information; a player can still write the same code, but `sense.boss` returns `nil` until earned. Must be communicated clearly. |
| **C. Heat budget** | Everything open, but a Heat meter limits sustained bullet output; boss drops raise capacity or add cooling. | Familiar, easy to balance. | Limits what you can write per second, which conflicts with P2. Turns scripting into optimization of a meter. |

**Decision: B.** It keeps P2 truthful (you can write anything), delivers a tangible reward per boss, and every new Sense makes the *player's own code* more powerful, not a stat sheet. A is folded in for free via Codex pages. We avoid C's cap on output in the main mode; the world's armor and adaptation rules (§5) do that job instead. The idea behind C (limited power as a *design* feature) is not discarded: it moves to the **separate planned mode in §11**.

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
Tier `T = floor(distance_from_origin / 12288 px)` (6 chunks per tier; this is a revision from the first draft's 4096 px so that the guaranteed first boss at 5–8 chunks sits in Tier 0–1). Per tier: HP ×(1 + 0.35·T), enemy count per encounter ×(1 + 0.15·T), new archetype pool opens at T1 (Shieldbearer, Sniper), T2 (Tank, Phaser), T3 (Mirror), and **combinations** appear from T2 (e.g., Shieldbearers escorting a Sniper).

### 5.3 Bosses (rules that matter for scripting)
- **Phases (3–4)** keyed to HP thresholds; each changes the attack set and the weak point.
- **Weak point**: only a specific part (e.g., rotating core) takes full damage; the rest takes ×0.1. Requires aiming or `sense.boss`.
- **Adaptation ("Habituation")**: the boss tracks the *pattern signature* of your recent bullets (angles bucketed into 24 × 15° sectors, speeds into 4 bands). If one signature makes up >70% of hits over 10 s, damage taken falls 10% per 5 s (floor ×0.4), recovering at 20%/5 s when you change patterns. Result: **players are pushed to edit scripts mid-fight**, the core unique thrill, without any restriction on code. Randomness spreads the signature, which is a legitimate counter-strategy (balanced by Armor and weak points).
- **Hazards authored as bullets** so the player's own sensing scripts (`sense.enemy_bullets`) can read and counter them.
- **Telegraphs**: every dangerous attack shows a ≥0.5 s warning in the boss's color (P3).

### 5.4 Player vulnerability
Player HP **100**, no regen except 1 pickup type dropped by regular enemies (+10, 8% drop). Contact = 15, bullet = 10, Sniper = 25. No i-frames beyond 0.4 s after a hit. **Death (decided, Q4):** on death the player respawns at the world origin and **keeps everything** (Fragments, Codex, scripts, `state`, the world). The cost of dying is time (the walk back) and the boss fight in progress: a living boss resets to full HP and its chunk reloads. No XP loss, no drop. Stakes come from difficulty, not from loss.

---

## 6. Open world and rare bosses

### 6.1 World structure
- **Infinite, chunked, seeded.** Chunk size **2048×2048 px**. Active ring: 3×3 chunks around the player; others are unloaded and regenerated deterministically from `(world_seed, chunk_x, chunk_y)`.
- **Same seed = same world** (so seeds can be shared; see §7).
- **No landmarks other than bosses** in this version: terrain is empty ground with sparse, minimal obstacles (a few static blocks per chunk, needed for later `sense.terrain`).
- Origin is a safe zone: radius 512 px, no spawns.

### 6.2 Regular spawn rule
When a chunk is first loaded, roll an **encounter budget** `B = 6 + 4·T` points. Spend points on archetypes allowed by tier: Drifter 1, Swarmer group 3, Shieldbearer 3, Sniper 3, Tank 5, Phaser 4, Mirror 4. Enemies start idle (wander) until the player is within 700 px. Cleared chunks respawn after 5 min of being out of the active ring (so the world feels alive but not farmed forever).

### 6.3 Boss spawn rule ("a boss spawns *instead*") — decided hybrid (Q3)

**Goal:** bosses are rare, paced so players are never boss-starved for long, and **the same seed always gives the same boss layout** regardless of the order the player explores.

- **Regions.** Chunks are grouped into **8×8-chunk regions** (16,384 px). A boss is placed on a *chunk*; a boss chunk gets **no regular enemies** (the boss spawns *instead*) and is not rolled again.
- **Canonical order.** Regions are decided in a fixed order that depends only on the seed: ring by ring outward from the origin region (ring = Chebyshev distance of the region's coordinates), and clockwise from the top inside a ring. A region's decision may depend on earlier regions in this order, **never on where the player has walked**, so worlds stay reproducible. (Ring *k* has 8k regions, so evaluating up to the player's ring is cheap and cacheable.)
- **Per-region quota with distance pity.** For region *R*, let `d` = chunk distance from *R*'s centre to the nearest boss chunk already placed (capped at 80):

```
p_first  = min(0.45 + 0.05 * floor(d / 10), 0.90)   # pity bump: +5 % per 10 chunks without a boss nearby
p_second = 0.20                                      # independent roll, can add a second boss
roll  u1 = hash(seed, R, "boss1"),  u2 = hash(seed, R, "boss2")
boss count = (u1 < p_first ? 1 : 0) + (u2 < p_second ? 1 : 0)
chunk(s)   = hash(seed, R, i) picks a chunk in R that is
             >= 6 chunks from any other boss chunk and >= 4 chunks from the origin
             (if no valid chunk exists, that boss is skipped)
```
- **Starter boss.** The origin region always gets exactly one boss at 5–8 chunks from the origin (Tier 0–1), so the first goal is never far. Its beacon range is extended to 6 chunks (§6.4).
- **Expected density (starting values):** about **0.75 bosses per region ≈ one per ~85 chunks of area**, with the pity term making long boss-free stretches very unlikely. The earlier draft's path-based figure ("one per ~25 newly generated chunks") is superseded because it depended on travel order. The right rarity is a tuning question (Q9).
- **Boss chunk persists** until the boss is killed; after that that boss never respawns in this save (the Fragment is already earned) and the chunk becomes ordinary.
- **Boss types** are selected by tier: T0–1 boss pool A (3 bosses), T2–3 pool B, T4+ pool C. A launch target of **6 distinct handcrafted bosses**, with procedurally varied colors/parameters.

### 6.4 Finding bosses without markers (P3, P4)
There is no map icon. Boss presence is **sensed**:
- A low-frequency audio hum that rises with proximity (audible within 3 chunks; 6 for the starter boss).
- A faint, slowly rotating **edge-of-screen tick mark** in the boss's color that points toward the nearest undefeated boss within 5 chunks (8 for the starter boss).
- The ground grid **bends subtly** near a boss chunk (a post-process warp, ≤3 px displacement).

---

## 7. Sharing and community (in scope; decided Q2)
- Shots are plain `.lua` files; a **share code** is a compressed, base64 copy of one script plus metadata (name, author, Senses required, `needs` such as `os`/`io`, platform notes). On web a share code can also be a URL.
- **Seed sharing**: the same seed gives the same chunk and boss layout (§6.3, decided).
- Later (not in scope now): in-repo `community-shots/` folder via PRs.

### 7.1 Running someone else's script (imported scripts)
Loading another player's script runs arbitrary code. We do **not** restrict what it may do in-game, but we make the risk explicit:

1. **Warning before first run, every time a new script is imported** (not dismissible with a "don't show again" for scripts that declare `needs`). Full-screen, plain language, e.g.: *"This script was made by another player. Scripts are programs and can contain malicious code. Only run scripts you trust. [View source] [Run without OS/file access] [Cancel]"*.
2. **Source view is one click away** and syntax-highlighted; the `needs` list and author are shown at the top.
3. **OS and file access are off by default for imported scripts** (`os`, `io`, `debug`, `package`, `load*`-from-file, `require` of non-shipped files are `nil`). The player may enable them explicitly with a second, separate confirmation naming each capability (*"Allow this script to read and write files on your device?"*). The choice is stored per script and revoked if the file's content hash changes.
4. Everything else (full Lua, all `shoot` features, Senses the player has earned) runs normally. The §3.2 crash/hang guards apply to all scripts.
5. Editing an imported script does **not** silently make it *own*. The editor offers **"Mark as mine"**, which asks for confirmation (Q12).

> **Honest limit:** this is a warning and a default, not a sandbox guarantee. Players who enable OS/file access for an untrusted script accept the risk. The doc and the in-game text must say so.

---

## 8. Visual and audio direction

### 8.1 Visual
- **Shapes only.** Circles, lines, triangles, squares; no textures, no sprites. Everything is drawn from vector primitives (`_draw()` / shaders), anti-aliased.
- **Palette** (starting values): background `#0B0D10`; faint grid `#161A20`; player white `#F2F2F2`; player bullets bright white by default (script may set `color`); enemy bullets warm `#FF5A4D`; enemies each a single cool or neutral hue by *role*: Drifter `#7DA2FF`, Swarmer `#7DE0C3`, Shieldbearer `#C9A7FF`, Tank `#8C8C8C`, Sniper `#FFD166`, Phaser `#F28FD0`, Mirror `#E8E8E8` outline. Bosses: one saturated hue each, larger than anything else (≥3× player size), with a glow.
- **Readability rule (P3):** enemy bullets are always warmer and brighter than the background, player bullets cooler/white. Bullet count never hides the player: the player has a 12 px white core with a thin dark halo at all times.
- **Juice, minimal:** 2-frame hit flash, tiny screen shake (≤3 px) only on boss phase changes, bullets leave a 6-frame fading trail so the *path of your script* is visible (this is the signature look).
- **Editor UI:** monospace font, same palette, syntax highlighting in 4 colors; no chrome beyond a 1 px border. Must scale to phone screens: minimum 16 dp touch targets, adjustable font size (see §10).
- **Camera:** fixed zoom (1 world unit = 1 px at 1080p), slight lead toward the aim direction (≤80 px). On phones the zoom is by *world extent*, not pixels: the visible area is at least 1280×720 world units, so that bullets stay visible and the game isn't easier or harder by screen size.

### 8.2 Audio
- **Generative, tonal, sparse.** No samples needed at first: synthesized sine/triangle plucks.
- **Your script has a voice:** each `shoot` call triggers a pluck whose pitch maps to bullet speed and whose duration maps to bullet life, quantized to a pentatonic scale so dense scripts sound harmonic, not noisy. Voice count is capped (e.g., 16) with the rest folded into a quiet shimmer.
- **Ambient bed:** a slow drone that shifts key with Tier; silence is welcome.
- **Bosses:** each has a short layered motif that *adds a stem per phase*; the beacon hum (§6.4) is the first stem, so approaching it is audibly "the music starting".
- **Feedback sounds:** hit ticks, armor "clink" (distinct from damage, so a `0` hit is audible), a clear low tone when a Fragment is earned.
- **Accessibility:** colorblind-safe palette check, audio cues have visual equivalents, volume sliders per bus (music, shots, world).

---

## 9. Scope guide (what to build first)
Sequenced so that each step is playable. All of it targets **every platform in §10**, so platform-affecting choices are made early:
1. Player movement + aim + one hardcoded `shoot`, with an **input abstraction** (kbm, controller, touch) from day one.
2. **Spike (before committing the stack): Lua binding + Godot 4 export to Web and Android/iOS** (see Q14). Then load `shots/default.lua`, `on_fire`, hot reload, in-game editor.
3. Guard rails of §3.2 (time/instruction/memory budgets, error isolation) built together with the binding, not later.
4. Drifter + Swarmer + player HP.
5. Chunked world, seed, regular spawns (§6.2).
6. Armor/Shield/Mirror archetypes.
7. First boss + Fragment + `sense.*` gating + Codex.
8. Region-quota boss spawn + beacon (§6.3–6.4).
9. Controller- and touch-friendly editor (§10); share codes with the import warning (§7.1).
10. Audio voices from scripts; visuals polish.
11. **Not first release:** the limited-scripting mode (§11); step 2's binding must already allow per-mode capability sets.

---

## 10. Platforms and input (decided Q8: PC, controller, web, mobile)

| Platform | Play input | Script editing | Capability notes |
|---|---|---|---|
| **PC** (Win/Linux/macOS) | Mouse + keyboard (WASD + mouse aim) | Full in-game editor; also **external editor hot reload** (watch `shots/`) | Full Lua, opt-in `os`/`io` (§3.2) |
| **Controller** | Left stick move, right stick aim + auto-fire past deadzone (or trigger) | Controller-friendly editor (below) | Same as PC |
| **Web** | Mouse + keyboard (touch/controller if present) | In-game editor; clipboard paste of share codes | **No OS or real file access** (browser sandbox): `os` is `nil`, `io` is absent or a virtual file system (Q14). Lower entity/time budgets. Needs a Lua binding that exports to Web (Q14). |
| **Mobile** (Android, iOS) | Twin virtual sticks (left move, right aim + auto-fire) | Touch editor and/or companion editing (below) | File access limited to the app sandbox, no `os.execute`. Lower budgets. |

### 10.1 Design implications
- **One game, one ruleset.** Enemies, Senses, damage, spawns and bosses are identical across platforms. The player's *device* is exposed as `ctx.device`, so scripts can adapt, but the engine adds no hidden bonuses. Aim assist is the one deliberate exception and is an open question (Q15).
- **The editor is a first-class feature on every platform** (P1: *code is the weapon*). It may not be dumbed down into menus on touch; instead the *input method* is helped.
- **Touch-friendly script editor** (starting design):
  - Full-screen editing on phones; the arena keeps running at 15% in a small corner preview (§2), and a one-tap *resume* button.
  - A **symbol row** above the OS keyboard (`( ) { } [ ] , . = " ' end function`), an **indent/dedent** button, bracket auto-close, large undo/redo.
  - **Snippet palette** (insert `shoot{}` skeletons, loops, `update` hook) and **tunable number sliders**: numeric literals marked `--@tune 0..1` or recognized in `shoot{}` get a slider on touch and controller. These help typing; they never replace code.
  - Pinch to resize text; landscape and portrait layouts.
- **Companion editing.** Edit on a second device while playing: (a) **PC external-editor hot reload** (watch `shots/`), (b) **phone as editor for a PC session** or **PC browser as editor for a phone session** over LAN/QR pairing, with live reload within one frame. Starting scope: (a) in the first release; (b) as a stretch (Q13).
- **Controller-friendly editor navigation.** D-pad / stick moves a *token cursor* (jumps by word, bracket, line); face buttons insert from a radial snippet menu; shoulder buttons change the number under the cursor ±step (tunable literals); the OS/Steam-style on-screen keyboard for free text; a **"quick tune" mode** that cycles through tunable numbers without text entry at all.
- **Web build sandbox limits.** No OS or file access, so `needs = {"os"}`/`{"io"}` scripts print an explanation and run with those libraries `nil`. Saves and `shots/` live in browser storage (IndexedDB) with an **Export / Import** button for `.lua` files and saves. Lower budgets: entity cap 2,000 and 3 ms (starting values). Web builds must work without threads if the host (e.g., itch.io) can't provide cross-origin isolation.
- **Mobile budgets.** Entity cap 1,500 and 3 ms per frame (starting values) with thermal-aware reduction; battery saver mode reduces trails and audio voices (§8).
- **Saves.** One save format on all platforms; cloud/cross-device sync is a later option (Q15).
- **Shared scripts across platforms** keep working: if a script exceeds a lower platform budget it is clamped by the §3.2 guards and the editor shows exactly which one.
- **UI layout.** HUD is minimal already (P3); on touch the sticks are drawn as thin outlines at 40% opacity, position-adjustable, and never over the player's own bullets' path (sticks placed in the lower corners).
- **Audio on web/mobile.** Synthesized audio (§8.2) must start after the first user gesture (browser autoplay rules); voice cap lower on mobile.

---

## 11. Planned mode (NOT first release): Constrained Scripting mode

> Working title: **Constrained mode** (name TBD). **Status: planned.** It is a *separate game mode* with its own save; the main mode (§1–§10) keeps its fully open API, with Senses unlocked by bosses. This section sketches what it could be so that the main-mode engine is designed to host it later.

**Why it exists.** The main mode honors "no restrictions" completely, which makes the *creative ceiling* high but the *progression* mostly informational. A second mode takes the opposite stance: **limited scripting power is the design**, giving players who like RPG progression a game of building power over time. Constraints here are *the point of the mode* and are chosen by the player when they pick the mode, so they do not conflict with P2 in the main mode.

**Shared foundations (must be true in the first release so this mode is cheap later):**
- The script environment is built from a **capability set** per mode (`env` table that the engine fills), so a mode can expose fewer functions or wrap them.
- The §3.2 *instruction counter* is also usable as a **meter** (cost-per-callback) for budgets.
- `shoot`, Senses and `ctx` pass through an **API facade** that a mode can intercept (clamp counts, charge costs).

### Three possible shapes

| Shape | Core rule | Example | Pros | Cons |
|---|---|---|---|---|
| **S1. Budget** ("compute budget") | Every shot has a budget (e.g., instruction or "ops" meter, live-bullet allowance). Level-ups and gear raise it. Over budget → the callback halts for that frame. | Level 1: 200 ops/shot and 40 live bullets. Level 10: 2,000 ops and 400 bullets. | Reuses §3.2 instrumentation; rewards *efficient* code, a real programmer's challenge. | Players must understand ops; frustration when a script silently stops (needs great feedback). |
| **S2. Stat-driven RPG** | Character stats map to script limits: **Focus** = max bullets per shot, **Clock** = shots/second, **Reach** = bullet life/range, **Memory** = size of persistent `state`, **Insight** = Senses available. Points from levels, items and quests. | `Focus 6` → `shoot` ignores the 7th bullet of a call and says so. | Familiar RPG loop; easy to balance and to explain; many build choices. | Stats limit code in obvious ways; risks feeling arbitrary vs. the main mode's philosophy. |
| **S3. Unlockable API ("spellbook")** | Start with `shoot` and `ctx.aim` only. API functions, bullet hooks and Senses are unlocked via quests, loot, or boss drops. Each function has a **cost** drawn from a resource that regenerates. | Unlock `update` hook at Lv 3; `on_die` split at Lv 8; `sense.terrain` via a quest. | Strong sense of discovery and "growing a language"; teaches programming gradually. | Heavy content/authoring cost; needs tutoring-style design for new coders. |

**Recommendation: S3 as the spine with S2 stats as the tuning layer, and S1's meter as the implementation mechanism** (the budget is how costs are enforced, stats and unlocks decide the numbers). Do not build before the first release is playable (Q10, Q11).

### Likely systems (if S2/S3 are chosen)
Levels and XP from enemies; stats and gear; quests/NPCs or a *terminal* hub (this would add non-boss points of interest, so it interacts with Q7); a separate save and leaderboards; the same minimalist look and audio (§8).

---

## Biggest open design questions

Question IDs are stable. **Resolved on 2026-10-30:** Q1, Q2, Q3, Q4, Q8 (see the Decisions log at the top). Open questions below each have options and a recommendation; **[Karyu]** marks the ones that need the project owner's decision.

### Q5. Editing while the world is hostile (and the guard-rail numbers)
- **A. Time slows to ~15% while the editor is open** (recommended start).
- **B. Full pause** (safer, kills tension and the live-edit thrill).
- **C. Real-time, world keeps running** (maximum tension, hard on touch/laptops).
- **D. Setting:** let the player choose.
- **Recommendation: A as default, D as an accessibility setting.** On phones the editor is full-screen with the world at 15% in a preview (§10). The §3.2 guard values (4 ms, 5M instructions, 128 MB, 4,000 bullets) are starting values to benchmark on target devices.

### Q6. Boss "Habituation" mechanic: is it too punishing or exploitable?
- **A. Keep as specified** (§5.3), tune on playtests.
- **B. Soft version:** adaptation reduces damage only to the *dominant* pattern, floor ×0.6.
- **C. Drop it:** rely on armor, weak points, and phases.
- **Recommendation: A, prototyped behind a flag.** It's the most distinctive way to create tension *without* limiting code, but needs playtest to avoid feeling like "the boss punishes me for finding something that works".

### Q7. Where do bosses sit in the long-term open world?
- **A. Bosses stay the only POIs** (current brief) with escalating tiers.
- **B. Add POIs after the first release** (shops, ruins) that sell/teach Senses.
- **Recommendation: A for now**, designing the Fragment/Codex systems so B can be added later without redoing progression. Note: the planned Constrained mode (§11) may want hubs or NPCs; this question must be revisited when that mode is scoped.

### Q9. Boss rarity target (tuning of the decided hybrid spawn rule) **[Karyu]**
- **A. A boss beacon every ~2–4 minutes of straight travel** (current starting values: ≈0.75 bosses per 8×8 region).
- **B. Rarer: one per ~8–12 minutes of travel** (e.g., `p_first` base 0.25, `p_second` 0.05).
- **C. Tier-dependent:** common near the origin (new players find bosses quickly), rarer further out.
- **Recommendation: C**, starting from A near the origin and trending toward B beyond Tier 3. "Rarely" in the brief points to B at the far end; the first hour should still feel eventful.

### Q10. What shape is the planned Constrained mode (§11)? **[Karyu]**
- **A. S1 Budget:** compute/bullet budget raised by level.
- **B. S2 Stat-driven RPG:** stats cap bullets, rate, range, memory.
- **C. S3 Unlockable API (spellbook)** with a resource cost per function.
- **D. Hybrid (S3 spine + S2 stats, S1 meter as implementation).**
- **Recommendation: D.** It gives the strongest "growing a language" feeling and reuses the guard-rail instrumentation. Not needed for the first release; this only affects the architecture constraints listed in §11.

### Q11. How does the Constrained mode relate to the main mode?
- **A. Fully separate:** own save, own world, own enemies; scripts are not shared between modes.
- **B. Shared world generator and bestiary, separate save and progression;** scripts can be imported across modes, clamped by the mode's limits (with the editor showing exactly what was clamped).
- **C. One game, one save, a "challenge ruleset" toggle per world.**
- **Recommendation: B.** Keeps the open-source "shots are shareable" culture across both modes without mixing progression. Script `needs`/capability metadata (§3.2, §7) already carries what's required to check compatibility.

### Q12. Script provenance: when does an edited imported script become "mine"?
- **A. Never automatically; "Mark as mine" button with confirmation** (current text in §7.1).
- **B. After any edit,** it's treated as own.
- **C. Only if the diff exceeds a threshold or the player re-saves it under a new name.**
- **Recommendation: A.** B lets malicious code survive a trivial edit while gaining OS access; C is complicated for little gain.

### Q13. How do we ship a good script editor on touch and controller? **[Karyu]**
- **A. In-game touch/controller editor only** (symbol row, snippets, tunable sliders, token cursor, §10.1).
- **B. A + PC external editor hot reload** (watch `shots/`) as a first-release companion path.
- **C. B + phone↔PC/browser LAN/QR pairing** for live companion editing.
- **Recommendation: B in the first release, C later.** The in-game editor must work on every platform (P1), while the external-editor path is cheap and gives power users their real editor.

### Q14. Technical feasibility: Lua on Godot 4 for Web and mobile exports
- **A. A Lua GDExtension (e.g., `lua-gdextension`) if it exports to Web/Android/iOS** (needs verification).
- **B. A custom thin C/C++ Lua 5.4 binding built for all targets** (more work, fully in our control).
- **C. A pure-GDScript or pure-managed Lua interpreter** (portable but slow, may violate the bullet/budget targets).
- **Recommendation: spike A first (§9 step 2); fall back to B.** Do not commit to a platform promise until a Web and an Android export both run a 1,000-bullet script within the time budget. Also decide what `io` means on Web (absent vs. virtual file system backed by IndexedDB; recommendation: virtual FS limited to `shots/` and `data/`, with Export/Import).

### Q15. Cross-platform fairness and sync
- **A. Same rules everywhere; no aim assist; local saves; leaderboards per platform class** (PC/web vs. mobile because of the lower budgets).
- **B. Optional aim assist on touch/controller (off by default, clearly labeled), single global leaderboard flagged by device.**
- **C. B + cloud saves/cross-device sync.**
- **Recommendation: B for aim assist only if playtests show touch is unplayable without it; cloud sync is a later option.** Leaderboard handling must be decided before the per-boss boards in §4 are built. **[Karyu]** if you want one global leaderboard or per-platform ones.
