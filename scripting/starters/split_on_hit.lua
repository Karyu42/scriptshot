-- Split: a shot that hits bursts into pieces flying back out.
return {
  name = "Split",
  cooldown = 0.40,
  on_fire = function(ctx) spawn { angle = ctx.aim, speed = 420, damage = 3 } end,
  on_hit = function(b, hit)
    local pieces = 3  -- <- tweak me: how many pieces
    local away = math.atan(-b.vy, -b.vx)  -- back the way the shot came
    for i = 1, pieces do
      local a = away + (i - (pieces + 1) / 2) * rad(50) / pieces
      b:spawn_child(hit.x + math.cos(a) * 16, hit.y + math.sin(a) * 16, math.cos(a) * 280, math.sin(a) * 280, 1.2)
    end
  end,
}
