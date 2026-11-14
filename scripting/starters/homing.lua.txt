-- Homing: shots steer toward the nearest enemy.
-- needs: sense.nearest_enemy
return {
  name = "Homing",
  cooldown = 0.45,
  on_fire = function(ctx) spawn { angle = ctx.aim, speed = 280, damage = 4, lifetime = 2.5 } end,
  on_batch = function(v, dt)
    local nearest = sense.nearest_enemy  -- nil until you earn it
    if not nearest then return end
    local pull = 1800  -- <- tweak me: how hard shots turn
    for i = 0, v.n - 1 do
      local e = nearest({ x = v.px[i], y = v.py[i] }, 400)
      if e then
        local dx, dy = e.pos.x - v.px[i], e.pos.y - v.py[i]
        local f = pull * dt / (math.sqrt(dx * dx + dy * dy) + 1)
        local vx, vy = v.vx[i] + dx * f, v.vy[i] + dy * f
        local k = math.sqrt((v.vx[i] ^ 2 + v.vy[i] ^ 2) / (vx * vx + vy * vy + 1e-9))  -- keep the speed
        v.vx[i], v.vy[i] = vx * k, vy * k
      end
    end
  end,
}
