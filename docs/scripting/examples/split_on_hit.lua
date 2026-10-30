-- split_on_hit.lua: a shot that splits into a fan of smaller shots when it hits.
-- Children can split once more (generation-limited), so one hit becomes up to 1 + 5 + 25 shots.
-- Uses: on_hit, b:split, b.generation, tags.

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
      b:split(5, {
        pos      = hit.pos,
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
