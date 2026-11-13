-- Spiral: three arms that turn a little more every shot.
-- `state` keeps the angle across saves, so a save does not snap it back.
state.t = state.t or 0
return {
  name = "Spiral",
  cooldown = 0.08,
  on_fire = function(ctx)
    state.t = (state.t + 0.22) % TAU  -- <- tweak me: how far the arms turn per shot
    for arm = 0, 2 do
      spawn { angle = ctx.aim + state.t + arm * (TAU / 3), speed = 340, damage = 2 }
    end
  end,
}
