# The script editor

Your weapon is a Lua file. The game starts with `shots/default.lua` equipped:
one straight shot along your aim. Change it, save, and your next shot is
different.

## Opening it

| | Open | Close | Save |
|---|---|---|---|
| Keyboard | **E** | **Esc** or *Close* | **Ctrl+S** (or Ctrl+Enter) |
| Controller | **X** (the edit face button) | **X** | *Save* |

While the editor is open, time runs at **15%**. The world keeps moving, so
find a quiet spot, or don't. Your ship does not move or fire while you type.
Closing the editor puts time back to normal.

## Saving

*Save* writes the file to `shots/` and reloads your weapon before the next
shot. Shots already in the air keep the code they were fired with.

If the file has a mistake, the game keeps your last good weapon and says so on
one line:

```
line 4: expected '}' before 'speed'. Still running the last good script.
```

That line gets a small red dot in the margin. Click a problem in the list to
jump to its line. The *details* switch shows the raw Lua message and which
callback it came from.

Mistakes that only show up while playing (say, an `on_hit` that reads a
missing field) appear in the same list, with a count. The game skips that
callback until your next save; everything else keeps running. A script that
runs too long in one go is stopped (`script timeout`). After three of those
it is paused until you save again, and you fire plain shots meanwhile.

Your text is always written to the file, even when it does not load, so a
half-finished idea is never lost.

## Files

On PC the folder is the game's user data folder, under `shots/`. Edit the
files in any text editor you like: when the equipped file changes on disk, the
game reloads it, the same as saving in game. A save that does not load (for
example a write that is only half done) keeps the last good weapon.

Only the equipped file reloads. If you change another file in `shots/`, a
small note says so (`shots/foo.lua saved (not equipped)`) instead of
loading it. Open it in the editor and save to equip it.

The file picker lists everything in `shots/`. *+ new file* saves the current
text as a new `shot_N.lua`. Opening a file does not equip it; saving it does.

The footer shows your shards. It is only a count.

## Starters

*Insert starter…* replaces the text with a ready-made weapon (one Ctrl+Z
undoes it). Each has one number marked `<- tweak me`.

| Starter | What it does | Try |
|---|---|---|
| Straight | One shot along your aim. This is `default.lua` | `damage = 1` → `4` |
| Spread | Five shots in a fan | `-2, 2` → `-3, 3` |
| Spiral | Three arms that turn every shot | `0.22` → `0.5` |
| Split | A shot that hits bursts into pieces right where it hit, flying back out | `pieces = 3` → `5` |
| Homing | Shots curve toward the nearest enemy within 400 px, and fly straight when there is none | *locked* |

Homing is greyed out (*needs nearest_enemy*) until you earn the
`sense.nearest_enemy` Sense. Until then `sense.nearest_enemy` is `nil` in every
script, so code that checks for it first is always safe:

```lua
local nearest = sense.nearest_enemy
if nearest then
  -- ...
end
```

## Senses and the Codex

Senses let a script see enemies. You earn them by playing:

| Sense | How you earn it |
|---|---|
| `sense.nearest_enemy` | Three kills. The three practice dummies at the start count; the same dummy again does not |
| `sense.enemies_in` | Beat the Warden |

When you earn one, its name pops up at the bottom of the screen for a moment
(`sense.nearest_enemy`), the Homing starter unlocks, and the next time the
editor is open it shows that Sense's **Codex** page: a short explanation and a
weapon that uses it. *Insert snippet* puts it in the editor; save to fire it.
*Codex* in the top bar brings the pages back later.

In autocomplete a new Sense is listed first in yellow until you save a script
that uses it. Senses you have not earned yet are listed grey with how you get
them (`nearest_enemy  (3 kills)`, `enemies_in  (found at: ???)`).

Earned Senses are saved with your game. What they return is described in
[api.md](api.md#senses-in-this-build-vertical-slice): position, size, kind and
rarity of each enemy within 600 px, never its health or speed.

## Writing your own

A weapon file returns a table. The fields are defaults for every shot
(`cooldown`, `speed`, `damage`, `lifetime`, `radius`), and `on_fire(ctx)` runs
each time you pull the trigger:

```lua
return {
  name = "Twin",
  cooldown = 0.2,
  on_fire = function(ctx)
    spawn { angle = ctx.aim - 0.1, speed = 500, damage = 2 }
    spawn { angle = ctx.aim + 0.1, speed = 500, damage = 2 }
  end,
}
```

`spawn { ... }` takes `angle`, `speed`, `damage`, `lifetime`, `radius`, `spin`
(turn rate, rad/s), `accel` (px/s²) and `pos = { x = ..., y = ... }`. `ctx`
has `aim`, `aim_dir`, `pos`, `time`, `n` (the shot count), `pressed`,
`held_time` and `dt`. `TAU`, `PI` and `rad(degrees)` are there for angles.

Callbacks such as `on_hit(b, hit)` and `on_batch(v, dt)` in the same table run
for every shot the weapon fires. The full list is in [api.md](api.md).

## For lesson and mod authors

`ShotScripts` (a child of `Main`) has the signals a checker needs. None of
them parse Lua.

| Signal | When |
|---|---|
| `script_saved(file_name, origin)` | The **equipped** file was saved: in the editor (`origin` `&"editor"`) or changed on disk (`&"file"`, PC). Fires even when the save does not load. Other `shots/` files never fire it |
| `weapon_swapped(file_name, origin)` | The weapon now runs `file_name` (`&"start"`, `&"editor"` or `&"file"`) |
| `load_failed(file_name, problem, origin)` | `file_name` did not load; the previous weapon keeps firing |
| `unequipped_file_saved(file_name)` | A file that is not equipped changed on disk. A UI notice for the toast, rate-limited; not for checkers |
