-- homing.lua: slow-launching shots that accelerate and home on the nearest enemy.
-- Uses: native homing (no per-frame Lua), accel, on_death.

return {
  name = "Seeker",
  cooldown = 0.5,

  on_fire = function(ctx)
    for i = -1, 1 do
      spawn {
        pos      = ctx.pos,
        angle    = ctx.aim + i * rad(25),   -- three-way launch
        speed    = 120,
        accel    = 300,                     -- speed up along heading
        max_speed = 420,
        lifetime = 4,
        damage   = 2,
        homing   = {
          range    = 350,
          turn     = 3.5,                   -- rad/s
          target   = "nearest",
          retarget = 0.2,
        },
        on_death = function(b, why)
          if why == "expire" then flash("#ff6b6b") end   -- a miss feels like a miss
        end,
      }
    end
  end,
}
