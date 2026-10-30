-- steer.lua: Scripting Engineer's spike script (PR #3, docs/scripting/spike/sandbox/steer.lua at b3a407f), copied verbatim apart from this line.
local M = {}
local dt = 1 / 60
local sin, cos, atan = math.sin, math.cos, math.atan
local function steer(vx, vy, age, pa)
  local a = 1.5 * sin(age * 4 + pa) * dt
  local c, s = cos(a), sin(a)
  return vx * c - vy * s, vx * s + vy * c
end
function M.on_update(i, x, y, vx, vy, age, pa)
  local nvx, nvy = steer(vx, vy, age, pa)
  set_vel(i, nvx, nvy)
  if i % 16 == 0 and age % 0.5 < dt then defer_spawn(x, y, atan(nvy, nvx) + 3.14159, 40) end
end
function M.on_update_batch(ids, pos, vel, age, pa, n, delta, out_vel, cmds)
  local nc = 0
  for k = 0, n - 1 do
    local vx, vy = vel[2 * k], vel[2 * k + 1]
    local nvx, nvy = steer(vx, vy, age[k], pa[k])
    out_vel[2 * k] = nvx; out_vel[2 * k + 1] = nvy
    if ids[k] % 16 == 0 and age[k] % 0.5 < dt then
      local o = 4 * nc
      cmds[o] = pos[2 * k]; cmds[o + 1] = pos[2 * k + 1]; cmds[o + 2] = atan(nvy, nvx) + 3.14159; cmds[o + 3] = 40
      nc = nc + 1
    end
  end
  return out_vel, cmds, nc
end
return M
