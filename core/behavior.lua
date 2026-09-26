-- 表驱动行为状态机
-- view 接口：set_state(name) / move_to(x, y) / x, y, w, h 字段
-- opts：speed, margin, screen_w, screen_h, idle_anim, wait_min, wait_max, query_mouse()
local M = {}
M.__index = M

local function direction_from_delta(dx, dy)
  local ax, ay = math.abs(dx), math.abs(dy)
  if ax > ay * 2 then
    return dx > 0 and 'walk_east' or 'walk_west'
  end
  if ay > ax * 2 then
    return dy > 0 and 'walk_south' or 'walk_north'
  end
  if dx > 0 then
    return dy < 0 and 'walk_northeast' or 'walk_southeast'
  end
  return dy < 0 and 'walk_northwest' or 'walk_southwest'
end

-- 行为驱动器表：mode 名 -> tick(self, dt)；新增物种可注册自己的驱动器
M.drivers = {
  wander = function(self, dt)
    local v = self.view
    local dx, dy = self.tx - v.x, self.ty - v.y
    if dx * dx + dy * dy < 4 then
      if self.wait <= 0 then
        self.wait = self.o.wait_min + math.random(0, self.o.wait_max - self.o.wait_min)
        v:set_state(self.o.idle_anim)
      else
        self.wait = self.wait - dt
        if self.wait <= 0 then
          self:pick_destination()
        end
      end
      return
    end
    self:move_towards(self.tx, self.ty)
  end,

  chase = function(self, _dt)
    local mx, my = self.o.query_mouse()
    self:move_towards(mx, my)
  end,

  frozen = function(self, _dt)
    self.view:set_state(self.o.idle_anim)
  end,
}

function M.new(view, opts)
  local self = setmetatable({}, M)
  self.view = view
  self.o = opts
  self.mode = 'wander'
  self.prev_mode = nil
  self.dragging = false
  self.wait = 0
  self.tx, self.ty = view.x, view.y
  return self
end

function M:set_mode(mode)
  if not M.drivers[mode] or self.mode == mode then
    return
  end
  self.mode = mode
  if mode == 'chase' then
    self.view:set_state('walk_east')
    return
  end
  self:pick_destination()
  if mode == 'frozen' then
    self.view:set_state(self.o.idle_anim)
  end
end

function M:pick_destination()
  local v, m = self.view, self.o.margin
  local max_x = math.max(m, self.o.screen_w - m - v.w)
  local max_y = math.max(m, self.o.screen_h - m - v.h)
  self.tx = m + math.random(0, max_x - m)
  self.ty = m + math.random(0, max_y - m)
  self.wait = 0
end

function M:move_towards(tx, ty)
  local v = self.view
  local dx, dy = tx - v.x, ty - v.y
  local d2 = dx * dx + dy * dy
  if d2 < 4 then
    v:set_state(self.o.idle_anim)
    return true
  end
  v:set_state(direction_from_delta(dx, dy))
  local spd = self.o.speed
  if d2 <= spd * spd then
    v:move_to(tx, ty)
  else
    local len = math.sqrt(d2)
    v:move_to(v.x + dx / len * spd, v.y + dy / len * spd)
  end
  return false
end

function M:tick(dt)
  if self.dragging then
    return
  end
  local drv = M.drivers[self.mode] or M.drivers.wander
  drv(self, dt)
end

function M:reset()
  self.wait = 0
  self:pick_destination()
end

return M
