-- Spread: five shots in a fan, one aim.
return {
  name = "Spread",
  cooldown = 0.30,
  on_fire = function(ctx)
    for i = -2, 2 do  -- <- tweak me: -3, 3 for seven shots
      spawn { angle = ctx.aim + i * 0.16, speed = 460, damage = 2 }
    end
  end,
}
