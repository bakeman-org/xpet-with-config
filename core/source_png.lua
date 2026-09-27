-- PNG/GIF 宠物素材后端（纯 Lua 解码，无 stb/C/libz 依赖）
-- PNG：core/pngload.lua（纯 Lua 含 inflate）
-- GIF：core/gifload.lua（love2d 同款 LuaJIT+FFI 流式解码器）
-- 目录布局与 XPM 后端不同：pet_asset_dir 直接指向单个 .gif 文件，
-- 或指向编号 PNG 帧目录（01.png ~ 99.png）；只有一个动画，状态全部回退 idle
local M = {}
local ffi = require('ffi')
local bit = require('bit')
local Util = require('core.util')

local file_exists = Util.file_exists

local function shquote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ─── PNG 解码（core/pngload.lua，仅支持非隔行 + 8/16 位 + ctype 0/2/4/6） ───
local pngload = require('core.pngload')

local function png_to_rgba(img)
  local w, h = img.width, img.height
  local ch, ps = img.channels, img.bit_depth / 8
  local out = ffi.new('unsigned char[?]', w * h * 4)
  local next_scanline = pngload.scanlines(img)
  for y = 0, h - 1 do
    local row = next_scanline()
    local base = y * w * 4
    for x = 0, w - 1 do
      local i = x * ch * ps + 1
      local o = base + x * 4
      local r, g, b, a
      if img.color_type == 6 then
        r, g, b, a = row:byte(i), row:byte(i + ps), row:byte(i + 2 * ps), row:byte(i + 3 * ps)
      elseif img.color_type == 2 then
        r, g, b = row:byte(i), row:byte(i + ps), row:byte(i + 2 * ps)
      elseif img.color_type == 4 then
        r, a = row:byte(i), row:byte(i + ps)
        g, b = r, r
      else
        r = row:byte(i)
        g, b = r, r
      end
      out[o] = r or 0
      out[o + 1] = g or 0
      out[o + 2] = b or 0
      out[o + 3] = a or 255
    end
  end
  return w, h, out
end

local function decode_png_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  local ok, img = pcall(pngload.load, data)
  if not ok or not img.width or img.width == 0 or img.height == 0 then
    return nil
  end
  return png_to_rgba(img)
end

-- ─── GIF 解码（core/gifload.lua，love2d 同款 LuaJIT+FFI 流式解码器） ───
local gifnew = require('core.gifload')

local function decode_gif_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  if #data < 14 or data:sub(1, 3) ~= 'GIF' then return nil end
  local g = gifnew()
  for i = 1, #data, 32768 do
    g:update(data:sub(i, math.min(i + 32767, #data)))
  end
  g:update('\0') -- 末尾补字节，让解码器能读到 trailer
  g:done()
  if g.ncomplete == 0 or not g.width or g.width == 0 or g.height == 0 then
    return nil
  end
  -- 合成整画布 RGBA 帧序列（帧透明像素 alpha=0，由 gifload 调色板清零）
  local sw, sh = g.width, g.height
  local canvas = ffi.new('unsigned char[?]', sw * sh * 4)
  local out = {}
  for i = 1, g.ncomplete do
    local img, x, y, fw, fh, _, dispose = g:frame(i)
    for py = 0, fh - 1 do
      local cy = y + py
      if cy >= 0 and cy < sh then
        for px = 0, fw - 1 do
          local cx = x + px
          if cx >= 0 and cx < sw then
            local o = (py * fw + px) * 4
            if img[o + 3] ~= 0 then
              local p = (cy * sw + cx) * 4
              canvas[p] = img[o]
              canvas[p + 1] = img[o + 1]
              canvas[p + 2] = img[o + 2]
              canvas[p + 3] = 255
            end
          end
        end
      end
    end
    out[#out + 1] = ffi.string(canvas, sw * sh * 4)
    if dispose == 2 then -- 还原为透明背景
      for py = y, math.min(y + fh, sh) - 1 do
        for px = x, math.min(x + fw, sw) - 1 do
          canvas[(py * sw + px) * 4 + 3] = 0
        end
      end
    end
  end
  return sw, sh, out
end

-- ─── RGBA → X pixmap/mask ───
local function rgba_buf(rgba)
  if type(rgba) == 'string' then
    return ffi.new('unsigned char[?]', #rgba, rgba)
  end
  return rgba -- 已是 FFI buffer（PNG 路径）
end

-- RGBA -> A1 位图数据（掩码），行按字节对齐，x86 LSBFirst
local function build_mask_bits(rgba, w, h)
  local row_bytes = math.floor((w + 7) / 8)
  local buf = ffi.new('unsigned char[?]', row_bytes * h)
  for y = 0, h - 1 do
    local row = y * row_bytes
    local src = y * w * 4
    for x = 0, w - 1 do
      if rgba[src + x * 4 + 3] >= 128 then
        buf[row + math.floor(x / 8)] = bit.bor(buf[row + math.floor(x / 8)], bit.lshift(1, x % 8))
      end
    end
  end
  return buf, row_bytes
end

-- RGBA -> ZPixmap 数据（depth 24，x86 小端 BGRX）
local function build_zpix_bits(rgba, w, h)
  local buf = ffi.new('unsigned char[?]', w * h * 4)
  local n = w * h
  for i = 0, n - 1 do
    local j = i * 4
    buf[j] = rgba[j + 2]
    buf[j + 1] = rgba[j + 1]
    buf[j + 2] = rgba[j]
    buf[j + 3] = 0
  end
  return buf
end

local function rgba_to_frame(ctx, rgba, w, h)
  local X11, dpy, root = ctx.X11, ctx.dpy, ctx.root
  local pix = X11.XCreatePixmap(dpy, root, w, h, ctx.depth)
  local gc = X11.XCreateGC(dpy, pix, 0, nil)

  local zbuf = build_zpix_bits(rgba, w, h)
  local visual = X11.XDefaultVisual(dpy, X11.XDefaultScreen(dpy))
  local zimg = X11.XCreateImage(dpy, visual, ctx.depth, 2, 0, zbuf, w, h, 32, 0)
  if zimg == nil then
    X11.XFreeGC(dpy, gc)
    X11.XFreePixmap(dpy, pix)
    return nil
  end
  X11.XPutImage(dpy, pix, gc, zimg, 0, 0, 0, 0, w, h)
  ctx.FT.surf_ximg_detach(zimg) -- 数据由 LuaJIT GC 持有，防止 XDestroyImage 释放
  X11.XDestroyImage(zimg)

  local mask_bits = build_mask_bits(rgba, w, h)
  local mask = X11.XCreateBitmapFromData(dpy, root, mask_bits, w, h)

  X11.XFreeGC(dpy, gc)
  return { pix = pix, mask = mask, w = w, h = h }
end

-- RGBA 最近邻重采样到 sw×sh（支持任意小数放大/缩小）
local function resample_rgba(rgba, w, h, sw, sh)
  local out = ffi.new('unsigned char[?]', sw * sh * 4)
  for y = 0, sh - 1 do
    local sy = math.min(h - 1, math.floor(y * h / sh))
    local srow = sy * w * 4
    local drow = y * sw * 4
    for x = 0, sw - 1 do
      local sx = math.min(w - 1, math.floor(x * w / sw))
      local s = srow + sx * 4
      local d = drow + x * 4
      out[d] = rgba[s]
      out[d + 1] = rgba[s + 1]
      out[d + 2] = rgba[s + 2]
      out[d + 3] = rgba[s + 3]
    end
  end
  return out
end

local function frame_from_rgba(ctx, rgba, w, h, scale)
  scale = tonumber(scale) or 1
  if scale <= 0 then
    scale = 1
  end
  if math.abs(scale - 1) < 0.001 then
    return rgba_to_frame(ctx, rgba, w, h)
  end
  local sw = math.max(1, math.floor(w * scale + 0.5))
  local sh = math.max(1, math.floor(h * scale + 0.5))
  if sw == w and sh == h then
    return rgba_to_frame(ctx, rgba, w, h)
  end
  return rgba_to_frame(ctx, resample_rgba(rgba, w, h, sw, sh), sw, sh)
end

-- 小帧衬到大画布（底部居中，脚踩地面），保证所有帧同尺寸
local function pad_to_canvas(buf, w, h, cw, ch)
  if w == cw and h == ch then
    return buf
  end
  local out = ffi.new('unsigned char[?]', cw * ch * 4)
  local ox = math.floor((cw - w) / 2)
  local oy = ch - h
  for y = 0, h - 1 do
    ffi.copy(out + ((y + oy) * cw + ox) * 4, buf + y * w * 4, w * 4)
  end
  return out
end

local function load_gif_frames(ctx, path, scale)
  local w, h, frames = decode_gif_file(path)
  if not w then
    ctx.log('gif decode failed: %s', path)
    return {}
  end
  local out = {}
  for _, rgba in ipairs(frames) do
    local fr = frame_from_rgba(ctx, rgba_buf(rgba), w, h, scale)
    if fr then
      out[#out + 1] = fr
    end
  end
  return out
end

-- 列出目录下按数字编号的 PNG 帧（01.png ~ 99.png，容忍 1.png / 跳号）
local function list_numbered_pngs(dir)
  local files = {}
  local p = io.popen(string.format('ls -1 %s 2>/dev/null', shquote(dir)))
  if p then
    for line in p:lines() do
      local n = line:match('^(%d+)%.png$')
      if n then
        files[#files + 1] = { n = tonumber(n), name = line }
      end
    end
    p:close()
  end
  table.sort(files, function(a, b)
    return a.n < b.n
  end)
  return files
end

-- pet_asset_dir 二选一：单个 .gif 文件，或编号 PNG 帧目录
function M.load(ctx, cfg)
  local path = cfg.pet_asset_dir
  if not path or not file_exists(path) then
    error('pet asset not found: ' .. tostring(path))
  end
  local scale = cfg.scale_factor or 1
  local frames = {}
  if path:sub(-4):lower() == '.gif' then
    frames = load_gif_frames(ctx, path, scale)
  else
    local files = list_numbered_pngs(path)
    if #files == 0 then
      error('no numbered png frames (01.png ~ 99.png) found in: ' .. path)
    end
    -- 两遍：先解码求最大画布，再把每帧底部居中衬到同一尺寸（窗口不裁切）
    local decoded, cw, ch = {}, 0, 0
    for _, f in ipairs(files) do
      local w, h, rgba = decode_png_file(path .. '/' .. f.name)
      if w then
        decoded[#decoded + 1] = { rgba = rgba_buf(rgba), w = w, h = h }
        if w > cw then
          cw = w
        end
        if h > ch then
          ch = h
        end
      else
        ctx.log('png decode failed: %s/%s', path, f.name)
      end
    end
    if #decoded == 0 then
      error('all png frames failed to decode in: ' .. path)
    end
    for _, d in ipairs(decoded) do
      local fr = frame_from_rgba(ctx, pad_to_canvas(d.rgba, d.w, d.h, cw, ch), cw, ch, scale)
      if fr then
        frames[#frames + 1] = fr
      end
    end
  end
  return { idle = frames }
end

M.decode_png = decode_png_file -- 供 tools/check_asset.lua 自检用
M.decode_gif = decode_gif_file

local PetSource = require('core.pet_source')
PetSource.register('png', M)

return M
