-- Web smoke shot (src/qa/web_smoke.gd). Bends the bullet and splits off one
-- declarative child, so a passing run proves Lua ran through ScriptHost.
return {
  on_spawn = function(b)
    b:set_velocity(180, -30)
    b:spawn_child(b.x + 6, b.y, 0, 160, 1.5)
  end,
}
