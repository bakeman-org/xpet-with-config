-- PetSource：宠物素材后端注册表
-- 接口约定：backend.load(ctx, cfg) -> anims
--   anims = { [state_name] = { {pix=, mask=, w=, h=}, ... }, idle = {...} }
--   pix/mask 为 X11 Pixmap（渲染层直接可用）；未来 PNG/GIF 后端返回同构数据即可。
local M = {}
M.registry = {}

local ffi = require('ffi')
local bit = require('bit')
local Util = require('core.util')

local file_exists = Util.file_exists

function M.register(name, backend)
  M.registry[name] = backend
end

function M.load(ctx, cfg)
  local kind = cfg.pet_source or 'xpm'
  local backend = M.registry[kind]
  if not backend then
    error('unknown pet_source: ' .. tostring(kind))
  end
  return backend.load(ctx, cfg)
end

local function shquote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ─── XPM 后端 ─────────────────────────────────────────────
-- 目录布局：pet_asset_dir/<state>/<n>.xpm（子目录名即状态名）
-- 也支持平铺布局：pet_asset_dir/<n>.xpm（整体作为 idle）
local Xpm = {}

local function list_states(dir)
  local states = {}
  local p = io.popen(string.format('ls -1 %s 2>/dev/null', shquote(dir)))
  if p then
    for line in p:lines() do
      if file_exists(dir .. '/' .. line .. '/0.xpm') then
        states[#states + 1] = line
      end
    end
    p:close()
  end
  return states
end

local function scale_drawable(ctx, src, sw, sh, scale, dest_depth, get_pixel)
  local X11, dpy, root = ctx.X11, ctx.dpy, ctx.root
  local dw, dh = sw * scale, sh * scale
  local dest = X11.XCreatePixmap(dpy, root, dw, dh, dest_depth)
  local gc = X11.XCreateGC(dpy, dest, 0, nil)
  local img = X11.XGetImage(dpy, src, 0, 0, sw, sh, 0xFFFFFFFF, 2)
  if img ~= nil then
    for yy = 0, sh - 1 do
      for xx = 0, sw - 1 do
        X11.XSetForeground(dpy, gc, get_pixel(img, xx, yy))
        X11.XFillRectangle(dpy, dest, gc, xx * scale, yy * scale, scale, scale)
      end
    end
    X11.XDestroyImage(img)
  end
  X11.XFreeGC(dpy, gc)
  return dest
end

local function load_frames(ctx, dir, scale)
  local X11, dpy, root = ctx.X11, ctx.dpy, ctx.root
  local XpmLib = ctx.Xpm
  local frames = {}
  local i = 0
  while true do
    local path = string.format('%s/%d.xpm', dir, i)
    if not file_exists(path) then
      break
    end
    local pix_out = ffi.new('Pixmap[1]')
    local mask_out = ffi.new('Pixmap[1]')
    local rc = XpmLib.XpmReadFileToPixmap(dpy, root, path, pix_out, mask_out, nil)
    if rc ~= 0 then
      ctx.log('XPM read failed: %s (rc=%d)', path, rc)
      break
    end
    local src_pix, src_mask = pix_out[0], mask_out[0]
    local root_ret = ffi.new('Window[1]')
    local xi, yi = ffi.new('int[1]'), ffi.new('int[1]')
    local ww, hh = ffi.new('unsigned int[1]'), ffi.new('unsigned int[1]')
    local bw_, dd_ = ffi.new('unsigned int[1]'), ffi.new('unsigned int[1]')
    X11.XGetGeometry(dpy, src_pix, root_ret, xi, yi, ww, hh, bw_, dd_)
    local sw, sh = ww[0], hh[0]
    if scale > 1 then
      local sp = scale_drawable(ctx, src_pix, sw, sh, scale, ctx.depth, X11.XGetPixel)
      local sm = scale_drawable(ctx, src_mask, sw, sh, scale, 1, function(img, xx, yy)
        return bit.band(X11.XGetPixel(img, xx, yy), 1)
      end)
      X11.XFreePixmap(dpy, src_pix)
      X11.XFreePixmap(dpy, src_mask)
      frames[#frames + 1] = { pix = sp, mask = sm, w = sw * scale, h = sh * scale }
    else
      frames[#frames + 1] = { pix = src_pix, mask = src_mask, w = sw, h = sh }
    end
    i = i + 1
  end
  return frames
end

function Xpm.load(ctx, cfg)
  local dir = cfg.pet_asset_dir
  if not dir or not file_exists(dir) then
    error('pet asset dir not found: ' .. tostring(dir))
  end
  local scale = cfg.scale_factor or 1
  local anims = {}
  local states = list_states(dir)
  if #states > 0 then
    for _, name in ipairs(states) do
      local frames = load_frames(ctx, dir .. '/' .. name, scale)
      if #frames > 0 then
        anims[name] = frames
      end
    end
  else
    local frames = load_frames(ctx, dir, scale)
    if #frames > 0 then
      anims.idle = frames
    end
  end
  if not anims.idle then
    for _, frames in pairs(anims) do
      anims.idle = frames
      break
    end
  end
  return anims
end

M.register('xpm', Xpm)

return M
