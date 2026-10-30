# Scriptshot — Design Pillars

> Status: **draft for review, revision 6 (owner decisions of 2026-10-30 folded in, incl. combat, writable player state, Constrained-mode shape and elites/rarity; QA & Build review items applied).** Spawning, elites and rarity tiers are specified in the companion doc [`spawning-and-rarity.md`](spawning-and-rarity.md); §6.5 summarises it. `main` contains only `README.md` and `LICENSE` (commits `e2ad1c3`, `e6f9c6a`). Other work is open in parallel: PR [#2](https://github.com/Karyu42/scriptshot/pull/2) (branch `feat/core-scaffold`, head `2026abe`: the Godot core with `ShotContext`, `ShotRequest`, `ShotPattern`, `BulletBehavior`, `BulletManager`, `BulletPool`, `HurtboxGrid`, `WallGrid`, `Hurtbox`, `Player`, `TrainingDummy`, tests and a benchmark) and PR [#3](https://github.com/Karyu42/scriptshot/pull/3) (branch `scripting/api-draft`: `docs/scripting/api.md` v0.1 and `docs/scripting/lua-binding.md`, **docs only, no Lua code yet**). When this doc names code it means those branches and uses their real names; nothing described here is on `main`, and anything not on those branches is a proposal. Every number is a **starting value to be playtested**, not a law. Resolved questions live in the **Decisions log** below; the questions still open are at the end of the doc (question IDs are stable, so Q1–Q4, Q8–Q13 and Q16–Q24 are resolved and absent from the open list; Q15 is narrowed to aim assist and sync).

Scriptshot is a top-down, minimalist, twin-stick shooter (Godot 4 + Lua, MIT) where **you write the shot**. Your Lua script *is* your weapon, and nothing in the language is taken away from you. It ships on PC (mouse + keyboard), controller, web and mobile. The world grows into an open world of regular enemies in which, rarely, a boss spawns instead. Bosses are the only points of interest.

---

## Decisions log (2026-10-30)

Decided by the project owner (Karyu), except the rows marked **decided (Chief of Staff, Karyu can override)**. Those rows (Q17–Q24) are calls the Chief of Staff made under Karyu's delegation: they are **working decisions the team builds on, distinct from Karyu's own decisions, and Karyu can still override any of them.** Everything else in this doc stays a proposal.

| ID | Decision | Where it lands |
|---|---|---|
| Q1 | **Main mode: fully open API, bosses unlock Senses (option B).** A **separate, planned game mode** with deliberately limited scripting power (budgets, unlockable API, stat-driven, possibly RPG-style) is added as a future mode, **not in the first release**. | §4, §11 |
| Q2 | **Maximum freedom.** The player's own scripts get **full Lua, including opt-in OS and file access**. The *only* engine-level guard rails are those that prevent crashes and hangs (instruction/time budgets, memory caps, error isolation, entity cap). OS and file access (and the other capabilities) are **opt-in per script and off by default for every script**, with a first-run prompt (§7.1). *Superseded in part on 2026-10-30 (3:26 PM, Karyu, see the row "No leaderboards, tags, clean-kill gating or in-game script sharing"):* the original "script sharing is in" and the import-specific warning were dropped. | §3.2, §7 |
| Q3 | **Boss spawn: hybrid** of deterministic region quotas plus a distance-based pity bump (former option C). Same seed = same bosses. | §6.3 |
| Q4 | **Death: respawn and keep everything** (former option A; Karyu). *Where* you respawn is refined by the "Death refinement" row (Chief of Staff). | §5.4 |
| Q8 | **All platforms: PC mouse + keyboard, controller, web and mobile.** | §10 (and design implications in §3.2, §8, §9) |
| Health 1A | **5 HP shown as pips.** Most hits deal 1, boss attacks deal 1–2. HP regenerates 1 per 3 s after 5 s without damage. | §5.4 |
| I-frames 2B | **0.75 s invulnerability after a hit** (the player blinks), plus a **dash that is invulnerable for 0.2 s on a 1.5 s cooldown**. | §5.4 |
| Friendly fire 3C | **Your own bullets never hurt you.** A **reflected bullet becomes enemy-owned**, switches to the enemy colour and **can hit you**. | §5.1, §5.4 |
| Death 4A | Respawn and keep everything (same as Q4 above; Karyu). Respawn place and delay: see the "Death refinement" row. | §5.4 |
| Death refinement | **Decided (Chief of Staff, Karyu can override), under Karyu's "respawn and keep everything": after 1.5 s you respawn at the last cleared boss arena, or at the origin if none has been cleared, keeping everything.** A living boss still resets to full HP. This matches PR #4 (merged): the `RespawnPoints` autoload (`register_arena_cleared(arena_position)`, `set_checkpoint(position)`, `get_respawn_position()`, `has_checkpoint()`, `get_arenas_cleared()`, `reset()`, signal `respawn_position_changed`) and `Main.respawn_delay` (default 1.5 s), which calls `Player.respawn(RespawnPoints.get_respawn_position())`. | §5.4 |
| Q9 (replaced) | **Owner direction: elite enemies and rarity tiers.** The "boss rarity target" question is replaced by **ELITE enemies** for early excitement and **rarity tiers (common / rare / legendary)** for both elites and bosses, each with distinct visuals, behaviours and rewards. Bosses stay common near the start and get rarer further out. Specified in [`spawning-and-rarity.md`](spawning-and-rarity.md); tuning questions are Q17–Q24 below. | §6.5, `spawning-and-rarity.md` |
| Q10 | **Constrained mode shape = D (hybrid):** S3 spellbook (unlockable API) as the spine, S2 RPG stats as the tuning layer, S1 meter as the implementation mechanism. **Not in the first release.** | §11 |
| Q11 | **Constrained mode relation = B:** **shared world generator and bestiary, separate saves and progression;** scripts stay usable across modes (a script file can be copied between the modes' `shots/` folders) and are **clamped to the receiving mode's limits** (the editor shows what was clamped). | §11, §7 |
| Q13 | **Editing on touch and controller = B:** the in-game editor works on every platform, plus **PC external-editor hot reload** (watch `shots/`) in the first release. **Phone pairing (LAN/QR companion editing) comes later.** | §10 |
| Q17 | **Decided (Chief of Staff, Karyu can override): both dials, as built.** Boss *frequency* falls with tier (beacon about every 117 s of straight walking in T1 to 310 s in T4+) and the *share of rare and legendary bosses* rises with tier. | §6.3, §6.5, `spawning-and-rarity.md` §4 |
| Q18 | **Decided (Chief of Staff, Karyu can override): keep the current legendary rates for the first playable** (about one legendary boss per 27 min of straight far-world walking) **and tune from playtests.** The odds stay a data table. | `spawning-and-rarity.md` §4.3, §9, §10 |
| Q19 | **Decided (Chief of Staff, Karyu can override): Shards are an additional route to Sense Level II, 25 Shards per token** (plus Level II from rare and legendary boss kills). Level I Senses, Fragments and tier access are never for sale. *With Karyu's 3:26 PM decision these, together with rare/legendary boss kills, are the only routes to Level II.* | `spawning-and-rarity.md` §7 |
| Q20 | **Decided (Chief of Staff, Karyu can override): elites never respawn.** Kills persist in the save as a per-chunk bitmask; regular enemies keep the 5-minute respawn rule. | `spawning-and-rarity.md` §6.5 |
| Q21 | **Decided (Chief of Staff, Karyu can override): the Herald is allowed as the one exception to seed purity.** A single time-based common elite 60–80 s after leaving the safe zone, saved as one flag. | §6.5, §7, `spawning-and-rarity.md` §3.6 |
| Q22 | **Decided (Chief of Staff, Karyu can override): rare and legendary bosses use the same 5-chunk sense radius** (beacon, hum) as common ones. A radius that grows with rarity stays a later tuning lever (re-simulate first). | §6.4, `spawning-and-rarity.md` §4 and §9 |
| Q23 | **Decided (Chief of Staff, Karyu can override): the first-playable affixes are Splitting, Summoner, Bulwark, Phasing and Null-shot.** Mirrored, Warded and Blinker stay specified and ship later. | `spawning-and-rarity.md` §3.4 |
| Q24 | **Decided (Chief of Staff, Karyu can override): option A.** Rarity cues use `_draw()` shapes, outline weights, one additive-blend halo and `AudioStreamGenerator` stings only (no Forward+/Mobile-only effect). **The cue check (additive halo plus `AudioStreamGenerator` stings on web and Android) is assigned to QA & Build once web and Android builds exist.** | §8.1, `spawning-and-rarity.md` §8.4, §10 |
| **Q15, Q16 (Karyu, 2026-10-30, 3:26 PM): No leaderboards, tags, clean-kill gating or in-game script sharing** | Karyu's words: *"its fine to drop the leaderboard and script sharing, that can be done outside of the game or added way later."* Consequences, all **Karyu's decision**, which **replaces the provisional Chief-of-Staff option A for Q16 and settles the leaderboard part of Q15**: (1) **no leaderboards**; (2) **no MOD tags and no modified/clean marks** (no per-fight flag, no Codex marks); (3) **no clean-kill gating of any reward**; (4) the **diegetic boss counters to cheat-like scripts stay**: Null attacks from Tier 2, plus the Equalizer, Rift and Eater bosses, and **no global Corruption**; (5) rewards that were clean-only get **non-tag routes**: Sense Level II from rare/legendary boss kills and Shards (25 per token), Seals and alternate Codex entries from a boss's counter phase or a rare variant, and the Echo rematch is kept only as an optional harder rematch (§12.4); **core progression is never gated**; (6) **verified fair play stays possible later in the Constrained mode** (§12.5); (7) **no in-game script sharing or import for now ("later, maybe")**: players share scripts outside the game, e.g. by copying files into `shots/`; **Q12 is closed as moot**, and the per-script `needs` opt-in with a first-run prompt now applies to **any** script that requests a capability (§7.1). The remaining half of Q15 (aim assist, cloud sync) stays open. | §3.2, §4, §7, §12, Q11, Q15 |
| **Player state is writable** | **Rejected: read-only player state.** Scripts **can change player state** (HP, invulnerability, position, speed, etc.) via the `player` table. Nothing in this doc treats player state as off limits. The design answer to "god mode is one line away" is §12 (the world fights back diegetically; rewards never depend on a tag), not a ban. | §3.1, §12 |

---

## 1. What makes it unique

1. **The weapon is a program, with no leash.** Other games let you tune a weapon; here you write it. Spirals, homing swarms, bullets that spawn bullets, bullets that read the world: if you can express it in Lua, it fires.
2. **Challenge lives in the world, not in the sandbox.** We never limit what you may write. We make the world push back: armor that punishes spam, shields that punish straight lines, bosses that punish repetition.
3. **Every enemy and boss is a question your script answers.** Encounters are small puzzles with many valid solutions, not DPS checks. A boss kill is an *idea* you had, tested live.
4. **Edit while the world is hostile.** The script editor is in-game, hot-reloads in under one frame, and keeps the fight going (slowed). Iteration happens under pressure and is the core thrill.
5. **Minimalism makes code legible.** With almost no art noise, you can *see* your script's geometry. The game looks like the math you wrote.
6. **Shots are shareable artifacts.** A shot is a small text file. People can trade, read, fork and remix them (it's open source, so the culture should be too). The game has no in-game sharing for now (§7): players share files outside it.

### Pillars (rules for every design decision)

| # | Pillar | Test: "does this feature…" |
|---|---|---|
| P1 | **Code is the weapon** | …make writing code more rewarding? If it replaces code with menus, cut it. |
| P2 | **No restrictions on the player, only pushback from the world** | …add a limit on what the player can write? If yes, reject. Express it as an enemy, a rule of physics, or a cost the world imposes instead. (Sole exception: the crash/hang guards in §3.2.) This includes your own player state: scripts may write HP, invulnerability, position and speed (§3.1); the world answers with diegetic counters (§12), never a ban or a mark. |
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
1. Spawn at world origin with a default script visible on-screen (`shots/default.lua`), firing a single bullet. A small **tutorial range** sits inside the 512 px safe zone (§6.1): three non-hostile targets built on `TrainingDummy` (`src/enemies/training_dummy.gd`, 40 HP, respawns), at about 300 px from the spawn.
2. Prompt: *"Press E to edit"* (controller: a face button; touch: an edit button). Time slows to 15% and a small editor opens beside the arena (on small touch screens it opens full-screen with the arena frozen at 15% in a corner preview; see §10). The default script has two commented lines to tweak (`count`, `spread`).
3. Edit → save → the shot changes **immediately, without leaving the world**.
4. One of the three targets is a **shielded dummy** (a front arc that *absorbs* straight shots, like the Shieldbearer, but static and non-hostile). It is a scripted tutorial placement, **not a spawn**, so it doesn't break Tier gating: real Shieldbearers only spawn from Tier 1 (§5.2). A curved shot (`turn_rate`) gets around the shield. Once the dummies die (or after 60 s) the player leaves the safe zone; the first *real* enemies are Tier 0: Drifters and Swarmers only, and **60–80 s after leaving the safe zone a first elite (the Herald, a Drifter with one affix) appears** (§6.5).
5. A **starter boss** is always placed at `D∞` 8.5 or 9.5 chunks from the origin (§6.3). Its beacon (an edge-of-screen tick, §6.4) becomes visible when the player is within 5 chunks of it (Euclidean), i.e. after walking roughly 3.5–4.5 chunks (about 24–31 s of straight walking at the player's 300 px/s). It is **not** visible at spawn. The player has found their first goal without a tutorial, typically 1–2 minutes after leaving the tutorial range.

---

## 3. Scripting model (proposed API shape)

### 3.1 Player-facing API

> There is no Lua integration in code yet: `main` has none, and the scaffold on PR #2 deliberately keeps Lua out of the core (`scripting/README.md` is a placeholder; the shot interface `ShotPattern`/`ShotEmitter` is the boundary a Lua binding plugs into). PR #3 evaluates bindings and recommends `gilzoide/lua-gdextension` (Lua 5.4) behind a thin `ScriptHost` facade, **pending a spike** (see Q14). This doc defines the **player-facing contract** only.

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
| Full Lua language and standard library (own scripts; `native`/`os`/`io`/`debug`/`package` are opt-in capabilities, see §3.2) | No design limits on loops, recursion, or state. Only the crash/hang guards of §3.2. |
| `shoot{angle, speed, damage, life, radius, color?, update?, on_hit?, on_die?}` | `on_die` may call `shoot` → bullets spawning bullets. |
| `ctx`: `aim`, `time`, `dt`, `shot_count`, `device` (`"kbm"`, `"pad"`, `"touch"`), plus `pos` (the **muzzle** position, `ShotContext.muzzle_position`), `vel` (`ShotContext.shooter_velocity`) and `hp` (snapshot of `player.hp`) | `device` lets a script adapt (e.g., wider autoaim cone on touch) without the engine granting any input-based advantage. For the player's own position use `player.pos` (below); `ctx.pos` is where bullets leave the barrel. |
| **`player` (live, readable AND writable; decided, see §12)**: `player.hp` (0..`max_hp`, default 5), `player.max_hp`, `player.invulnerable` (bool script flag), `player.iframes` (seconds of engine i-frames left), `player.pos`, `player.vel`, `player.speed` (default 300 px/s, `Player.max_speed` on the scaffold), `player.dash_cd` (seconds left), `player.regen_delay`/`player.regen_rate` (defaults 5 s / 1 per 3 s) | Writes apply at the end of the current callback. `player.hp = 0` kills the player (respawn rules, §5.4). |
| `player.dash(angle)` | The same action as the dash button (0.2 s i-frames, 1.5 s cooldown, §5.4); returns `false` while on cooldown. A script dashing is **not** a state write: it obeys the same rules as the button. |
| `on_hurt = function(ctx, dmg, src) return dmg end` (optional script callback) | Called before damage is applied; the return value replaces the damage (`0` = ignore). Returning less than `dmg` is an advantage write the world can answer (§12.1, §12.2). |
| `b.owner` on bullets (`"player"` / `"enemy"`) | Read-only; changes only through reflection (§5.1). |
| Persistent per-script `state` table | **Always available from the start** (not a Sense, not an unlock). Survives respawn (Q4: death keeps everything) and is saved in the save file. Not the same as `player` state. Corresponds to `weapon.state` / `run.state` in the scripting draft (its [OI-7], decided here: persistent). |

| Granted by Fragments (§4) | Examples |
|---|---|
| **Senses** (world information fed to code) | `sense.nearest_enemy`, `sense.enemies_in(r)`, `sense.enemy_bullets`, `sense.terrain`, `sense.boss` (phase, weak point), `sense.world` (seed, chunk coords) |

### 3.2 Script environment and the only engine guard rails

**Design intent.** Maximum freedom for the player's scripts, with **only** crash/hang guards as guard rails. The engine (through the `ScriptHost` facade proposed in PR #3's `docs/scripting/lua-binding.md`) runs **Lua 5.4** on every platform.

**Always available, no capability needed:** base Lua with **`load` in text mode only** (mode `"t"`; **binary chunks are never loadable**, because malformed bytecode can crash the VM, so this is a crash guard, not a gameplay limit), and **`dofile` and `loadfile` are available only with `io`, text mode only; binary chunks are refused everywhere** (`load`, `loadfile` and `dofile` use mode `'t'`, and `string.dump` does not exist; Scripting Engineer's call, PR #3 `api.md` *Capabilities*). **`require` works with no capability** for `.lua` modules in the script's **own folder subtree** (read-only, text-only, plain dotted names, no absolute paths or `..`; same sandbox and watchdog as the script; Scripting Engineer's call, PR #3). Also `string`, `table`, `math`, `utf8`, `coroutine`, `os.time`, `os.clock`, and the **full game API**, including writing player state (§3.1, §12). Note: `loadstring` is Lua 5.1/LuaJIT-only and does **not** exist in 5.4; use `load`.

**Capabilities (opt-in via `needs`).** Names, labels and library lists follow the Scripting Engineer's draft in PR #3 (`docs/scripting/api.md`, *Capabilities*), which owns them. Listed in order of danger, with the player-facing label:

| `needs` name | Covers | Player-facing label |
|---|---|---|
| `native` | `package.loadlib`, `package.cpath` and the **C searchers** of `require` (C modules, shared libraries). **The package C searchers are only enabled with `native`.** | "Load native code. Can do anything to your computer." |
| `os` | `os.execute`, **`io.popen`** (it runs programs, so it lives here and not under `io`), `os.remove`, `os.rename`, `os.getenv`, … (`os.time` and `os.clock` stay always-on) | "Run programs and change your system." |
| `io` | file read and write (`io.open`, `io.read`/`io.write`, `io.lines`, …), plus `dofile` and `loadfile` (**text mode only**); **not** `io.popen` (that is `os`) | "Read and write files." |
| `debug` | `debug.*` minus the guard-reaching functions (`sethook`/`gethook` are no-ops; `getregistry` and the upvalue/local functions are removed, see the watchdog note below) | "Inspect and change Lua internals." |
| `package` | `require` from **paths outside the script's own folder** (`package.path` changes, `package.loaded`, Lua searchers 1 and 2; own-folder `.lua` modules need no capability; **C searchers stay off unless `native` is also granted**) | "Load Lua modules from disk." |
| `net` | **reserved for later**, not available | n/a |

Engine rules for capabilities: **`os.exit` ends the script and never kills the game.** **The watchdog (instruction/time guard) is never a capability**: crash and hang guards are not on the list above on purpose, and a grant never lifts a guard in the table below.

**The watchdog and `debug` (decided by the Scripting Engineer; PR #3 `docs/scripting/lua-binding.md` §3 and `spike-results.md` §11).** Every callback runs in a **host-owned coroutine** with a **count hook (every 1,000 instructions, never line hooks) that checks the instruction budget, the wall clock, the memory estimate and the `os.exit` flag, and yields** to abort; a yield is not an error, so `pcall`, `xpcall` and error handlers cannot swallow it. **Scripts can't remove, replace or reach the guards, even with `debug` granted:** `debug.sethook`/`gethook` are no-ops, `getregistry` and the upvalue/local functions that could reach the guards are removed, the sandbox `coroutine` wrappers register every child thread, and the facade shows scripts only validated Callables. **This held up against the 47 adversarial cases of the Scripting Engineer's spike (0 hangs; spike-results §11).**

**What PR #3 still lists as a gap (stated plainly).** The count hook **does not fire during a long C call** (for example `string.rep`, a pathological pattern match, `table.sort`, `string.format` with huge widths), so **native calls are not interruptible**. PR #3 bounds the worst cases in the sandbox wrappers instead (a `string.rep` result ≤ 1 MiB and a pattern-matching subject ≤ 1,024 characters, worst case about 4 ms; its own allocator patch moves those limits into C), and the **64 MB memory cap is soft on the stock binding** (checked every 1,000 instructions; measured overshoot 64 to 83 MB) and hard only with that patch. With `native` granted none of these guarantees hold, which the label already says. A hang inside one C call can only be prevented, not interrupted.

`require` of own-folder modules is always on (Scripting Engineer's call, see above).

Platform availability: on **web** `native`, `os`, `io` and `package` are unavailable (§10); on mobile `native` is unavailable and `io`/`package` are limited to the app data folder.

```lua
return {
  needs = {"io"},            -- opt-in; listed in the first-run prompt and in the editor header
  on_fire = function(ctx)
    local f = io.open("shots/log.txt", "a"); f:write(ctx.time, "\n"); f:close()
    shoot{ angle = ctx.aim, speed = 480, damage = 10 }
  end,
}
```

**Who gets prompted.** **Any script that requests a capability** gets the same first-run prompt (§7.1), whether it was written in the editor or dropped into `shots/` from anywhere: the game cannot know where a file came from, so every script is treated the same. The prompt lists each requested capability with its label and a switch (default off). Grants are remembered **per script content hash**, so a changed script asks again. There is **no per-script profile field** for the Constrained mode; that mode clamps by **game mode**, not by script (§11).

**The sole engine-level guards (they exist to prevent crashes and hangs, never to shape gameplay):**

| Guard | Starting value | Behaviour |
|---|---|---|
| **Per-frame time budget** for all script callbacks | **3 ms on PC** (matches the scripting draft's default; 2 ms on web/mobile as a starting value, §10) | When exceeded, remaining script work for that frame is cut off as described in §3.3 (hooked bullets keep flying). A small `!` appears in the editor with the measured time. |
| **Instruction budget per callback** (watchdog against infinite loops, e.g., Lua count hook) | **100,000 VM instructions per callback invocation** (the scripting draft's default, set by the Scripting Engineer in PR #3) | The callback is aborted with an error (`script timeout`) and the game keeps running. 3 consecutive timeouts suspend that script until it is saved again. |
| **Memory cap** per script (separate Lua allocator accounting) | 64 MB on PC (the scripting draft's default), lower on web/mobile | Allocation beyond the cap raises a Lua error inside the script; the script is suspended and the editor shows the usage. |
| **Error isolation** | always on | Every callback (`on_fire`, `update`, `on_hit`, `on_die`) runs in a protected call. A Lua error never crashes the game; it prints to the editor console with file/line and disables only that callback until the next save. The previous working version can be restored with one key. |
| **Live-bullet cap** (keeps the pool/renderer alive) | **PC: 10,000 live bullets in total**, with a **5,000 floor** (see §3.3). Web and mobile have their own starting values in §10 | New `shoot` calls beyond the player's share are dropped and the editor shows "bullet cap reached". This is a performance ceiling, not a design limit. |
| **Cap auto-lowering** | PC: from 10,000 down to the 5,000 floor, never below | If the frame budget (16.6 ms) can't be held at the current cap on this device (p95 over budget for 2 s), the cap steps down (10,000 → 7,500 → 5,000); below 5,000 a "hardware below minimum" notice is shown. The editor displays the current cap. |
| **Bullet speed clamp** | **1,200 px/s** until swept collision is on `main` (§3.3) | `shoot{speed}` and speeds set from hooks are clamped; the editor says so ("speed clamped to 1200 px/s"). Prevents tunnelling through hurtboxes and walls. |
| **Bullet speed ceiling** | **4,000 px/s** once swept collision is on `main` (the clamp above lifts) | A crash guard for absurd values (`1e9`, `NaN`, `inf` are rejected or clamped); not a design limit. |

Everything else is *not* restricted: loops, recursion, coroutines, global state, bullet counts below the cap, `debug`/`os`/`io`/`package`/`native` (with opt-in), and writing player state. If a guard is hit, the player is told exactly which one and why (P2 stays honest).

**No provenance flag.** There is no "own" versus "imported" distinction: a script is a file in `shots/` (or one written in the in-game editor), and the capability rules of §3.2 and §7.1 apply to all of them. (Script sharing inside the game is out for now, §7.)

**Platform notes.** A script that declares `needs` the platform cannot satisfy still loads, but those libraries are `nil` and the editor says why. The `needs` list is part of the script file, so anyone opening it can see what it asks for.

### 3.3 Bullet budget, speed clamp, and what happens when budgets run out

**Bullet cap (B1).** The **PC cap is one number: 10,000 live bullets in total** (the target of the scaffold's benchmark, `tests/benchmark/bullet_benchmark.gd`; `BulletManager.capacity` defaults to 16384, so the logical cap sits below the pool size). **5,000 is the floor**: on hardware where the 10k benchmark can't hold the frame budget (16.6 ms). For context, the author's comment on PR #2 reports a **headless** run of `./tools/run_benchmark.sh` (28 walls, 32 hurtboxes, 10% fast bullets; median of 3 runs on a shared 8-core box under load) with **work p50 12.4 ms and p95 14.1 ms at 10,000 bullets** (13.4 / 14.1 / 18.7 ms across the three runs) and 6.9 / 9.0 ms at 5,000, and calls 10k "borderline on slower hardware". That figure is **not independently re-measured here, excludes real rendering (headless), and is only an indication, not a guarantee** for any target device the cap auto-lowers, but never below 5,000, and below 5,000 the game shows a "hardware below minimum" notice. Web and mobile caps are **separate starting values** (§10), not claims about the PC number.

**Reserved capacity for enemies and bosses (B2).** Player scripts can't starve the world's bullets:

| | Total cap | Reserved for enemy + boss bullets | Player scripts may use at most |
|---|---|---|---|
| Platform | Total cap | Reserved for enemy + boss bullets (30%) | Player scripts may use at most | Boss design budget (live bullets) | All regular enemies together |
|---|---|---|---|---|---|
| **PC** | 10,000 | **3,000** | **7,000** | **≤ 2,500** | **≤ 500** |
| **PC floor** | 5,000 | **1,500** | **3,500** | **≤ 1,250** | **≤ 250** |
| **Web** (starting values, §10) | 4,000 | **1,200** | **2,800** | **≤ 1,000** | **≤ 200** |
| **Mobile** (starting values, §10) | 2,500 | **750** | **1,750** | **≤ 625** | **≤ 125** |

The design budgets are the PC split (2,500 boss + 500 regular = 3,000 reserve) scaled proportionally to each platform's reserve (5/6 boss, 1/6 regular). Boss authors must be able to meet their patterns within the **smallest** boss budget (mobile, 625) by thinning density, not by changing the pattern's shape.

This reserve is a pool-protection rule in the same family as the cap (it keeps the world's bullets alive), not a gameplay limit on what scripts do. Rules: (1) player-owned bullets are hard-capped at the "at most" column; (2) enemy and boss bullets may use **the whole pool**, including unused player share (so a huge boss pattern is never cut by a player, and the player's own share shrinks instead if the pool fills); (3) the boss and regular-enemy design budgets in the table fit inside each platform's reserve; (4) engine work: per-owner live counters in `BulletPool` (see §5.5).

**Speed clamp (B3).** Until **swept collision** is on `main`, bullet speed is **clamped to 1,200 px/s** (about 20 px per 60 Hz tick, less than the 44 px diameter of a `TrainingDummy` hurtbox, so bullets can't tunnel). The clamp applies to `shoot{speed}` and to any velocity set from a hook. Swept collision is implemented on the scaffold PR #2 (`pool.prev_pos`, `HurtboxGrid.collide_bullets`, `WallGrid`; `docs/architecture.md`: "Collision is **swept**") but is **not on `main` yet**. **When PR #2 merges, the clamp lifts** (keep a sane engine ceiling, e.g. 4,000 px/s, as a crash guard) and the editor message about it is removed.

**When the time budget (3 ms PC) runs out (should-fix).** Hooked bullets (`behavior_id != 0`, i.e. a Lua `update`) are the expensive path; plain bullets cost no script time. When the budget runs out mid-frame:
- bullets whose `on_update` hook didn't run this tick **keep their last velocity and continue on native kinematics** (`acceleration`, `turn_rate`, lifetime, collision all still apply), they just skip the hook for this tick;
- those bullets draw with their **MultiMesh per-instance colour alpha** (the `RGBA` in the instance buffer written by `BulletRenderer.update_from`) multiplied by 0.7 for that frame (a **visible indicator**), and the editor shows `!` with the count ("412 hooks skipped");
- hooks are scheduled **round-robin** from where the previous frame stopped, so the same bullets aren't always the ones skipped;
- event hooks (`on_hit`, `on_despawn`) are **never silently dropped**: they are queued and run next tick (the scripting draft's rule: "deferred, never dropped silently"); this needs an event queue because the bullet slot is gone by then (engine work, §5.5);
- if over budget for 2 s, the editor shows a warning with the hottest script lines (no restriction is applied).

### 3.4 Lua API names vs. the scaffold and the scripting draft

The Lua names in this doc (`shoot`, `update`, `on_die`, `sense.*`, `player`) are **design placeholders**. The Scripting Engineer's draft (`docs/scripting/api.md` v0.1, PR #3 / `scripting/api-draft`) currently uses `spawn{}`, `on_tick`, `on_death`, `world.*` and `b:` handles; the final player-facing names are owned by that draft. This table maps each concept to the **real** Godot-side names on `feat/core-scaffold` so engineers know where each one lands:

| This doc | Scripting draft v0.1 | Godot side (real name) | Status |
|---|---|---|---|
| script table with `on_fire(ctx)` | weapon table, `on_fire(ctx)` | `ShotPattern.fire(context: ShotContext, emitter: ShotEmitter)` | exists |
| `cooldown` | `cooldown` | `ShotPattern.fire_interval` | exists |
| `ctx.aim` | `ctx.aim`, `ctx.aim_dir` | `ShotContext.aim_angle`, `ShotContext.aim_direction` | exists |
| `ctx.pos` (muzzle) | `ctx.pos` | `ShotContext.muzzle_position` | exists |
| `ctx.vel` | n/a | `ShotContext.shooter_velocity` | exists |
| `ctx.time` | `world.time` | `ShotContext.time` | exists |
| `ctx.shot_count` | `ctx.n` | `ShotContext.shot_index` | exists |
| `ctx.dt` | `world.dt` | none (fixed 60 Hz tick, `physics_ticks_per_second=60`) | constant, expose |
| `ctx.device` | n/a | `InputDevice` autoload (`src/core/input_device.gd`), not in `ShotContext` | new field |
| `ctx.hp`, `player.hp` | `world.player.hp` | none: `Player` emits `damaged(amount)` but has no health (architecture open question 6) | new (§5.4) |
| `player.pos`, `player.vel` | `world.player.pos/vel` | `Player` (`CharacterBody2D`) position/`velocity` | exists, writes need facade |
| `player.speed` | n/a | `Player.max_speed` (300.0) | exists |
| `player.invulnerable`, `iframes` | n/a | `Hurtbox.active` ("Turn off to make the owner temporarily untouchable (i-frames)") plus new timers | partly exists |
| `shoot{}` | `spawn{}` | `ShotEmitter.request_shot(ShotRequest)`, `request_shots()` | exists |
| `angle`, `speed` | `angle`, `speed` | `ShotRequest.polar(position, heading, speed)` → `ShotRequest.velocity` | exists |
| `damage` | `damage` | `ShotRequest.damage` (default 1.0) | exists |
| `life` | `lifetime` | `ShotRequest.lifetime` | exists |
| `radius` | `radius` | `ShotRequest.radius` | exists |
| `color` | `color` | `ShotRequest.color` | exists |
| `accel`, `turn` (native motion) | `accel`, `spin` | `ShotRequest.acceleration`, `ShotRequest.turn_rate` | exists |
| `pierce` | `pierce` | `ShotRequest.pierce` | exists |
| `bounce` | `bounce` | none: `WallGrid` despawns with `DespawnReason.WALL` | new (§5.5) |
| `collide_world` | n/a | `ShotRequest.collide_world` | exists |
| `team`/`b.owner` | `team`, `b.owner` | none: ownership is implied by `ShotRequest.hit_mask`; `Layers.PLAYER_BULLET`/`ENEMY_BULLET` are reserved | new (§5.5) |
| `update(b, dt)` | `on_tick(b, dt)` | `BulletBehavior.on_update(pool, index, delta)`, registered with `ShotEmitter.register_behavior()` → `ShotRequest.behavior_id` | exists |
| `on_hit(b, hit)` | `on_hit(b, hit)` | `BulletBehavior.on_hit(pool, index, hurtbox)` | exists |
| `on_die(b, why)` | `on_death(b, why)` | `BulletBehavior.on_despawn(pool, index, reason)` with `BulletPool.DespawnReason` (`LIFETIME`, `BOUNDS`, `HIT`, `MANUAL`, `CLEARED`, `WALL`) | exists |
| `on_spawn` | `on_spawn(b)` | `BulletBehavior.on_spawn(pool, index)` | exists |
| `b:kill()` | `b:kill(why)` | `BulletPool.mark_dead(index, reason)` | exists |
| `b.pos`, `b.vel` | `b.pos`, `b.vel` | `pool.pos[index]`, `pool.vel[index]` | exists |
| `sense.*` | `world.*` queries | none yet (`HurtboxGrid` is the spatial hash they would query) | new |
| `state` | `weapon.state`, `run.state` | none (Lua side, `ScriptHost`) | new |


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
Senses are tied to **boss types** (named, with a pool/tier), **not to a kill order**: in an open world the player can meet any boss first, so no Sense depends on "the Nth boss". Names are working titles. Scripts must therefore work when a Sense is missing (the field is `nil`).

| Power step | Sense | Unlocked by (boss, pool/tier) | What it enables |
|---|---|---|---|
| 0 | `ctx` and `player` (self), persistent `state` (always on) | Start | Fixed-pattern shots (spirals, fans, shotguns), learning scripts that remember across deaths |
| 0 | `sense.nearest_enemy` | **Free after first 3 kills** (teaches that senses exist) | Basic homing |
| 1 | `sense.enemies_in(r)` | **Warden** (pool A, Tier 0–1) | Area logic, triage targeting |
| 1 | `sense.enemy_bullets` | **Sower** (pool A, Tier 0–1) | Bullet-eating / deflect shots |
| 1 | `sense.terrain` | **Prism** (pool A, Tier 0–1) | Ricochet, wall-hugging bullets |
| 2 | `sense.boss` (phase, weak point, telegraphs) | **Lattice** (pool B, Tier 2–3) | Precision boss-killing scripts |
| 2 | none (Codex pages, Seal and Level II tokens only) | **Mantle** (pool B, Tier 2–3) | Rare and legendary Mantle kills give a Level II token (it has no Sense of its own); Seals and Codex entries (§12.4) |
| 3 | `sense.world` (seed, chunk coords) | **Archivist** (pool C, Tier 4+) | World-aware scripts, navigation |

The starter boss (§6.3) is whichever pool A boss the seed picks.

Every Sense has a **Level I** (earned on **any** boss kill) and a **Level II** (extended data). Level II comes from **rare or legendary boss kills of that Sense's boss type** and from **Shards** (25 Shards = one Level II token), never from a performance mark or a tag (§12.4, `spawning-and-rarity.md` §7). Example: `sense.enemies_in(r)` Level I returns positions within 600 px; Level II returns positions, velocities and HP within any radius.

Each boss type has a *Fragment* it drops once per save; Fragment order is not enforced (open world), so power is gated by **distance/Tier** (§6), never by kill order or count. The counter mechanics of §12.2 (Equalizer, Rift, Eater, and the Null attacks every boss from Tier 2 carries) are assigned to launch bosses by the boss designer; they are mechanics, not extra bosses.

Elites and rare/legendary bosses add **extra routes to Level II** (Shards, and Level II from rare or legendary boss kills) without touching Level I or the Fragment rule; see `spawning-and-rarity.md` §7.

### Discoverability (P4)
- **Codex pages** drop with Fragments: a 10-line annotated Lua example, never more than one screen.
- **Hints in the world**: enemies visibly telegraph their rules (a shield arc is drawn; an armored tank has a thick outline).
- **Editor affordances**: autocomplete lists *locked* Senses greyed with "found at: ???" so players know there's more to find.
- **Failure teaches**: when an armored enemy shrugs off your hit, a damage number reads `0` and the armor value flashes.

### Why keep exploring
1. Bosses are the only POIs, and each boss type carries a unique Fragment: *no boss, no new Sense*.
2. Further from origin = tougher tiers = need for better scripts = need for new Senses.
3. Boss encounters are **puzzles with several solutions**; solving one in a way you didn't expect is its own reward (Codex "alternate solution" entries record the notable ones, §12.4).
4. **Rare and legendary variants, elites and Shards** (`spawning-and-rarity.md`) give long-term goals and a reason to go back out: Level II tokens, Seals, trophies and Codex entries. Players trade and compare scripts outside the game, which the open `shots/` folder makes easy (§7).

---

## 5. Challenge with unrestricted scripting

**Principle:** if a player can write a script that trivializes content, that is acceptable *only after* they discovered the idea, and the world should always have a next layer that makes them rethink. Challenge comes from enemy behavior and world physics; **never** from banning APIs. **One deliberate exception to "discovered the idea":** god mode (`player.invulnerable = true`) is one line away from minute one, by decision. We neither hide nor ban it; §12 explains why the game stays meaningful anyway.

### 5.1 Regular enemy archetypes (starting values; HP is at Tier 0)

| Enemy | HP | Move | Rule | What it pressures in your script |
|---|---|---|---|---|
| **Drifter** | 30 | 90 px/s toward player | none | Baseline: any shot works |
| **Swarmer** (groups of 8–14) | 6 | 140 px/s, erratic | dies to anything; surrounds | Area coverage, spread |
| **Shieldbearer** | 60 | 70 px/s | 120° front arc **absorbs** bullets (bullet consumed, no damage, no reflection; visible arc) | Angles, curved or looping bullets, flanking |
| **Tank** | 400 | 50 px/s | **Armor 5**: each hit's damage is reduced by 5 (min 0) | Bullet damage per hit. 3-damage spam does **0**; big/slow bullets win |
| **Sniper** | 20 | stationary, 600 px range | Draws a 0.8 s telegraph line, then fires one 600 px/s bullet for **1 damage** (1 of the player's 5 HP, §5.4) | Movement, bullet range |
| **Phaser** | 80 | 100 px/s | Invulnerable except a 0.4 s pulse every 2.0 s | Timing, `sense.enemies_in`, burst scripts |
| **Mirror** | 50 | 80 px/s | Front arc **reflects** bullets (120° arc, same geometry as the Shieldbearer's). A reflected bullet **becomes enemy-owned** (see §5.4, friendly-fire rule) | Indirect shots, bullets that hit from the side |

**Hit response, one per enemy type (no mixing):** *absorb* = bullet is consumed with no damage and no effect; *reflect* = bullet changes owner and flies back (§5.4); *armor* = bullet hits normally, damage is reduced.

| Enemy | Response when a bullet hits the shielded/protected part |
|---|---|
| Shieldbearer (front arc) | **Absorb** |
| Mirror (front arc) | **Reflect** |
| Phaser (outside its 0.4 s pulse) | **Absorb** (the whole body) |
| Tank | **Armor** (no shield) |
| Boss, non-weak-point body parts | **Armor-like**: hit normally at ×0.1 damage (§5.3); a boss may also have a named *reflect phase* (reflect, for that phase only) |
| Drifter, Swarmer, Sniper | none: hit normally |

Armor is the key anti-spam rule: it makes damage **per bullet** matter, so one cannot win by multiplying trivial bullets, yet it doesn't cap bullet count.

### 5.2 Tier scaling
Tier `T = floor(max(|x|, |y|) / 16384)` with `x, y` in px (that is `D∞` from the origin divided by **8 chunks**; square tiers, §6.1), so the guaranteed starter boss at `D∞` 8.5–9.5 chunks sits in Tier 1. (Tiers were 6 chunks wide in earlier revisions; they are now as wide as a region so that region ring = tier, see `spawning-and-rarity.md` §2.) Per tier: HP ×(1 + 0.35·T), enemy count per encounter ×(1 + 0.15·T), **Tier 0 spawns only Drifters and Swarmers**; new archetype pool opens at T1 (Shieldbearer, Sniper), T2 (Tank, Phaser), T3 (Mirror), and **combinations** appear from T2 (e.g., Shieldbearers escorting a Sniper). **Elites** (a base archetype plus 1–2 affixes, in three rarities) join the mix from T0; the rules are in §6.5 and `spawning-and-rarity.md`.

### 5.3 Bosses (rules that matter for scripting)
- **Phases (3–4)** keyed to HP thresholds; each changes the attack set and the weak point.
- **Weak point**: only a specific part (e.g., rotating core) takes full damage; the rest takes ×0.1. Requires aiming or `sense.boss`.
- **Adaptation ("Habituation")**: the boss tracks the *pattern signature* of your recent bullets (angles bucketed into 24 × 15° sectors, speeds into 4 bands). If one signature makes up >70% of hits over 10 s, damage taken falls 10% per 5 s (floor ×0.4), recovering at 20%/5 s when you change patterns. Result: **players are pushed to edit scripts mid-fight**, the core unique thrill, without any restriction on code. Randomness spreads the signature, which is a legitimate counter-strategy (balanced by Armor and weak points).
- **Hazards authored as bullets** so the player's own sensing scripts (`sense.enemy_bullets`) can read and counter them.
- **Telegraphs**: every dangerous attack shows a ≥0.5 s warning in the boss's color (P3).
- **Counter phase and Null attacks** (from Tier 2): every boss has a phase with 1–2 **Null attacks** that pierce the `player.invulnerable` flag and overheal (white-violet, ≥0.8 s telegraph, engine i-frames still protect, §12.2). Beating that phase unlocks the boss's Seal and an alternate-solution Codex entry (§12.4); it is never required for the Fragment or Level I.

### 5.4 Player combat spec (decided 2026-10-30: Health 1A, I-frames 2B, Friendly fire 3C, Death 4A)

**Health (1A).**
- **5 HP, drawn as 5 pips** in a small ring orbiting the player at 20 px radius (no HUD bar, P3). Full pip = white filled circle, empty = hollow outline. HP above max (script-written *overheal*, §12) is drawn as extra pips in the violet accent colour.
- **Damage:** contact with a regular enemy = **1**; regular enemy bullet = **1**; Sniper shot = **1** (telegraphed, long range); **boss attacks = 1–2** (2 only for attacks with a ≥0.8 s telegraph and a distinct big visual, mostly in boss phases 3–4). Nothing regular deals more than 1, so 5 hits is a stable "lifebar".
- **Regeneration:** **+1 HP every 3 s after 5 s without taking damage.** Taking damage resets the 5 s timer. From 1 HP to full that is 5 s + 12 s = 17 s of safety. Boss fights are mostly decided *without* regen, so it works as between-encounter recovery.

**I-frames (2B).**
- **Hit i-frames:** **0.75 s** of invulnerability after any hit. The player **blinks**: `Player` is drawn with `_draw()` (not a sprite), so the blink alternates the alpha of its draw colour (`modulate.a`) between 100% and 30% every 62 ms. Bullets pass through; contact damage is suppressed.
- **Dash:** one button (kbm: Space; pad: a face button/right shoulder; touch: a dash button + double-tap-to-dash on the move stick). Moves **160 px in 0.2 s** (800 px/s) in the move direction (or aim direction if idle) and is **invulnerable for the full 0.2 s**; **cooldown 1.5 s**, shown as a small arc around the player that fills. The dash can pass through bullets and enemies but not terrain. Firing during a dash is allowed.
- Hit i-frames and dash i-frames **don't stack**; the longer one applies. They are *engine i-frames* (distinct from the script flag `player.invulnerable`, §12.3).

**Friendly fire (3C).**
- **Your own bullets never hurt you**, including after bouncing off terrain, in all cases (no self-damage on any platform or mode).
- A bullet **reflected** by a Mirror, a boss reflect phase, or any "reflect" rule **changes owner** `player → enemy`: it **switches to the enemy bullet colour (`#FF5A4D`)**, keeps its position/speed (angle reversed or as the reflecting rule says) and **can hit the player for 1 damage** (its script `damage` value is ignored when hitting you). It can no longer hurt enemies, no longer calls the script's `update`/`on_hit`/`on_die` (the script no longer owns it), and **can't be reflected again** (max one reflection per bullet, which prevents ping-pong).
- Reflection is therefore a *world rule that punishes dense straight scripts*, not a restriction on writing them.

**Death (4A, same as Q4; respawn place is a Chief of Staff refinement, Karyu can override).** On death (HP 0, including `player.hp = 0`) the player waits **1.5 s** (`Main.respawn_delay`, PR #4) and respawns **at the last cleared boss arena, or at the origin if no arena has been cleared yet**, and **keeps everything** (Fragments, Codex, scripts, `state`, the world; HP resets to max, i-frames and dash cooldown clear, as in PR #4). In code (PR #4, merged to `main`): boss code calls `RespawnPoints.register_arena_cleared(arena_position)` when its arena is won (the *last* cleared arena wins), `Main` asks `RespawnPoints.get_respawn_position()` (origin `Vector2.ZERO` while `has_checkpoint()` is false), and anything else that wants a save point can call `set_checkpoint(position)`. `RespawnPoints` stores only a position, so **saving it in the save file is part of the save format** (not yet specified). **A living boss still resets to full HP** and its chunk reloads. The cost of dying is time (the walk back from the arena, shorter the further you have progressed) and the boss fight in progress. No XP loss, no drop. Stakes come from difficulty, not from loss. *Note:* a cleared boss chunk becomes ordinary (§6.3), so regular enemies can spawn at the respawn point; if playtests show spawn-camping, give arenas a small safe radius like the origin's (not decided).

### 5.5 Engine work needed for these combat rules

What the scaffold on `feat/core-scaffold` already has versus what the rules above need (the Gameplay Engineer owns these; this is the list, not a schedule):

| Rule | In the scaffold today | Needed |
|---|---|---|
| **Shields (absorb)** | `Hurtbox` is a circle (`radius`, `layer`, `active`); `HurtboxGrid` tests swept segments against circles; `Hurtbox.hit(damage, hit_position, bullet_velocity)` signal | A hit-response per `Hurtbox` (`HIT` / `ABSORB` / `REFLECT`) with a facing and arc, evaluated at the contact point by `BulletManager`; a new `BulletPool.DespawnReason` (e.g., `ABSORBED`) |
| **Reflect + bullet owner** | Faction is implied by `ShotRequest.hit_mask` (`Layers.ENEMY` / `Layers.PLAYER`); `Layers.PLAYER_BULLET` and `ENEMY_BULLET` are reserved but unused | An explicit **owner** array in `BulletPool` (player / enemy), a `reflected` flag (max one reflection), reflection that rewrites `vel`, `hit_mask`, `color` and clears `behavior` (so Lua hooks stop, §5.4), and `b.owner` exposed read-only |
| **Weak points** | Multiple `Hurtbox` children per enemy are possible (each a circle) | A damage multiplier per `Hurtbox` and a **priority rule** when hurtboxes overlap (weak point wins over body), plus `sense.boss` data |
| **Bounces** | `WallGrid` clips bullets to the wall and despawns them with `DespawnReason.WALL`; "the grid only reports hit fractions" (no normal) | Hit **normal** from `WallGrid`, a `bounce` count in `ShotRequest`/`BulletPool`, reflection of `vel` about the normal; `collide_world = false` stays as is |
| **Armor** | `Hurtbox.hit` carries `damage`; an enemy script can subtract (as `TrainingDummy` handles damage) | none in the engine (enemy-side rule) |
| **Player health, i-frames, dash** | **PR #4 (merged to `main`)** adds `Health` (regen, hit i-frames), `dash`, death with respawn (`Main.respawn_delay`, `RespawnPoints`) and `PlayerState`; the pip HUD and blink drawing are the remaining art-side work (check against `main`) | Pips and blink drawing |
| **Per-owner bullet counters** | `BulletPool.count`, `dropped_total` | Live counters per owner and the reserve rules of §3.3 |
| **Budget-aware hooks** | `BulletPool.hooked` / `hooked_count` list hooked bullets | Hook scheduler with round-robin, the "skipped" flag for rendering, and an event queue for deferred `on_hit`/`on_despawn` (§3.3) |
| **Open-world bounds** | `BulletManager.world_bounds` defaults to a fixed `Rect2(-1312, -752, 2624, 1504)`; `HurtboxGrid` and `WallGrid` are constructed from it | See §6.1: follow the camera |

---

## 6. Open world and rare bosses

### 6.1 World structure
- **Infinite, chunked, seeded.** Chunk size **2048×2048 px**. Active ring: 3×3 chunks around the player; others are unloaded and regenerated deterministically from `(world_seed, chunk_x, chunk_y)`.
- **Same seed = same world** (so seeds can be shared; see §7).
- **No landmarks other than bosses** in this version: terrain is empty ground with sparse, minimal obstacles (a few static blocks per chunk, needed for later `sense.terrain`).
- **Coordinates, regions and distance (the definitions every rule below uses).**
  - World position is `(x, y)` in px, y down (Godot). **Chunk** `(cx, cy) = (floor(x/2048), floor(y/2048))` covers `[2048·cx, 2048·(cx+1)) × [2048·cy, 2048·(cy+1))`. In **chunk units** (px ÷ 2048) a chunk's centre is `(cx+0.5, cy+0.5)`. The world origin `(0,0)` px is the **corner** shared by chunks `(−1,−1)`, `(0,−1)`, `(−1,0)` and `(0,0)`.
  - **Region** `(rx, ry)` = the 8×8 chunks with `cx ∈ [8·rx−4, 8·rx+3]` and `cy ∈ [8·ry−4, 8·ry+3]`. Regions are **centred on the world origin**: region `(0,0)` has the origin at its centre, and its **centre is the chunk corner `(8·rx, 8·ry)` in chunk units** (px `(16384·rx, 16384·ry)`). A chunk belongs to region `(floor((cx+4)/8), floor((cy+4)/8))`. A region's **tier is its ring** `k = max(|rx|, |ry|)` (the region centre is at `D∞` = 8k chunks), while chunk-level rules use the chunk's own tier. (Earlier revisions used corner-aligned regions; they made regions straddle tier boundaries and the world asymmetric.)
  - **Two named metrics, used consistently.** **`D∞` (Chebyshev)** = `max(|Δx|, |Δy|)` between two points in chunk units (chunk centres, or the region centre, or the origin). **All world-generation rules use `D∞`**: Tier, region ring order, the pity distance `d`, the "≥ 6 chunks apart" and "≥ 4 chunks from origin" boss rules, and the starter-boss radius. **Euclidean distance in px** is used **only** for what the player senses or physics does: beacon and hum ranges (§6.4), enemy wake-up distance (700 px), and bullet range.
- Origin is a safe zone: radius 512 px (Euclidean), **no spawns** (regular or boss). The only things inside it are the non-hostile **tutorial targets** of §2, which are scripted placements, not spawns.
- **Units.** The project's base viewport is **1280×720** (`project.godot`: `window/size/viewport_width=1280`, `viewport_height=720`, stretch `canvas_items`, aspect `keep`). **1 world unit = 1 px** at that base resolution, and every px value in this doc is in those units; other screens scale the whole view uniformly (letterboxed), so the visible world is always 1280×720 units. (This replaces the earlier "1080p" wording.)
- **Player speed.** `Player.max_speed` = **300 px/s** (acceleration 2400 px/s², full speed in 0.125 s, friction 2000 px/s², from `MovementMath` and `docs/architecture.md`). Crossing one 2048 px chunk takes about **6.8 s**.
- **Simulation window follows the camera.** The scaffold's `BulletManager.world_bounds` is a fixed `Rect2(-1312, -752, 2624, 1504)` (about 2× the viewport), and `HurtboxGrid`/`WallGrid` are built from that rectangle (`HurtboxGrid.new(world_bounds, cell_size)`, `cell_size` 64). In the open world that rectangle must **re-centre on the camera** (rebase the grids as the player crosses cell boundaries, stream walls in and out per chunk with `BulletManager.add_wall(Rect2)` / `clear_walls()`), and bullets that leave it despawn with `DespawnReason.BOUNDS`. Design consequence: a bullet's usable range is about ±1,300 px horizontally and ±750 px vertically from the camera; scripts with `life × speed` beyond that simply expire at the edge (documented in the editor).

### 6.2 Regular spawn rule
When a chunk is first loaded, roll an **encounter budget** `B = 6 + 4·T` points. Spend points on archetypes allowed by tier: Drifter 1, Swarmer group 3, Shieldbearer 3, Sniper 3, Tank 5, Phaser 4, Mirror 4. The budget is split into **2 encounters per chunk in T0–T1 and 3 from T2**, and each encounter can be an **elite** (§6.5). Enemies start idle (wander) until the player is within 700 px. Cleared chunks respawn after 5 min of being out of the active ring (so the world feels alive but not farmed forever).

### 6.3 Boss spawn rule ("a boss spawns *instead*") — decided hybrid (Q3)

**Goal:** bosses are rare, paced so players are never boss-starved for long, and **the same seed always gives the same boss layout** regardless of the order the player explores. All distances are `D∞` in chunk units and all regions/chunks are as defined in §6.1.

- **A boss is placed on a chunk.** A boss chunk gets **no regular enemies** (the boss spawns *instead*) and is not rolled again.
- **Starter boss (placed first).** One boss chunk is picked by `hash(seed, "starter")` among the chunks whose centre has `D∞` from the world origin of **8.5 or 9.5** (px `D∞` 17,408–19,456, i.e. **Tier 1**). It is always a *common* boss. It is registered as a placed boss before any region is decided and it belongs to whichever region it falls in.
- **Canonical order.** Regions are decided in a fixed order that depends only on the seed: **ring `k = max(|rx|, |ry|)`** ascending from 0, and **inside a ring ascending `(ry, rx)`**. A region's decision may depend on earlier regions in this order, **never on where the player has walked**, so worlds stay reproducible. (Ring *k* has 8k regions (1 for k = 0), so evaluating up to the player's ring is cheap and cacheable.)
- **Per-region quota with distance pity.** For region `R`, let `d` = `D∞` from `R`'s centre to the nearest boss chunk already placed (including the starter), **capped at 80**:

```
d        = min( D∞(centre(R), nearest placed boss chunk), 80 )
p_first  = BASE_FIRST[T] + 0.05 * floor(d / 10)   # pity bump: +5 % per 10 chunks without a boss nearby (max +0.40)
p_second = BASE_SECOND[T]                          # independent roll, can add a second boss
# T = the region's tier (its ring). BASE_FIRST  = 0.30 / 0.25 / 0.18 / 0.12 / 0.08 for T0 / T1 / T2 / T3 / T4+
#                                    BASE_SECOND = 0.08 / 0.06 / 0.04 / 0.03 / 0.02
u1 = hash(seed, R, "boss1"),  u2 = hash(seed, R, "boss2")
boss count = (u1 < p_first ? 1 : 0) + (u2 < p_second ? 1 : 0)
for each boss i: pick a chunk of R by hash(seed, R, i, attempt), attempt = 0..9, accepting the first that is
             >= 6 (D∞) from every placed boss chunk and >= 4 (D∞) from the origin;
             if none of the 10 attempts is valid, that boss is skipped
```
  (An earlier draft wrote `min(…, 0.80)` and then a flat base of 0.15; with `d` capped at 80 the pity part alone adds at most 0.40, so no further cap is needed. The base now depends on the tier: **bosses are more frequent near the origin and rarer further out**, decided direction of 2026-10-30; table and rationale in `spawning-and-rarity.md` §4.)
- **Expected density (starting values), measured by simulation** (40 seeds, 34 rings; `docs/design/sim/rarity_sim.py`): area per boss **≈ 171 chunks² in T1, 326 in T2, 405 in T3, 454 in T4+** (and ≈ 301 in the small T0), so boss frequency falls outward as intended.
- **Boss chunk persists** until the boss is killed; after that that boss never respawns in this save (the Fragment is already earned) and the chunk becomes ordinary.
- **Boss types** are selected by tier: T0–1 boss pool A (3 bosses), T2–3 pool B (2), T4+ pool C (1), a launch target of **6 distinct handcrafted bosses**, with procedurally varied colors/parameters. Bosses are **identified by name and pool/tier, not by number** (Fragments can be gathered in any order); working titles are in §4.

**Beacon cadence arithmetic.** The beacon is the edge-of-screen tick of §6.4: visible when the boss is within **5 chunks Euclidean (10,240 px)**.
1. A straight walk therefore sweeps a strip **2 × 5 = 10 chunks wide**.
2. Area walked per boss met = area per boss (chunks²); **chunks walked per new beacon = area per boss ÷ 10**.
3. Walk speed `Player.max_speed` = 300 px/s ⇒ one chunk (2,048 px) = **6.83 s**.

| Tier | Area per boss (simulated) | Chunks per new beacon | Time per new beacon, straight walk |
|---|---|---|---|
| T1 | 171 chunks² | 17.1 | ≈ **117 s** |
| T2 | 326 | 32.6 | ≈ **223 s** |
| T3 | 405 | 40.5 | ≈ **277 s** |
| T4+ | 454 | 45.4 | ≈ **310 s (5.2 min)** |

Fighting and wandering lengthen these (see the simulation in `spawning-and-rarity.md` §9: first boss sighted at a median of 52 s and a mean of 131 s straight; 73 s median wandering). The previous single-rate values (≈195 s everywhere for the old option A, ≈359 s for option B of Q9) are superseded.
4. **Starter boss:** `D∞` ≥ 8.5 chunks from spawn, beacon visible within 5 chunks (Euclidean) ⇒ it is **never visible at spawn** and appears after walking at least about 3.5 chunks (≈ 24 s) toward it, typically 25–35 s of walking; with the tutorial range first, about 1–2 minutes after the first edit.

### 6.4 Finding bosses without markers (P3, P4)
There is no map icon. Boss presence is **sensed**:
- A low-frequency audio hum that rises with proximity (audible within 3 chunks, Euclidean).
- A faint, slowly rotating **edge-of-screen tick mark** in the boss's color that points toward the nearest undefeated boss within **5 chunks Euclidean** (10,240 px; the same for the starter boss, so a beacon never shows at spawn).
- The ground grid **bends subtly** near a boss chunk (a post-process warp, ≤3 px displacement).

### 6.5 Elites and rarity (summary; full spec in [`spawning-and-rarity.md`](spawning-and-rarity.md))
Owner direction of 2026-10-30: **elite enemies** for early excitement and **rarity tiers (common / rare / legendary)** for both elites and bosses, each with distinct visuals, behaviours and rewards.
- **Elites:** a regular archetype plus **1–2 affixes** (Bulwark, Mirrored, Phasing, Warded, Splitting, Summoner, Blinker, Null-shot). Each affix is a world rule that counters one lazy script habit and never limits what can be written (P2). Per encounter, P(elite) = 4–6 % by tier; **rare elites from T1, legendary from T2**; a time-based **Herald** guarantees the **first elite 60–80 s after leaving the safe zone** (median 64 s in simulation).
- **Boss frequency falls with tier, boss rarity rises:** beacon cadence ≈ 117 s (T1) → 310 s (T4+) of straight walking; rare and legendary shares of bosses ≈ 14 % / 0 % in T1, 33 % / 2 % in T2, 44 % / 16 % in T3, 46 % / 22 % in T4+. A **rare** boss adds a variant twist and ×1.2 HP; a **legendary** boss adds that twist plus **Phase ★**, an extra phase with a unique mechanic (×1.3 HP), several of which counter cheat-like scripts (Null ring, Equalizer, Rift).
- **Deterministic:** boss rarity comes from the region hash plus an **ordinal pity counter** (≥ 1 rare+ in any 6 bosses from T2, ≥ 1 legendary in any 12 from T3); elite pity is per region. Same seed, same world.
- **Rewards:** Shards (25 = one Sense Level II token), Codex pages and cosmetic trophies; the first kill of a boss type at any rarity gives its Fragment. Rewards depend on **what was killed only**. Rare and legendary boss kills also grant Level II of that boss's Sense.
- **Visual language:** shape first (one ring, double ring with ticks, crowned ring), outline weight (3 / 4 / 5 px), a cyan or amber accent and a short audio sting; every cue is `_draw()`-based with GL Compatibility fallbacks.

---

## 7. Sharing and community, and the capability prompt (decided Q2, amended 2026-10-30)

**Decided (Karyu, 2026-10-30, 3:26 PM): no in-game script sharing or import for now.** The game has no share codes, no import or download flow and no `shots/imported/` folder. Players share scripts **outside the game**: a shot is a plain `.lua` file, so they copy it into `shots/` (on web and mobile, via the Export/Import button or the app's folder, §10). That keeps the project's open-source culture without an in-game trust system.
- **Later, maybe (future note, not planned work):** an in-game share code (a compressed, base64 copy of one script plus metadata such as name, author, Senses used, `needs`) or an in-repo `community-shots/` folder via PRs. If it ever comes back, it reuses the capability prompt of §7.1 unchanged and adds a "this script was made by someone else" line, nothing more.
- **Seed sharing** stays: the same seed gives the same chunk, boss and elite layout, including each boss's and elite's rarity (§6.3, §6.5; decided). The only exception is the one-off Herald elite of the first minutes, which depends on when and where the player leaves the safe zone.
- **Across game modes** (§11, decided Q11 = B): a script file can be used in the Constrained mode as well as in the main mode; the receiving mode **clamps it to its own limits**, and the editor shows exactly what was clamped. The clamp is by game mode, not by a per-script field.

### 7.1 The capability prompt (any script that requests a capability)
A script is a program, and a file in `shots/` can come from anywhere, so **every script is treated the same**. The prompt is about the **capabilities a script asks for** (`needs`, §3.2), not about where it came from. Capability names and labels are the Scripting Engineer's, from PR #3 (§3.2).

1. **First-run prompt**, shown the first time a script whose `needs` includes `os`, `io`, `debug`, `package` or `native` is about to run, and again when an edit adds a capability (item 4). Plain language, e.g.: *"This script asks for extra powers. Scripts are programs and can do anything the powers below allow. Only turn on what you trust."* It has a **View source** button and a **Run** button, and **no "allow all" on first run**. (`net` is reserved and not offered.)
2. **Each requested capability has its own switch, all OFF by default, ordered by danger** (most dangerous first), each with its label from §3.2: `native` ("Load native code. Can do anything to your computer."), `os` ("Run programs and change your system."), `io` ("Read and write files."), `debug` ("Inspect and change Lua internals."), `package` ("Load Lua modules from disk."). The player turns on only what they accept; **Run** works with all switches off (the capabilities then are `nil` and the script may error).
3. **Source view is one click away** and syntax-highlighted; the `needs` list and a content hash are shown at the top.
4. **Grants (decided by the Scripting Engineer, PR #3 `api.md` *Grants*):** they are **keyed by content hash**. **Edits made in the in-game editor carry the existing grant forward.** A **save from an external editor** (PC hot reload, §10) changes the hash, so the prompt appears once and offers **"Trust this file while I edit it"**: a **per-session trust for that file path, cleared on restart**, after which saves of that path reload without prompting. **An edit that adds a capability to `needs` always prompts again, for just the new capability** (existing grants stay). Hot reload re-checks grants before swapping in the new code; the old version keeps running until the player answers. Everything else (the full game API including player-state writes, base Lua, `string`, `table`, `math`, `utf8`, `coroutine`, `load`, `os.time`, `os.clock`, own-folder `require`) runs normally, and the §3.2 crash/hang guards apply to all scripts. A script that writes player state is not blocked or marked; the world answers in the fight (§12).
5. **A script that requests no capability** never sees a prompt (own-folder `require` never prompts either).
6. **Platform:** switches for capabilities the platform doesn't provide (web: `native`, `os`, `io`, `package`) are shown disabled with the reason.

> **Honest limit:** this is a prompt and a default, not a sandbox guarantee. Players who enable OS/file access for a script accept the risk. The doc and the in-game text must say so.

---

## 8. Visual and audio direction

### 8.1 Visual
- **Shapes only.** Circles, lines, triangles, squares; no textures, no sprites. Everything is drawn from vector primitives (`_draw()` / shaders), anti-aliased.
- **Palette** (starting values): background `#0B0D10`; faint grid `#161A20`; player white `#F2F2F2`; player bullets bright white by default (script may set `color`); enemy bullets warm `#FF5A4D`; enemies each a single cool or neutral hue by *role*: Drifter `#7DA2FF`, Swarmer `#7DE0C3`, Shieldbearer `#C9A7FF`, Tank `#8C8C8C`, Sniper `#FFD166`, Phaser `#F28FD0`, Mirror `#E8E8E8` outline. Bosses: one saturated hue each, larger than anything else (≥3× player size), with a glow (see **Rendering note** below).
- **Readability rule (P3):** enemy bullets are always warmer and brighter than the background, player bullets cooler/white. Bullet count never hides the player: the player has a 12 px white core with a thin dark halo at all times.
- **Juice, minimal:** 2-frame hit flash, tiny screen shake (≤3 px) only on boss phase changes, bullets leave a short fading **trail** so the *path of your script* is visible (the signature look). The trail is a **shader smear, not extra instances** (cost and fallback rule below).
- **Trail cost and the cheap implementation.**
  - *Estimate of the naive way (not measured):* drawing a 6-frame trail as 6 extra `MultiMesh` instances per bullet means 7 instances per bullet. `BulletRenderer` writes `FLOATS_PER_INSTANCE = 12` floats (48 B) per instance and, with physics interpolation, a current and a previous buffer. At **10,000 bullets** that is 70,000 instances ≈ **3.4 MB per tick per buffer (≈ 6.7 MB with the previous buffer; ≈ 400 MB/s at 60 Hz)** versus ≈ 0.5 MB (≈ 1 MB) for 10,000 plain bullets, plus 7× the GDScript fill loop in `update_from`, which is already the hot path next to a 12.4 ms p50 simulation at 10k in the scaffold benchmark. **That does not fit the 16.6 ms budget**, so it is rejected.
  - *Chosen:* **velocity-aligned smear in the existing shader.** `BulletRenderer` already stretches each bullet along its travel direction (`stretch`, `length_scale`) and `bullet.gdshader` draws it as a quad with per-instance colour. The smear lengthens each bullet's quad to `max(2·radius, speed × trail_time)`, offsets its centre backwards by half the extra length, and fades alpha along the tail in `bullet.gdshader` (using `UV.x`). **Zero extra instances and no extra buffer upload**; the only added cost is a little fill rate (more pixels per bullet). `trail_time` = 0.10 s (**6 frames at 60 Hz**). Curving bullets show a straight smear along the current heading rather than the true path (acceptable; the *shape of the pattern* still reads from the bullets' spacing).
  - *Fallback rule (by live count, re-evaluated each second, with hysteresis):* **≤ 3,000 live bullets: `trail_time` 0.10 s; 3,000–7,000: 0.05 s (3 frames); > 7,000: smear only on enemy and boss bullets (readability of threats first, P3) and none on player bullets.** If the p95 frame time exceeds 90% of the budget for 2 s, drop one level; on web and mobile start at the 0.05 s level. A "true path" ribbon (history samples) is **not** in scope until a measured budget allows it.
- **Editor UI:** monospace font, same palette, syntax highlighting in 4 colors; no chrome beyond a 1 px border. Must scale to phone screens: minimum 16 dp touch targets, adjustable font size (see §10).
- **Rendering note (glow and grid warp; pending a QA check).** The scaffold's `project.godot` sets `renderer/rendering_method="gl_compatibility"` for desktop **and** mobile, and web uses the same Compatibility renderer. **Boss glow (post-process bloom) and the grid warp (post-process, §6.4) are therefore designated Forward+/Mobile-only effects** and are **untested on GL Compatibility**; QA must check them on web and mobile before anything depends on them. **Defined Compatibility fallback (the default until QA signs off):** *glow* = a larger, low-alpha additive halo disc drawn behind the boss in `_draw()` (no post-process) and a brighter outline on its telegraphs; *grid warp* = no post-process: the grid lines near a boss chunk are drawn by `_draw()` with a vertex offset of ≤3 px (about a few dozen lines, CPU-side), or simply a brightness pulse on those lines if that proves too costly. Nothing in the gameplay rules relies on either effect (the beacon, hum and edge tick are the actual signals, §6.4).
- **Camera:** fixed zoom (1 world unit = 1 px at the **1280×720** base viewport; see §6.1), slight lead toward the aim direction (≤80 px), following the player with the scaffold's `FollowCamera` (frame-rate independent smoothing, aim lean, `add_trauma()` shake). On phones the same rule holds: the visible area is always 1280×720 world units (stretch `canvas_items`, aspect `keep`), so bullets stay visible and the game isn't easier or harder by screen size.

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
1. **Largely done on PR #2:** player movement + aim + `BasicShot`, `InputDevice` (kbm/gamepad switching), `FollowCamera`, the bullet pool/renderer and `TrainingDummy`. Still to add: touch input and the web/mobile export checks.
2. **Spike (before committing the stack): Lua binding + Godot 4 export to Web and Android/iOS** (see Q14). Then load `shots/default.lua`, `on_fire`, hot reload, in-game editor.
3. Guard rails of §3.2 (time/instruction/memory budgets, error isolation) built together with the binding, not later.
4. Drifter + Swarmer + player HP (pips, §5.4). `Player` currently emits `damaged(amount)` with no health.
5. Chunked world, seed, regular spawns (§6.2).
6. Armor/Shield/Mirror archetypes, then **elites and affixes** (§6.5; per-`Hurtbox` hit responses are shared with step 6) and the rarity visual language, with the Herald after the first Drifter loop works.
7. First boss + Fragment + `sense.*` gating + Codex.
8. Region-quota boss spawn + beacon (§6.3–6.4), with boss rarity and pity (`spawning-and-rarity.md` §4–§6) as a data-driven table from the start.
9. Controller- and touch-friendly editor (§10); the capability prompt (§7.1).
10. Audio voices from scripts; visuals polish.
11. Player combat spec (§5.4): pips, regen, hit i-frames, dash, ownership/reflection. Build the **`player` facade with `__newindex` write detection** (§12.1) from the start, so the boss counters (§12.2) can read its events.
12. **Not first release:** the Constrained mode (§11, decided shape: spellbook core + RPG stats); step 2's binding must already allow per-mode capability sets.

---

## 10. Platforms and input (decided Q8: PC, controller, web, mobile)

| Platform | Play input | Script editing | Capability notes |
|---|---|---|---|
| **PC** (Win/Linux/macOS) | Mouse + keyboard (WASD + mouse aim) | Full in-game editor; also **external editor hot reload** (watch `shots/`), first release | Full Lua, opt-in capabilities `native`/`os`/`io`/`debug`/`package` (§3.2). **10,000** live bullets (floor 5,000), 3 ms script budget (§3.3) |
| **Controller** | Left stick move, right stick aim + auto-fire past deadzone (or trigger) | Controller-friendly editor (below) | Same as PC |
| **Web** | Mouse + keyboard (touch/controller if present) | In-game editor; Export / Import button for `.lua` files | **No OS or real file access** (browser sandbox): `native`, `os`, `io`, `package` unavailable (`io` may be a virtual file system, Q14). Lower bullet/time budgets (below). Needs a Lua binding that exports to Web (Q14). |
| **Mobile** (Android, iOS) | Twin virtual sticks (left move, right aim + auto-fire) | Touch editor and/or companion editing (below) | File access limited to the app sandbox, no `os.execute`. Lower budgets. |

### 10.1 Design implications
- **One game, one ruleset.** Enemies, Senses, damage, spawns and bosses are identical across platforms. The player's *device* is exposed as `ctx.device`, so scripts can adapt, but the engine adds no hidden bonuses. Aim assist is the one deliberate exception and is an open question (Q15).
- **The editor is a first-class feature on every platform** (P1: *code is the weapon*). It may not be dumbed down into menus on touch; instead the *input method* is helped.
- **Touch-friendly script editor** (starting design):
  - Full-screen editing on phones; the arena keeps running at 15% in a small corner preview (§2), and a one-tap *resume* button.
  - A **symbol row** above the OS keyboard (`( ) { } [ ] , . = " ' end function`), an **indent/dedent** button, bracket auto-close, large undo/redo.
  - **Snippet palette** (insert `shoot{}` skeletons, loops, `update` hook) and **tunable number sliders**: numeric literals marked `--@tune 0..1` or recognized in `shoot{}` get a slider on touch and controller. These help typing; they never replace code.
  - Pinch to resize text; landscape and portrait layouts.
- **Companion editing.** Edit on a second device while playing: (a) **PC external-editor hot reload** (watch `shots/`), (b) **phone as editor for a PC session** or **PC browser as editor for a phone session** over LAN/QR pairing, with live reload within one frame. **Decided (Q13 = B): (a) ships in the first release; (b) phone pairing comes later.**
- **Controller-friendly editor navigation.** D-pad / stick moves a *token cursor* (jumps by word, bracket, line); face buttons insert from a radial snippet menu; shoulder buttons change the number under the cursor ±step (tunable literals); the OS/Steam-style on-screen keyboard for free text; a **"quick tune" mode** that cycles through tunable numbers without text entry at all.
- **Web build sandbox limits.** No OS or file access, so scripts that declare `needs` such as `"os"`, `"io"`, `"package"` or `"native"` print an explanation and run with those libraries `nil`. Saves and `shots/` live in browser storage (IndexedDB) with an **Export / Import** button for `.lua` files and saves. **Starting values (not derived from the PC number; to be measured in the Q14 spike): total live-bullet cap 4,000 (2,800 player / 1,200 reserved for enemies and bosses, the same 30% rule), script time budget 2 ms.** Web builds must work without threads if the host (e.g., itch.io) can't provide cross-origin isolation.
- **Mobile budgets.** **Starting values (separate from PC and web; to be measured): total live-bullet cap 2,500 (1,750 player / 750 reserved), script time budget 2 ms per frame**, with thermal-aware reduction; battery saver mode reduces trails and audio voices (§8).
- **Saves.** One save format on all platforms; cloud/cross-device sync is a later option (Q15).
- **Getting a script onto a device** (no in-game sharing, §7): on PC copy the `.lua` file into `shots/`; on web use the Export / Import button; on mobile use the app's `shots/` folder (file manager or USB) or type it in the touch editor.
- **A script on another platform** keeps working: if a script exceeds a lower platform budget it is clamped by the §3.2 guards and the editor shows exactly which one.
- **UI layout.** HUD is minimal already (P3); on touch the sticks are drawn as thin outlines at 40% opacity, position-adjustable, and never over the player's own bullets' path (sticks placed in the lower corners).
- **Audio on web/mobile.** Synthesized audio (§8.2) must start after the first user gesture (browser autoplay rules); voice cap lower on mobile.

---

## 11. Planned mode (NOT first release): Constrained Scripting mode

> Working title: **Constrained mode** (name TBD). **Status: planned, not in the first release. Shape decided (Q10 = D): an S3 spellbook (unlockable API) as the spine, S2 RPG stats as the tuning layer, the S1 meter as the implementation mechanism. Relation to the main mode decided (Q11 = B): shared world generator and bestiary (so elites, bosses and rarity tiers carry over), separate saves and progression, scripts usable in both modes and clamped to the receiving mode's limits.** It is a *separate game mode* with its own save; the main mode (§1–§10) keeps its fully open API, with Senses unlocked by bosses. This section sketches what it could be so that the main-mode engine is designed to host it later.

**Why it exists.** The main mode honors "no restrictions" completely, which makes the *creative ceiling* high but the *progression* mostly informational. A second mode takes the opposite stance: **limited scripting power is the design**, giving players who like RPG progression a game of building power over time. Constraints here are *the point of the mode* and are chosen by the player when they pick the mode, so they do not conflict with P2 in the main mode.

**Shared foundations (must be true in the first release so this mode is cheap later):**
- The script environment is built from a **capability set** per mode (`env` table that the engine fills), so a mode can expose fewer functions or wrap them.
- The §3.2 *instruction counter* is also usable as a **meter** (cost-per-callback) for budgets.
- `shoot`, Senses, `ctx` and **`player` writes** pass through an **API facade** that a mode can intercept (clamp counts, charge costs, or make `player` read-only). In the Constrained mode `player` writes are absent or costed by design, which is what makes it the home of fair competition (§12.5).

### Three possible shapes

| Shape | Core rule | Example | Pros | Cons |
|---|---|---|---|---|
| **S1. Budget** ("compute budget") | Every shot has a budget (e.g., instruction or "ops" meter, live-bullet allowance). Level-ups and gear raise it. Over budget → the callback halts for that frame. | Level 1: 200 ops/shot and 40 live bullets. Level 10: 2,000 ops and 400 bullets. | Reuses §3.2 instrumentation; rewards *efficient* code, a real programmer's challenge. | Players must understand ops; frustration when a script silently stops (needs great feedback). |
| **S2. Stat-driven RPG** | Character stats map to script limits: **Focus** = max bullets per shot, **Clock** = shots/second, **Reach** = bullet life/range, **Memory** = size of persistent `state`, **Insight** = Senses available. Points from levels, items and quests. | `Focus 6` → `shoot` ignores the 7th bullet of a call and says so. | Familiar RPG loop; easy to balance and to explain; many build choices. | Stats limit code in obvious ways; risks feeling arbitrary vs. the main mode's philosophy. |
| **S3. Unlockable API ("spellbook")** | Start with `shoot` and `ctx.aim` only. API functions, bullet hooks and Senses are unlocked via quests, loot, or boss drops. Each function has a **cost** drawn from a resource that regenerates. | Unlock `update` hook at Lv 3; `on_die` split at Lv 8; `sense.terrain` via a quest. | Strong sense of discovery and "growing a language"; teaches programming gradually. | Heavy content/authoring cost; needs tutoring-style design for new coders. |

**Decided (Q10 = D): S3 as the spine with S2 stats as the tuning layer, and S1's meter as the implementation mechanism** (the budget is how costs are enforced, stats and unlocks decide the numbers). **Decided (Q11 = B):** the mode reuses the main mode's world generator, bestiary and rarity tables (`spawning-and-rarity.md`), keeps its **own save and progression**, and clamps imported scripts to its limits (§7). Do not build before the first release is playable.

### Likely systems (if S2/S3 are chosen)
Levels and XP from enemies; stats and gear; quests/NPCs or a *terminal* hub (this would add non-boss points of interest, so it interacts with Q7); a separate save; the same minimalist look and audio (§8).

---

## 12. Challenge when god mode is one line away

**Context (decided):** player state is **writable** by scripts. `player.invulnerable = true`, `player.hp = 1e9`, `player.pos = boss.pos`, `player.speed = 5000` are all valid Lua in the main mode, from minute one. We do not ban them (P1, P2). **Decided (Karyu, 2026-10-30, 3:26 PM):** the answer is **diegetic**: *the world fights back*. There are **no leaderboards, no MOD tags, no modified/clean marks and no clean-kill gating of rewards**, and there is **no global Corruption**. Nothing is recorded about how you played; what changes is what the world does to you while you do it. Verified fair play stays possible **later** in the Constrained mode (§12.5).

### 12.1 What the world can detect (shared definition)
The world **reads** the player facade during a fight; it does not record or mark anything. An **advantage write** is a write to `player.*` (or a returned `on_hurt` value) that gives the player an *advantage over what the engine would have produced*:
- `hp` set above the engine's value, `max_hp` raised, `regen_*` improved, `iframes`/`dash_cd` improved;
- `invulnerable = true`;
- `pos` changed by more than the physical move budget (> 1.5 × `speed` × `dt` + dash distance in one frame), i.e. a teleport;
- `speed` raised above its base value, `vel` forced above base speed;
- `on_hurt` returning less than `dmg`.

**Not advantage writes:** reads; `player.dash()` (same rules as the button); automation such as auto-dodge or auto-aim (it is the game: code is the weapon); and handicaps (lower `max_hp`, lower `speed`, regen off), which are simply harder play.

Engine implementation (decided by the Scripting Engineer, PR #3 `api.md` *Write detection, not provenance*): the `player` facade (`__newindex`) is **write detection only**. It emits **events** that the boss counters read (the Rift, the Equalizer, the Eater's Hunger meter); **nothing is tagged and nothing is stored**. The events come from the Lua binding's `player` proxy, because `PlayerState` (PR #4) has none; the **event names are proposed in PR #3** (`script_wrote(field, old, new)` for every committed write and `script_teleported(from, to)` for `pos` writes) and **to be confirmed there** with the Gameplay Engineer (`Player.teleported` also fires on respawn, so it can't be used for the Rift). Detection is never stored, shown as a mark or used to gate a reward.

### 12.2 Diegetic counters (the world pushes back)

| Counter | How it works | Where it appears |
|---|---|---|
| **Null attacks** | A marked attack class (distinct white-violet colour, ≥0.8 s telegraph) **ignores the `player.invulnerable` script flag and overheal**, but still respects *engine i-frames* (dash/hit i-frames). 1 damage each. Turns god mode into "you still need to dodge the pierce attacks". In code this is the bullet flag **`pierces_script_invuln`** (PR #4, merged; `null_pierce` is its design/Lua-facing name), owned by the **Gameplay Engineer**. | **Every boss from Tier 2 has 1–2 Null attacks.** Also the Null-shot elite affix and the legendary Null rings (`spawning-and-rarity.md`). |
| **The Equalizer** (HP-reading boss) | Reads `player.hp / max_hp` each frame and **scales to it**: overheal beyond max converts into boss damage/HP (+1 boss tier per 2 overheal pips), so setting `hp = 1e9` produces an unwinnable boss rather than god mode. | One or two bosses (flavour); also legendary Lattice's Phase ★. Trivially bypassed by `invulnerable` unless combined with Null attacks, which is why those exist. |
| **The Rift** (position deltas) | The engine measures `|Δpos|` per frame against the physical move budget. A teleport > 600 px (or any `pos` write inside a boss arena) spawns a **Rift** at the origin and destination: after 0.6 s each Rift emits a 1-damage ring (telegraphed) and gives the boss a charge. Not applied to open-world travel (fast travel via script is fine). | Select bosses (one that "hunts" the destination); also legendary Mantle's Phase ★. |
| **The Eater** (an in-boss meter) | **Inside one boss only**: while that fight runs, each advantage write fills the Eater's own **Hunger** meter (0–100, drains 1/s, drawn as a violet ring on the boss, not on the player). At 100 the Eater **hunts you** (a fast, telegraphed chaser that deals 1 damage). The meter resets when the fight ends. | One boss. **There is no global Corruption**: it would be a soft cap that quietly punishes any use (against P2's spirit), is hard to define fairly and is the highest tuning risk. |

Strength: a world that pushes back is on-brand (P2). Weakness: every counter is a new rule to learn, and a clever script can dodge one specific counter. Null attacks are the backbone because they do not depend on the player noticing a rule; the others are flavour. None of them is a ban: the script is always allowed to run, and a player who enjoys god mode still gets a fight.

### 12.3 Engine i-frames vs script flags
Two separate layers exist on purpose: **engine i-frames** (0.75 s after a hit, 0.2 s during a dash; always respected by every attack, including Null attacks) and the **script flag** `player.invulnerable` (ignored by Null attacks and any "bypass" rule). Bosses that bypass flags still need the player to dodge, and a player who plays normally is never affected by the bypass layer.

### 12.4 Rewards without tags
Nothing is gated on how the script behaved. **Core progression is never gated:** Fragments, **Sense Level I**, tier access and the Codex page for a first kill come from **any kill**.

| Reward | Route (no tag, no clean-kill condition) |
|---|---|
| Kill credit, Codex page, **Sense Level I** (decided Q1) | **Any kill** of the boss type, any rarity |
| **Sense Level II** (extended data: velocity, HP, larger range) | **Rare or legendary boss kill** of that Sense's boss type, **or Shards** (25 Shards = one token, decided Q19; Shards come from elites and bosses, `spawning-and-rarity.md` §7). Mantle (no Sense) gives a token instead |
| **Seal** (per-boss mark, cosmetic and Codex) | **Beating the boss's counter phase** (below), **or a rare/legendary kill** of that boss type |
| **Alternate-solution Codex entries** | One entry for each **counter phase beaten** and one for each **rare variant twist** killed (`spawning-and-rarity.md` §5) |
| **Echo challenge** cosmetics (below) | An Echo rematch with modifiers |

- **Counter phase.** Each boss has a phase in which its counter appears: from Tier 2 the phase with its Null attacks (and the Equalizer/Rift/Eater rule on the bosses that carry one); for a legendary boss its Phase ★. The phase is **beaten** when it ends without the player taking damage from its Null/counter attacks. This is a skill check on dodging that anyone can fail or pass; **it does not look at the player's script or state**, and the counter attacks pierce flags, so god mode does not skip it. Tier 0–1 bosses (pool A) have no Null attacks, so their Seal comes from the rare route.
- **Echo (decided here: keep, as an *optional harder rematch*, cosmetic only, after the first release).** A killed boss leaves a faint **Echo** beacon the player can re-fight with chosen **modifiers** that the engine applies as rules: *Frail* (max HP 3), *No regen*, *No dash*, *Overclock* (boss ×1.25 speed), *Bare* (no Senses active). Each modifier is worth 1 point; 3 points give a cosmetic bullet trail or voice and a Codex line. It gives **no Fragments, Shards or Level II** (so it can't be farmed and nothing core depends on it). **Why keep it rather than drop it:** it is cheap (the boss and the modifier rules already exist), it gives players who want a harder ladder one without touching the main game's rewards, and it needs no tag or detection at all. It no longer has to repair "clean" rewards, so it can wait; if playtests show nobody uses it, drop it.
- **Codex entry** per boss: ○ not killed, ● killed, plus small pips for the rarities killed and the counter phase beaten. These are collection pips, not quality marks.

### 12.5 Verified fair play: later, in the Constrained mode
The main mode is a **sandbox**; nothing in it is ranked. If verified competition is ever wanted, it belongs to the Constrained mode (§11): its API facade makes `player` read-only (or costed), its caps are known, and its runs can be validated (deterministic replays of seed + inputs + script hash). That keeps the main mode's freedom untouched. This is a plan for later, not first-release work, and the first release has no rankings of any kind.

### 12.6 Interactions and caveats
- **Health regen and i-frames:** `regen_*`, `iframes`, `dash_cd` are all writable. Because engine i-frames (hit + dash) are the *real* defence, a normal player's defence is dodge timing, and Null attacks (§12.2) respect them. Regen at 1 per 3 s after 5 s is tuned so scripts that merely *wait safely* don't trivialize fights.
- **Dash automation:** an auto-dodge script obeys the same cooldown. If playtests show it trivializes bosses, the answer is boss design (telegraph lengths, Null attacks), not a ban.
- **Open source = client trust.** Anyone can patch a local build or save. That is fine because nothing in the main mode is ranked or verified, so there is nothing to cheat.
- **Scripts from anywhere** may write state; the game neither warns about it nor marks it (only the capability prompt of §7.1 applies, and only to capabilities).
- **Difficulty tuning:** boss HP and damage are balanced for a player at the engine's normal state (5 HP, i-frames, dash). Players who rewrite their state play in their own balance zone, and the counters above are the design's answer to it.

### 12.7 Summary
The world fights back **diegetically**: Null attacks from Tier 2 on every boss, plus the Equalizer, Rift and Eater (in-boss meter) as flavour bosses, **no global Corruption**. Rewards never depend on a tag or a clean kill: Level I from any kill; Level II from rare/legendary boss kills and Shards; Seals and alternate Codex entries from counter phases and rare variants; the Echo is an optional harder rematch. Verified fair play, if ever wanted, lives in the Constrained mode.

---

## Biggest open design questions

Question IDs are stable. **Resolved on 2026-10-30:** Q1, Q2, Q3, Q4, Q8, **Q12 (closed as moot: no in-game script sharing or import), Q16 (Karyu: no leaderboards, tags or clean-kill gating; diegetic counters), the leaderboard part of Q15**, **Q9 (replaced by elites and rarity tiers), Q10 (D), Q11 (B), Q13 (B)**; **Q17–Q24 decided by the Chief of Staff under Karyu's delegation (Karyu can override; see the log)**; and the combat decisions Health 1A / I-frames 2B / Friendly fire 3C / Death 4A / writable player state (see the Decisions log at the top). Open questions below each have options and a recommendation; **[Karyu]** marks the ones that need the project owner's decision (none at the moment).

### Q5. Editing while the world is hostile (and the guard-rail numbers)
- **A. Time slows to ~15% while the editor is open** (recommended start).
- **B. Full pause** (safer, kills tension and the live-edit thrill).
- **C. Real-time, world keeps running** (maximum tension, hard on touch/laptops).
- **D. Setting:** let the player choose.
- **Recommendation: A as default, D as an accessibility setting.** On phones the editor is full-screen with the world at 15% in a preview (§10). The §3.2/§3.3 guard values (3 ms, 100,000 instructions, 64 MB, 10,000 bullets with a 5,000 floor on PC; separate web and mobile values in §10) are starting values to benchmark on target devices.

### Q6. Boss "Habituation" mechanic: is it too punishing or exploitable?
- **A. Keep as specified** (§5.3), tune on playtests.
- **B. Soft version:** adaptation reduces damage only to the *dominant* pattern, floor ×0.6.
- **C. Drop it:** rely on armor, weak points, and phases.
- **Recommendation: A, prototyped behind a flag.** It's the most distinctive way to create tension *without* limiting code, but needs playtest to avoid feeling like "the boss punishes me for finding something that works".

### Q7. Where do bosses sit in the long-term open world?
- **A. Bosses stay the only POIs** (current brief) with escalating tiers.
- **B. Add POIs after the first release** (shops, ruins) that sell/teach Senses.
- **Recommendation: A for now**, designing the Fragment/Codex systems so B can be added later without redoing progression. Note: the planned Constrained mode (§11) may want hubs or NPCs; this question must be revisited when that mode is scoped.

### Q14. Technical feasibility: Lua on Godot 4 for Web and mobile exports
- **A. A Lua GDExtension (e.g., `lua-gdextension`) if it exports to Web/Android/iOS** (needs verification).
- **B. A custom thin C/C++ Lua 5.4 binding built for all targets** (more work, fully in our control).
- **C. A pure-GDScript or pure-managed Lua interpreter** (portable but slow, may violate the bullet/budget targets).
- **Recommendation: spike A first (§9 step 2); fall back to B.** Do not commit to a platform promise until a Web and an Android export both run a 1,000-bullet script within the time budget. Also decide what `io` means on Web (absent vs. virtual file system backed by IndexedDB; recommendation: virtual FS limited to `shots/` and `data/`, with Export/Import).

### Q15. Aim assist and cloud sync (narrowed on 2026-10-30)
The leaderboard part of this question is **closed**: Karyu dropped leaderboards (see the decisions log), so no per-platform boards, no device flags and no tag dimension are needed. What remains:
- **A. Same rules everywhere; no aim assist; local saves.**
- **B. Optional aim assist on touch/controller** (off by default, clearly labeled).
- **C. B + cloud saves/cross-device sync.**
- **Recommendation: A for the first playable; B only if playtests show touch is unplayable without it; cloud sync is a later option.** Rules stay identical across platforms either way (§10.1).
