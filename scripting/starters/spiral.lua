-- Spiral: three arms that turn a little more every shot.
local t = 0
return {
  name = "Spiral",
  cooldown = 0.08,
  on_fire = function(ctx)
    t = t + 0.22  -- <- tweak me: how far the arms turn per shot
    for arm = 0, 2 do
      spawn { angle = ctx.aim + t + arm * (TAU / 3), speed = 340, damage = 2 }
    end
  end,
}
