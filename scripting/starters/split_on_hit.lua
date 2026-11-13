-- Split: when a shot hits, it bursts into pieces right where it hit.
return {
  name = "Split",
  cooldown = 0.40,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 420, damage = 3 }
  end,
  on_hit = function(b, hit)
    local pieces = 3  -- <- tweak me: how many pieces
    local back = math.atan(-b.vy, -b.vx)  -- fly back the way the shot came
    for i = 1, pieces do
      local a = back + (i - (pieces + 1) / 2) * 0.4
      b:spawn_child(hit.x, hit.y, math.cos(a) * 280, math.sin(a) * 280, 1.2)
    end
  end,
}
