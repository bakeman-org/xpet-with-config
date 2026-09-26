local M = {}
local Surface = require('core.surface')

M.theme = {
  bg = 0x141218,
  surface = 0x1d1b20,
  surface_hi = 0x2b2930,
  surface_hover = 0x3b383e,
  primary = 0xd0bcff,
  primary_hi = 0xe3d5ff,
  on_primary = 0x381e72,
  secondary_ctr = 0x4a4458,
  on_surface = 0xe6e1e5,
  on_var = 0xcac4d0,
  outline = 0x49454f,
  green = 0xb5ccb5,
  red = 0xf2b8b5,
}

local UI = {}
UI.__index = UI

function M.new(ctx, override)
  local self = setmetatable({}, UI)
  self.ctx = ctx
  self.theme = setmetatable(override or {}, {
    __index = M.theme,
  })
  self.surface = nil
  self.mx, self.my = -1, -1
  self.mdown = false
  self.mrelease = nil
  self.active_id = nil
  return self
end

function UI:attach(surface)
  self.surface = surface
end

function UI:on_event(t, ev)
  if t == 6 then
    self.mx, self.my = ev.xmotion.x, ev.xmotion.y
  elseif t == 4 and ev.xbutton.button == 1 then
    self.mx, self.my = ev.xbutton.x, ev.xbutton.y
    self.mdown = true
  elseif t == 5 and ev.xbutton.button == 1 then
    self.mdown = false
    self.mrelease = {
      x = self.mx,
      y = self.my,
    }
  end
end

function UI:begin()
  if not self.mdown then
    self.active_id = nil
  end
end
function UI:end_frame()
  self.mrelease = nil
end

function UI:hover(x, y, w, h)
  return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h
end

function UI:clicked(x, y, w, h)
  if not self.mrelease then
    return false
  end
  local r = self.mrelease
  return r.x >= x and r.x < x + w and r.y >= y and r.y < y + h
end

function UI:label(x, y_top, text, color, bg)
  if bg then
    self.surface:rect(
      x - 2,
      y_top - 2,
      select(1, self.ctx.get_text_size(text)) + 4,
      self.ctx.get_line_height() + 4,
      bg
    )
  end
  self.surface:text(x, y_top, text, color or self.theme.on_surface)
end

-- 建议的行高：主字体视觉高度 + 一点点 leading
function UI:line_h(pad)
  return self.ctx.get_primary_line_height() + (pad or 6)
end

function UI:label_c(x, y_top, w, text, color, bg)
  if bg then
    self.surface:rect(x, y_top - 2, w, self.ctx.get_line_height() + 4, bg) -- 背景条还是用 max lh，够高就行
  end
  local tw = select(1, self.ctx.get_text_size(text))
  self.surface:text(math.floor(x + w / 2 - tw / 2), y_top, text, color or self.theme.on_surface)
end

function UI:id_button(id, x, y, w, h, text, opts)
  opts = opts or {}
  local T = self.theme
  local hover = self:hover(x, y, w, h)
  local bg, fg
  if opts.filled then
    bg = hover and T.primary_hi or T.primary
    fg = T.on_primary
  elseif opts.tonal then
    bg = hover and T.surface_hover or T.secondary_ctr
    fg = T.primary
  else
    bg = hover and T.surface_hover or (opts.bg or T.surface_hi)
    fg = opts.color or T.on_surface
  end
  local r = opts.radius or math.floor(h / 2)
  self.surface:rrect(x, y, w, h, r, bg)
  local lh = self.ctx.get_primary_line_height()
  local tw = select(1, self.ctx.get_text_size(text))
  self.surface:text(math.floor(x + w / 2 - tw / 2), math.floor(y + h / 2 - lh / 2), text, fg)
  return self:clicked(x, y, w, h)
end

function UI:button(x, y, w, h, text, opts)
  return self:id_button('btn:' .. x .. ':' .. y .. ':' .. text, x, y, w, h, text, opts)
end

function UI:slider(id, x, y, w, value, opts)
  opts = opts or {}
  local T = self.theme
  local min_v, max_v = opts.min or 0, opts.max or 1
  local norm = math.max(0, math.min(1, (value - min_v) / (max_v - min_v)))
  local hit_r = opts.hit_r or 14

  local over = self.mx >= x - hit_r
    and self.mx <= x + w + hit_r
    and self.my >= y - hit_r
    and self.my <= y + hit_r
  if self.mdown and over and not self.active_id then
    self.active_id = id
  end

  local new_v = value
  if self.active_id == id then
    local px = math.max(x, math.min(x + w, self.mx))
    new_v = min_v + (px - x) / w * (max_v - min_v)
  end

  self.surface:rrect(x, y, w, 6, 3, opts.track or T.surface_hi)
  local fw = math.max(6, math.floor(w * norm))
  self.surface:rrect(x, y, fw, 6, 3, opts.color or T.primary)
  local hx = x + math.floor(w * norm)
  self.surface:rrect(hx - 8, y - 5, 16, 16, 8, opts.handle or T.on_surface)

  return new_v, new_v ~= value
end

function UI:toggle(id, x, y, w, h, value, opts)
  opts = opts or {}
  local T = self.theme
  local bg = value and (opts.on_color or T.primary) or T.surface_hi
  self.surface:rrect(x, y, w, h, h / 2, bg)
  local knob = h - 8
  local kx = value and (x + w - knob - 4) or (x + 4)
  self.surface:rrect(
    kx,
    y + 4,
    knob,
    knob,
    knob / 2,
    opts.knob or (value and T.on_primary or T.on_var)
  )
  if self:clicked(x, y, w, h) then
    return not value, true
  end
  return value, false
end

function UI:card(x, y, w, h, opts)
  opts = opts or {}
  local r = opts.radius or 16
  self.surface:rrect(x, y, w, h, r, opts.bg or self.theme.surface)
end

function UI:divider(x, y, w, color)
  self.surface:rect(x, y, w, 1, color or self.theme.outline)
end

-- 焦点状态（UI 实例级）
function UI:focus_input(id)
  self._focus_id = id
end
function UI:blur_input()
  self._focus_id = nil
end
function UI:has_focus(id)
  return self._focus_id == id
end

-- 渲染一个输入框，返回本次是否被点击（调用方可据此 grab 键盘）
function UI:text_field(id, x, y, w, h, value, opts)
  opts = opts or {}
  local T = self.theme
  local hover = self:hover(x, y, w, h)
  local focused = self:has_focus(id)

  local clicked = self:clicked(x, y, w, h)
  if clicked then
    self._focus_id = id
    focused = true
  end

  local bg = focused and T.surface_hi or (hover and T.surface_hover or T.surface)
  local r = opts.radius or math.floor(h / 2)
  self.surface:rrect(x, y, w, h, r, bg)

  if focused then
    -- 简单两条边模拟 outline
    self.surface:rect(x + r, y, w - 2 * r, 1, T.primary)
    self.surface:rect(x + r, y + h - 1, w - 2 * r, 1, T.primary)
  end

  local lh = self.ctx.get_primary_line_height()
  local ty = y + math.floor((h - lh) / 2)
  local text = value or ''
  local fg
  if text == '' and opts.placeholder then
    text = opts.placeholder
    fg = T.outline
  else
    fg = focused and T.on_surface or T.on_var
  end
  if focused then
    text = text .. '▏'
  end

  self.surface:text(x + 12, ty, text, fg)
  return clicked
end

return M
