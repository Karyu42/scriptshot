-- spawner.lua: a slow "mother" shot that periodically drops homing seeds, and bursts when it dies.
-- Uses: b:every, b:spawn (child shots), per-shot state, on_death.
-- Engine status: `homing` has no native equivalent yet (api.md, "Spawn fields -> engine mapping"); until it lands the
-- seeds fly straight (the field is accepted and ignored with a one-time console note).

local function seed_def(angle)
  return {
    angle    = angle,
    speed    = 220,
    damage   = 1,
    radius   = 3,
    lifetime = 2.5,
    color    = "#80ed99",
    homing   = { range = 250, turn = 5, target = "nearest" },
  }
end

return {
  name = "Spawner",
  cooldown = 1.5,

  on_fire = function(ctx)
    spawn {
      pos      = ctx.pos,
      angle    = ctx.aim,
      speed    = 90,
      damage   = 0,               -- the mother is harmless; her children are the damage
      radius   = 8,
      lifetime = 4,
      color    = "#38a3a5",
      state    = { drops = 0 },

      on_spawn = function(b)
        b:every(0.25, function(b)
          b.state.drops = b.state.drops + 1
          -- alternate left / right of the heading
          local side = (b.state.drops % 2 == 0) and 1 or -1
          b:spawn(seed_def(b.angle + side * PI / 2))
        end)
      end,

      on_death = function(b, why)
        -- why is a despawn reason: "lifetime", "bounds", "hit", "manual", "cleared", "wall".
        -- Skip the final burst when the shot was removed by a global clear (e.g. a respawn wiping the arena).
        if why == "cleared" then return end
        b:split(8, { spread = TAU, speed = 200, damage = 1, lifetime = 1.5, homing = { range = 200, turn = 4 } })
      end,
    }
  end,
}
