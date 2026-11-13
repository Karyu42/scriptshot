-- sense.nearest_enemy(pos, range)  · earned: 3 kills
-- Gives the enemy whose centre is closest to pos, or nil.
--   pos    a table with x and y, like { x = v.px[i], y = v.py[i] }
--   range  how far to look, in px (600 when you leave it out)
-- What you get back (read-only):
--   e.pos.x, e.pos.y   where it is      e.radius   how big it is
--   e.kind             "drifter", "husk", "dummy", ...
--   e.id               the same number for as long as it lives
--   e:alive()          false once it has died
-- Before you earn it, sense.nearest_enemy is nil, so check first.
-- Insert this snippet, save, and your shots curve toward the nearest enemy.

-- Homing: shots steer toward the nearest enemy.
-- needs: sense.nearest_enemy
return {
  name = "Homing",
  cooldown = 0.45,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 280, damage = 4, lifetime = 2.5 }
  end,
  on_batch = function(v, dt)
    local nearest = sense.nearest_enemy  -- nil until you earn it
    if not nearest then return end
    local pull = 900  -- <- tweak me: how hard shots turn
    for i = 0, v.n - 1 do
      local e = nearest({ x = v.px[i], y = v.py[i] }, 400)
      if e then
        local dx, dy = e.pos.x - v.px[i], e.pos.y - v.py[i]
        local d = math.sqrt(dx * dx + dy * dy) + 1
        v.vx[i], v.vy[i] = v.vx[i] + dx / d * pull * dt, v.vy[i] + dy / d * pull * dt
      end
    end
  end,
}
