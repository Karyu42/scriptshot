-- split_on_hit.lua: a shot that splits into a fan of smaller shots when it hits.
-- Children can split once more (generation-limited), so one hit becomes up to 1 + 5 + 25 shots.
-- Uses: on_hit, b:split, b.generation.
-- Engine status: needs nothing beyond the spawn fields that exist today, plus hit.normal (derived natively from
-- the impact point and the hurtbox centre; see api.md, "Hits").
--
-- Children must not be born inside the hurtbox they are leaving, or the very next swept test hits it again
-- (the pool only remembers the last target for *piercing* bullets). So the fan is centred on the surface
-- normal (away from the target) and its origin is pushed out of the target along that normal.

local MAX_GENERATION = 2

local function make_shot(extra)
  local def = {
    speed    = 360,
    damage   = 3,
    radius   = 6,
    lifetime = 2,
    color    = "#4cc9f0",
    on_hit = function(b, hit)
      if b.generation >= MAX_GENERATION then return end
      local away = hit.normal                                   -- unit vec2, points out of the target
      b:split(5, {
        pos      = hit.pos + away * (b.radius + 4),              -- start outside the hurtbox
        center   = away:angle(),                                 -- fan around "away", not around the old heading
        spread   = rad(120),
        speed    = "x0.9",
        damage   = "x0.5",
        radius   = "x0.7",
        lifetime = 1.0,
        inherit  = true,           -- children get this same on_hit, so they split too
      })
    end,
  }
  for k, v in pairs(extra or {}) do def[k] = v end
  return def
end

return {
  name = "Splitter",
  cooldown = 0.4,

  on_fire = function(ctx)
    spawn(make_shot { pos = ctx.pos, angle = ctx.aim })
  end,
}
