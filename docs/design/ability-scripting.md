# Ability scripting

> Status: **post-slice design.** The vertical slice does not build this. Companions: [`pillars.md`](pillars.md) (P1, P2, §12), [`../scripting/api.md`](../scripting/api.md) (*Writing player state*, *Weapon state*), [`../scripting/editor.md`](../scripting/editor.md), [`rpg-modifiers.md`](rpg-modifiers.md). Numbers below are the ones in this spec. Anything still missing is `TBD (tune)`.

**Goal.** Players script and tune movement, dash, and similar abilities, not only shots. It builds on the editor, the `PlayerState` write surface, the sandbox, the per-frame budget, hot reload, and `state`. The main mode keeps no restrictions (pillars P1 and P2). The challenge still comes from the world (Null attacks, counter bosses), not from limits on movement.

## A1. Ability slots and files

**Game Designer call.** Ability scripting has three slots.

| Slot | What it does | When |
|---|---|---|
| **Move** | Replaces the hardcoded movement | With the first ability step |
| **Dash** | Replaces the hardcoded dash | With the first ability step |
| **Utility** | A new ability on a new button | Later (A6). It needs an input mapping on every platform: PC, controller, and a touch button on mobile |

Each slot equips one file from a new `abilities/` folder, the same way a weapon equips a file from `shots/`. Bundled defaults ship as `scripting/abilities/*.lua.txt`, the same `.lua.txt` rule bundled scripts already use (`scripting/README.md`). Player files are `.lua`.

**Game Designer call.** The default Move and Dash are Lua files that reproduce today's engine behaviour exactly. A parity test (GE and QA) proves it: the same inputs produce the same positions within **0.5 px** over a **10 s** scripted input trace.

Each ability file has its own `state`, with the same rules as weapon `state` (api.md *Weapon state*).

## A2. Script shape

This shape is a proposal. SE finalises it in api.md and adds an *Ability hooks* section. The `ctx` fields and the hook list are the same as for weapons.

```lua
return {
  name = "Momentum",
  -- Move: every physics tick. input.dir is the unit stick/WASD vector (or zero).
  -- Return the velocity you want. Returning nil uses the default movement.
  on_move = function(ctx, input)
    local target = input.dir * player.speed
    return player.vel:lerp(target, 0.12)
  end,
}
```

```lua
return {
  name = "Blink",
  cooldown = 0.6,              -- the dash button's cooldown for this file
  on_dash = function(ctx, dir) -- runs like on_fire (coroutine-capable, same budget)
    player.pos = player.pos + dir * 160
  end,
}
```

- `on_move(ctx, input)` returns a velocity. The engine applies it through `PlayerState.set_velocity` (the **5000 px/s** clamp) and does wall collision as today.
- `on_dash(ctx, dir)` replaces the dash action. Inside it, `player:dash(angle)` still gives the engine dash.
- Ability files may also call `spawn` (for example a dash that leaves shots behind), using the weapon's bullet budget.

## A3. The one engine floor: engine i-frames

**Game Designer call.**

Scripts can move the player any way they like.

**Engine i-frames** stay engine-owned: the **0.2 s** dash window. Null attacks respect them, and scripts cannot write or extend them.

A scripted dash gets the engine's **0.2 s** i-frames only when it calls `player:dash()`, and only at the engine's dash cooldown. Teleports and velocity bursts are free and unlimited, and they do not add engine i-frames.

Why: script invulnerability is already unlimited, and Null attacks pierce it. If a script could extend engine i-frames, it could get around the Null counters, which are the main mode's only diegetic answer to god mode (pillars §12). This is not a restriction on movement.

Movement writes emit `script_wrote` and `script_teleported`, so the Rift and Equalizer counters work unchanged.

## A4. Editor tools

The main mode and RPG mode share these tools.

### A4.1 Templates per slot

**Game Designer call.** "New from template" filters by slot. Each template is commented for a first-time coder, like the weapon starters.

| Slot | Templates |
|---|---|
| Move | Default, Momentum (ice), Strafe-lock (moving while firing keeps facing), Tank (rotate + thrust) |
| Dash | Default, Double dash (2 charges), Blink (teleport), Shot dash (dash fires a ring) |
| Utility (with A6) | Shield bubble, Decoy, Slow field |

### A4.2 Knobs

**Game Designer call.** A trailing annotation on a line with a literal number or bool turns that literal into a knob:

```lua
local SPEED = 260 --@knob 0..800 step 10 "Top speed"
```

- The editor shows a slider, or a toggle for bools.
- Dragging rewrites the literal in the source. The source stays the only truth.
- It hot-reloads on release, and it hot-reloads live while dragging with a **150 ms** debounce.
- If the line no longer matches the pattern, the knob hides. Nothing breaks.
- Weapons use the same knobs. The old `-- <- tweak me` comments in the starters become knobs in a follow-up.
- On mobile, knobs are the main way to edit.

### A4.3 Inline docs and tooltips

**Game Designer call.**

- Hovering (PC) or long-pressing (mobile) an API name shows its signature, a one-line description, its clamps (for example "speed clamped to 5000 px/s"), and a link to the Codex page.
- Typing `name(` shows signature help.
- The data comes from one index file (for example `scripting/docs/api_index.json`) built from api.md, so the docs and the tooltips cannot drift. SE owns the generator.

### A4.4 Quick test and path preview

**Game Designer call.**

**Test** runs the current editor buffer, unsaved, in a pocket arena.

- The arena has walls, **3** dummies, a Sniper lane, and a Drifter pack. Each of those is toggleable.
- It does not touch the save or the world. Esc returns you to the editor with the buffer intact.

**Path preview** is for Move and Dash only. It is a headless run of a fixed **3 s** input trace (right, then up, then a dash), drawn as a ghost trail beside the code.

- It updates on every knob change.
- It is deterministic and uses the same sim as the game.
- Ops over budget show as a red trail end with the watchdog message.

## A5. Fit after the slice

No slice row changes. The steps are ordered, and each one is a small PR.

| Step | What | Who |
|---|---|---|
| A1 and A2 | Hooks, and the parity default files | GE and SE |
| A4.2 | Knobs. They benefit weapons immediately | SE |
| A4.3 | Tooltips index | SE |
| A4.4 | Test pocket and path preview | GE and SE |
| A4.1 | Templates | Game Designer writes them. SE reviews |
| A6 | Utility slot and button | Later |

The Codex onboarding entry "Your legs are code too" unlocks after the slice's Warden kill, so the slice's onboarding is unchanged.

## A6. Utility

**Game Designer call.** Utility is the third slot. It waits until Move and Dash exist, because it needs a new button on PC, on a controller, and as a touch button on mobile. Its templates are in A4.1.
