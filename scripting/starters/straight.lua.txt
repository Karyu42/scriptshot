-- Straight: one shot along your aim, every `cooldown` seconds.
-- Save (Ctrl+S) and the next shot uses your numbers.
return {
  name = "Straight",
  cooldown = 0.25,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 480, damage = 1 }  -- <- tweak me: damage
  end,
}
