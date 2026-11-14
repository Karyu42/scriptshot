# RPG mode

> Status: **post-slice design.** Working title **RPG mode**. It replaces the name "Constrained mode" and the earlier "spellbook + RPG stats, limited scripting" plan (pillars §11, Q10 = D). Companions: [`pillars.md`](pillars.md) §11, [`ability-scripting.md`](ability-scripting.md), [`spawning-and-rarity.md`](spawning-and-rarity.md). Do not build this before the main-mode first release is playable. Numbers below are the ones in this spec. A missing tune value is `TBD (tune)`.

**What it refines.** A card-and-slot build system, in the manner of Noita and Magicraft.

- The spellbook spine becomes the **card collection**.
- The RPG stats become **Frame stats**.
- The S1 meter becomes **mana** plus a per-card ops budget.
- Kept from before: **separate saves; a shared world generator, bestiary, and rarity tables; local saves only, with no in-game sharing.** Players may copy files outside the game, as in the main mode.

## B1. Vocabulary

**Frame.** A weapon with stats and an ordered row of **slots**. The player holds **2** Frames and swaps them with a button.

| Frame stat | Value |
|---|---|
| Slot count | **3–8**, by Frame rarity |
| Mana max | `TBD (tune)` |
| Mana regen | `TBD (tune)` per second |
| Cast delay | `TBD (tune)`. Time between casts |
| Recharge | `TBD (tune)`. Time after the row is exhausted |
| Spread | `TBD (tune)` |

**Card.** Goes in a slot. Four kinds:

| Kind | What it does | Named cards |
|---|---|---|
| **Shot** | Makes projectiles | Bolt, Spark, Orb, Lance, Mine |
| **Modifier** | Changes the next Shot | Damage+, Speed+, Pierce, Homing, Split on hit, Bounce, Heavy, Lifetime+ |
| **Multicast** | Casts the next N Shots together | Double, Triple, Fan ×3 |
| **Trigger** | A Shot that carries the following group as its payload, cast at a moment | on hit, on expire, or a **0.5 s** timer |

**Cast.** One press of a Frame, or one auto-fire tick.

## B2. Chain and slot rules

**Game Designer call.**

1. A cast reads slots left to right from the Frame's cursor. Modifiers stack onto a pending bundle until a Shot card closes it. A Multicast N keeps drawing until N Shots are closed, and casts them together.
2. Every card's mana cost is paid when it is drawn. If mana runs short mid-draw, the cast fires what it has closed so far. The rest **fizzles** with a small grey puff. That is readable. There is no penalty beyond the wasted mana.
3. When the cursor passes the last slot, the cast that is in progress **wraps once** to slot 1 to finish its bundle. After the cast, the Frame **recharges** and the cursor resets to slot 1. A bundle that still has no Shot after the wrap fizzles.
4. Trigger nesting is capped at **depth 3**. A Trigger inside depth 3 casts its own Shot without its payload.
5. Each cast has a projectile cap of **64**. The excess fizzles. A Frame cannot have more than **24** of its projectiles alive.
6. Modifier stacking: additive stats add, then multiplicative ones multiply. Booleans (Pierce, Homing) are idempotent: a second copy adds nothing, and its card tooltip says so. Order matters only for Triggers and Multicasts. The stat sum is order-free, so builds are readable.
7. Empty slots are skipped at no cost.
8. **Build preview.** The Frame screen shows the cast sequence as a strip (bundles boxed, wraps marked, fizzles in grey), plus per-cast mana, a DPS estimate, and recharge. It uses the same deterministic sim as the editor path preview ([`ability-scripting.md`](ability-scripting.md) A4.4).
9. Editing slots is allowed anywhere outside combat (no enemy awake within **800 px**). Swapping a whole Frame is allowed anytime.

## B3. Runs and drops

The run structure is **Karyu decides** (Q29, below). Drops do not wait on that answer.

Cards and Frames drop from enemies and elites. Rarity tables are per source. Draws use the deterministic `hash_u(run_seed, source_id, "drop")` style, never runtime RNG. Drops come from a **drop pool** (B5).

| Source | Drop |
|---|---|
| Regular | Rarely, a common card. The rate is `TBD (tune)` |
| Elite | One card. Rarity rises with the elite's rarity. The table is `TBD (tune)` |
| Boss | A Frame or a rare card, plus a choice of **1 from 3** |

## B4. User-authored modifiers in Lua

A file in `rpg/modifiers/*.lua`:

```lua
return {
  id = "karyu.ricochet_split",   -- unique, namespaced
  name = "Ricochet Split",
  kind = "modifier",             -- "shot" | "modifier" | "multicast" | "trigger"
  desc = "Bullets split in two when they bounce.",
  apply = function(b)            -- runs once on the pending bundle; b is a shot-spec proxy
    b.bounces = b.bounces + 1
    b.on_wall = function(ctx, s) s:split(2, 0.6) end
  end,
}
```

Built-in cards are written in the same API, so user cards are first-class and the API stays honest.

### Sandbox: the RPG capability set

**Game Designer call.** This is a stricter `env` than the main mode, built on the per-mode facade (pillars §11 *Shared foundations*).

| Available | Not available |
|---|---|
| The bundle API (`s:split`, `cast_payload`). Spawns count against the **64** / **24** caps | `io`, `os`, `package`, `native`, capabilities, and prompts. They are not requestable in RPG mode |
| Senses the run has unlocked | `player` writes. `player` is read-only |
| | `state` persistence across casts or runs |

Budgets:

| What | Cap |
|---|---|
| `apply` | **2,000** instructions per call |
| A per-bullet hook (`on_hit`, `on_wall`, `on_tick`, `on_expire`) | **200** instructions each |
| Per-card memory | **64 KiB** |

If a card goes over budget, that card is disabled for the rest of the run, with a toast, and the cast continues without it. Errors work the same way: the card is disabled for the run, and the error is shown in the editor.

### Power appraisal

**Game Designer call.** Balance comes from appraisal, not from a hand-set cost.

When a user card is enabled, the engine runs a deterministic **appraisal**. It applies the card to a set of reference bundles (Bolt alone, Bolt+Damage+, Triple Spark) and measures the stat deltas: damage per mana, projectile count, effective range, pierce, bounce, homing, and trigger fan-out.

A **price table** turns those deltas into a **Power** score. It is the same table that prices the built-in cards, and it is tunable data. The table's numbers are `TBD (tune)`.

Power sets the card's **mana cost** (the declared cost is only a floor) and its **rarity**. A card above the **Power ceiling** for legendary cannot be enabled. The manager says by how much and why. The ceiling per rarity is `TBD (tune)`.

If a card's behaviour cannot be appraised, for example because it depends on hits, it is appraised with a scripted hit sequence in the reference arena.

### Validation before enabling

All four must pass:

1. It loads.
2. The schema is valid (`id`, `kind`, `apply`).
3. Appraisal is under budget and under the ceiling.
4. A **10 s** smoke cast in the pocket arena (ability-scripting A4.4) runs with no errors.

### Entering the drop pool

**Game Designer call.**

An RPG-mode **Modifier manager** lists built-in and user cards. User cards have an **"In drops"** toggle, available only after they pass validation.

- An enabled card joins the pool at its appraised rarity's weight.
- User cards make up at most **30%** of drops by default. The manager has a slider from **0%** to **50%**.
- User cards are **never starting gear**. They must drop. RPG mode stays a game of finding builds.
- Each run snapshots the enabled set by content hash at run start, so the run stays deterministic. Edits apply from the next run. The manager shows "changed, applies next run".
- Saves are local only, with no sharing, as before.

## B5. Balance knobs

All of these are data. One table.

| Knob | Value |
|---|---|
| Mana max, mana regen, cast delay, recharge | `TBD (tune)` |
| Slot count per Frame rarity | **3–8** |
| Per-card mana cost (built-ins) | `TBD (tune)`, except where appraisal sets a user card's cost |
| Price table | `TBD (tune)`. Same table for built-in and user cards |
| Power ceiling per rarity | `TBD (tune)` |
| Rarity weights per drop source | `TBD (tune)`. See B3 for the shape |
| User-card drop share | Default **30%**, slider **0–50%** |
| Projectile caps | **64** per cast, **24** alive |
| Trigger depth | **3** |
| Ops budgets | **2,000** on `apply`, **200** on a per-bullet hook |
| Card memory | **64 KiB** |
| Enemy HP multiplier for RPG mode | Default **×1.0**, `TBD (tune)`. Shared bestiary, separate multiplier. The shared tier scaling ×(1 + 0.35·T) stays |
| Drop rates per enemy rarity | `TBD (tune)` |

## B6. Fit after the slice

RPG mode starts only after the main-mode first release is playable. That pillars rule stands. Ability scripting comes first, because both modes use its editor tools.

None of this touches the vertical slice or its rows.

| Step | What |
|---|---|
| R0 | The per-mode capability facade (already required by the pillars), plus RPG-mode save separation |
| R1 | The card engine, the chain rules, and about **20** built-in cards written in Lua |
| R2 | The Frame screen and build preview |
| R3 | Drops and the run loop |
| R4 | User modifiers, appraisal, and validation |
| R5 | The Modifier manager |

## B7. Karyu decides

One question each. The recommended option is first and in bold. These are also Q29, Q30, and Q31 in [`pillars.md`](pillars.md).

### 1. RPG run structure (Q29)

**Karyu decides.**

- **A. Roguelite runs (recommended).** The build is lost on death. Discovered cards stay in the collection.
- **B. Persistent.** Keep everything and respawn, as in the main mode.
- **C. Hub expeditions.** A persistent character, with Frames reset per expedition.

### 2. Scripts crossing between modes (Q30)

**Karyu decides.** This revises Q11 = B.

- **A. Only modifier files cross (recommended).** Main-mode weapon scripts do not load in RPG mode.
- **B. Keep Q11.** A weapon script can be slotted as one heavily clamped "Script card".
- **C. Nothing crosses.**

### 3. Abilities in RPG mode (Q31)

**Karyu decides.**

- **A. Shots only at launch.**
- **B. Shots plus a 2-slot Dash Frame with dash cards (recommended).**
- **C. Shots, dash, and movement cards.**

## B8. Calls the Game Designer made

- Wrap once, then recharge.
- Fizzle instead of blocking the cast.
- Trigger depth 3.
- Projectile caps of 64 per cast and 24 alive.
- Order-free stat sums.
- Edit slots out of combat only.
- 2 Frames.
- Appraisal-based cost and rarity.
- A 30% default share for user cards.
- User cards never start equipped.
- A per-run snapshot of enabled cards.
- `player` is read-only in RPG mode.
