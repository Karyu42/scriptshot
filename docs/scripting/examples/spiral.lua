-- spiral.lua: a rotating stream of shots that fans out into a spiral.
-- Uses: ctx, wait() inside on_fire, spawn, native straight-line motion.
-- Lua runs once per shot spawned; the flight itself is native.

return {
  name = "Spiral",
  cooldown = 1.2,

  on_fire = function(ctx)
    local arms  = 3                 -- spiral arms
    local count = 24                -- shots per arm
    local turn  = rad(9)            -- angle added per step
    local angle = ctx.aim

    for i = 1, count do
      for arm = 0, arms - 1 do
        spawn {
          pos      = ctx.pos,
          angle    = angle + arm * TAU / arms,
          speed    = 260,
          lifetime = 2.5,
          color    = "#ffd166",
        }
      end
      angle = angle + turn
      wait(0.03)                    -- yields; the game keeps running
    end
  end,
}
