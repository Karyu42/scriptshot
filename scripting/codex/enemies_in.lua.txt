-- sense.enemies_in(pos, r)  · earned: the Warden
-- Gives every enemy within r of pos, nearest first: a list you can loop over.
--   r      up to 600 px (a bigger r counts as 600)
-- Each entry is the same as sense.nearest_enemy's: e.pos.x, e.pos.y,
-- e.radius, e.kind, e.rarity, e.id and e:alive(). No speed, no hp.
-- The closest body is not always the one you want. Here the shots skip
-- the husks and push toward the Warden itself (e.kind == "warden").
-- Insert this snippet, save, and fire near the Warden's ring.
-- Level II (later, not in this build) adds speed and hp and lifts the
-- 600 px limit.

-- Warden seeker: shots push toward the Warden, not the nearest husk.
-- needs: sense.enemies_in
return {
  name = "Warden seeker",
  cooldown = 0.45,
  on_fire = function(ctx)
    spawn { angle = ctx.aim, speed = 280, damage = 4, lifetime = 2.5 }
  end,
  on_batch = function(v, dt)
    local query = sense.enemies_in  -- nil until you earn it
    if not query or v.n == 0 then return end
    -- One look per batch (from the first shot), not one per shot.
    local core = nil
    for _, e in ipairs(query({ x = v.px[0], y = v.py[0] }, 600)) do
      if e.kind == "warden" then core = e break end
    end
    if not core then return end
    for i = 0, v.n - 1 do
      local dx, dy = core.pos.x - v.px[i], core.pos.y - v.py[i]
      v.vx[i], v.vy[i] = v.vx[i] + dx * dt, v.vy[i] + dy * dt  -- <- tweak me: dt * 2 turns harder
    end
  end,
}
