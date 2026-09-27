-- 全屏截图取色：点「取色」→ grim 截全屏 → 全屏覆盖窗显示截图，
-- 放大镜跟随鼠标实时预览，左键取色复制，Esc/右键取消
-- （XWayland root 无 backing store，XGetImage 不可用；颜色全部从 grim 的
--   PPM 数据里直接查表，不再逐点起子进程采样）
local M = {}
local bit = require('bit') -- luacheck: ignore  (预留)
local Panel = require('core.panel')
local Canvas = require('core.canvas')
local Surface = require('core.surface')
local Clipboard = require('core.clipboard')
local X11C = require('core.x11_const')
local Util = require('core.util')

local log = Util.logger('color_picker')
local keybind_hint = Util.keybind_hint

local THEME = {
    bg            = 0x141218,
    surface       = 0x1d1b20,
    surface_hi    = 0x2b2930,
    primary       = 0xb69eff,
    primary_hi    = 0xcfbcff,
    on_primary    = 0x2e1065,
    secondary_ctr = 0x4a4458,
    on_surface    = 0xe6e1e5,
    on_var        = 0xcac4d0,
    outline       = 0x49454f,
    red           = 0xf2b8b5,
    green         = 0xa6e3a1,
}

local XC_CROSSHAIR = 34
local ZOOM = 10   -- 放大倍数
local GRID = 15   -- 采样网格 GRID×GRID 像素（奇数，中心格对准光标）
local PAD = 12

local L_TITLE = '取色器'
local L_PICK = '取色'
local L_PICKING = '取色中…'
local L_COPY = '复制'
local L_CLOSE = '×'
local L_PICKING_TIP = '移动鼠标预览，左键取色，Esc 取消'
local L_EMPTY = '尚未取色'
local L_IDLE_TIP = '点击「取色」截取全屏开始取色'

local function hex_of(c)
    return string.format('#%02X%02X%02X', c.r, c.g, c.b)
end

-- PPM P6 → w, h, base（二进制像素数据 1 起始偏移）
local function ppm_parse(data)
    if not data or data:sub(1, 2) ~= 'P6' then return nil end
    local i, vals = 3, {}
    while #vals < 3 and i <= #data do
        local c = data:sub(i, i)
        if c == '#' then
            i = data:find('\n', i, true) or (#data + 1)
        elseif c:match('^%s') then
            i = i + 1
        else
            local n = data:match('^%d+', i)
            if not n then return nil end
            vals[#vals + 1] = tonumber(n)
            i = i + #n
        end
    end
    if #vals < 3 or vals[3] ~= 255 then return nil end
    return vals[1], vals[2], i + 1
end

function M.init(ctx)
    M.ctx = ctx
    M.picking = false
    M.color = nil
    local ks = ctx.X11.XStringToKeysym('Escape')
    M.esc_code = ctx.X11.XKeysymToKeycode(ctx.dpy, ks)
    M.hint = keybind_hint(ctx, 'toggle_color_picker')

    local lh = ctx.get_primary_line_height()
    M.LH = lh
    M.W = 320
    M.APPBAR = lh + 30
    M.SWATCH_H = 64
    M.BTN_H = lh + 24
    M.H = M.APPBAR + 18 + M.SWATCH_H + 14 + (lh + 4) * 2 + 14 + M.BTN_H + 20
    M.MAG_W = PAD * 2 + GRID * ZOOM
    M.MAG_H = PAD + GRID * ZOOM + 10 + lh + PAD

    M.panel = Panel.new(ctx, {
        name = 'color_picker',
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
    })

    ctx.register_action('toggle_color_picker', function() M.panel:toggle() end)
    ctx.on('tick', function(dt) M.panel:tick(dt) end)
    ctx.on('xevent', function(t, ev) return M.on_ev(t, ev) end)
    log('ready')
end

function M.on_ev(t, ev)
    if not M.panel then return false end
    if M.picking then
        if t == 6 then -- MOTION
            M.mx, M.my = ev.xmotion.x_root, ev.xmotion.y_root
            M.pick_color()
            M.draw_mag()
            return true
        elseif t == 4 then -- PRESS
            if ev.xbutton.button == 1 then
                M.mx, M.my = ev.xbutton.x_root, ev.xbutton.y_root
                M.pick_color()
                M.finish_pick(true)
            else
                M.finish_pick(false)
            end
            return true
        elseif t == 5 then
            return true
        elseif t == 2 then
            if ev.xkey.keycode == M.esc_code then
                M.finish_pick(false)
            end
            return true
        end
        return false
    end
    return M.panel:on_ev(t, ev)
end

function M.pixel_at(x, y)
    local s = M.shot
    if not s or x < 0 or y < 0 or x >= s.w or y >= s.h then return nil end
    local i = s.base + (y * s.w + x) * 3
    local d = s.data
    return { r = d:byte(i), g = d:byte(i + 1), b = d:byte(i + 2) }
end

function M.pick_color()
    M.color = M.pixel_at(math.floor(M.mx), math.floor(M.my))
end

-- grim 全屏截图 → 全屏覆盖窗（截图作背景 pixmap）
function M.build_shot_window()
    local ctx = M.ctx
    local ffi = ctx.ffi
    local X, dpy = ctx.X11, ctx.dpy
    local s = M.shot
    local raw = ffi.new('unsigned char[?]', #s.data, s.data)
    local n = s.w * s.h
    local zbuf = ffi.new('unsigned char[?]', n * 4)
    local b0 = s.base - 1
    for i = 0, n - 1 do
        local j = b0 + i * 3
        local o = i * 4
        zbuf[o] = raw[j + 2]     -- B
        zbuf[o + 1] = raw[j + 1] -- G
        zbuf[o + 2] = raw[j]     -- R
        zbuf[o + 3] = 0
    end
    local pix = X.XCreatePixmap(dpy, ctx.root, s.w, s.h, ctx.depth)
    local gc = X.XCreateGC(dpy, pix, 0, nil)
    local visual = X.XDefaultVisual(dpy, X.XDefaultScreen(dpy))
    local img = X.XCreateImage(dpy, visual, ctx.depth, 2, 0, zbuf, s.w, s.h, 32, 0)
    if img == nil then
        X.XFreeGC(dpy, gc)
        X.XFreePixmap(dpy, pix)
        error('XCreateImage failed')
    end
    X.XPutImage(dpy, pix, gc, img, 0, 0, 0, 0, s.w, s.h)
    ctx.FT.surf_ximg_detach(img) -- 缓冲由 GC 持有，防 XDestroyImage 释放
    X.XDestroyImage(img)
    X.XFreeGC(dpy, gc)

    M.shot_pix = pix
    M.shot_canvas = Canvas.new(ctx, s.w, s.h, { x = 0, y = 0, bg = 0, border_width = 0 })
    X.XSetWindowBackgroundPixmap(dpy, M.shot_canvas.win, pix)
    X.XClearWindow(dpy, M.shot_canvas.win)
    M.shot_canvas:show()
end

-- 放大镜：GRID×GRID 采样区绘制 ZOOM 倍色块 + 中心十字 + hex
function M.draw_mag()
    if not M.mag_surf then return end
    local s, T = M.mag_surf, THEME
    local half = math.floor(GRID / 2)
    s:clear(0x000000)
    for gy = 0, GRID - 1 do
        for gx = 0, GRID - 1 do
            local c = M.pixel_at(M.mx - half + gx, M.my - half + gy)
            local col = 0x1a1a1a
            if c then col = c.r * 0x10000 + c.g * 0x100 + c.b end
            s:rect(PAD + gx * ZOOM, PAD + gy * ZOOM, ZOOM, ZOOM, col)
        end
    end
    -- 中心格白框描边
    local cx0 = PAD + half * ZOOM
    local cy0 = PAD + half * ZOOM
    s:rect(cx0 - 1, cy0 - 1, ZOOM + 2, 1, 0xffffff)
    s:rect(cx0 - 1, cy0 + ZOOM, ZOOM + 2, 1, 0xffffff)
    s:rect(cx0 - 1, cy0, 1, ZOOM, 0xffffff)
    s:rect(cx0 + ZOOM, cy0, 1, ZOOM, 0xffffff)
    if M.color then
        s:text(PAD, PAD + GRID * ZOOM + 10, hex_of(M.color), T.on_surface)
    end

    -- 跟随光标，靠边翻转
    local mx, my = M.mx + 20, M.my + 20
    if mx + M.MAG_W > M.ctx.scr_w then mx = M.mx - M.MAG_W - 20 end
    if my + M.MAG_H > M.ctx.scr_h then my = M.my - M.MAG_H - 20 end
    if mx < 0 then mx = 0 end
    if my < 0 then my = 0 end
    M.mag_canvas:move(mx, my)
    s:flush(M.mag_canvas.win, M.mag_canvas.wgc)
end

function M.start_pick()
    local ctx = M.ctx
    local p = io.popen('grim -t ppm - 2>&1')
    if not p then
        ctx.show_bubble('无法启动 grim（需要安装 grim）😢')
        return
    end
    local data = p:read('*a')
    p:close()
    local w, h, base = ppm_parse(data)
    if not w then
        ctx.show_bubble('grim 截屏失败，详见 /tmp/xpet.log 😢')
        log('grim output: %s', tostring(data):sub(1, 200))
        return
    end
    M.shot = { data = data, w = w, h = h, base = base }

    local ok, err = pcall(M.build_shot_window)
    if not ok then
        M.shot = nil
        log('build shot window failed: %s', tostring(err))
        ctx.show_bubble('截屏窗创建失败 😢')
        return
    end

    M.mag_canvas = Canvas.new(ctx, M.MAG_W, M.MAG_H, {
        x = 0, y = 0, bg = THEME.outline, border_width = 1,
    })
    M.mag_surf = Surface.new(ctx, M.MAG_W, M.MAG_H)

    local X, dpy = ctx.X11, ctx.dpy
    M.cursor = X.XCreateFontCursor(dpy, XC_CROSSHAIR)
    local mask = X11C.BUTTON_PRESS_MASK + X11C.BUTTON_RELEASE_MASK
        + X11C.POINTER_MOTION_MASK
    X.XGrabPointer(dpy, ctx.root, 0, mask, 1, 1, 0, M.cursor, 0)
    X.XGrabKeyboard(dpy, ctx.root, 0, 1, 1, 0)

    M.picking = true
    M.mx, M.my = math.floor(ctx.scr_w / 2), math.floor(ctx.scr_h / 2)
    M.pick_color()
    M.draw_mag()
    M.mag_canvas:show()
    if M.panel.visible then M.panel:draw() end
end

function M.stop_pick()
    local X, dpy = M.ctx.X11, M.ctx.dpy
    X.XUngrabPointer(dpy, 0)
    X.XUngrabKeyboard(dpy, 0)
    if M.cursor then
        X.XFreeCursor(dpy, M.cursor)
        M.cursor = nil
    end
    if M.mag_canvas then
        M.mag_surf:destroy()
        M.mag_surf = nil
        M.mag_canvas:destroy()
        M.mag_canvas = nil
    end
    if M.shot_canvas then
        M.shot_canvas:destroy()
        M.shot_canvas = nil
    end
    if M.shot_pix then
        X.XFreePixmap(dpy, M.shot_pix)
        M.shot_pix = nil
    end
    M.shot = nil
    M.picking = false
end

function M.finish_pick(ok)
    M.stop_pick()
    if ok and M.color then
        local hex = hex_of(M.color)
        if Clipboard.copy(hex) then
            M.ctx.show_bubble(hex .. ' 已复制 🎨')
        else
            M.ctx.show_bubble(hex .. '（复制失败）😢')
        end
    end
    if M.panel.visible then M.panel:draw() end
end

function M.draw(p)
    local ui, s, T = p.ui, p.surf, p.ui.theme
    local lh = M.LH
    local W = M.W
    local tw = function(str) return select(1, M.ctx.get_text_size(str)) end

    s:rect(0, 0, W, M.APPBAR, T.surface)
    local ay = math.floor((M.APPBAR - lh) / 2)
    s:text(24, ay, L_TITLE, T.primary)

    local close_sz = 32
    local close_x = W - 24 - close_sz
    local close_y = math.floor((M.APPBAR - close_sz) / 2)
    local hw = tw(M.hint)
    s:text(close_x - 16 - hw, ay, M.hint, T.outline)

    local close_hover = ui:hover(close_x, close_y, close_sz, close_sz)
    s:rrect(close_x, close_y, close_sz, close_sz,
            math.floor(close_sz / 2), close_hover and T.surface_hi or T.bg)
    local cl_w = tw(L_CLOSE)
    s:text(math.floor(close_x + close_sz / 2 - cl_w / 2),
           math.floor(close_y + (close_sz - lh) / 2), L_CLOSE, T.red)
    if ui:clicked(close_x, close_y, close_sz, close_sz) then
        p:hide()
    end
    s:rect(0, M.APPBAR - 1, W, 1, T.outline)

    local y = M.APPBAR + 18
    if M.color then
        local rgb = M.color.r * 0x10000 + M.color.g * 0x100 + M.color.b
        s:rrect(24, y, W - 48, M.SWATCH_H, 12, 0x000000)
        s:rrect(25, y + 1, W - 50, M.SWATCH_H - 2, 11, rgb)
    else
        s:rrect(24, y, W - 48, M.SWATCH_H, 12, T.surface_hi)
        local e_w = tw(L_EMPTY)
        s:text(math.floor(W / 2 - e_w / 2),
               y + math.floor((M.SWATCH_H - lh) / 2), L_EMPTY, T.on_var)
    end

    y = y + M.SWATCH_H + 14
    if M.color then
        local hex = hex_of(M.color)
        s:text(24, y, hex, T.on_surface)
        local rgb = string.format('R %d  G %d  B %d', M.color.r, M.color.g, M.color.b)
        s:text(W - 24 - tw(rgb), y, rgb, T.on_var)
        s:text(24, y + lh + 4, M.picking and L_PICKING_TIP or ' ', T.outline)
    else
        s:text(24, y, M.picking and L_PICKING_TIP or L_IDLE_TIP, T.on_var)
    end

    y = y + (lh + 4) * 2 + 14
    local btn_w = math.floor((W - 48 - 12) / 2)
    if ui:id_button('cp_pick', 24, y, btn_w, M.BTN_H,
                    M.picking and L_PICKING or L_PICK,
                    { filled = not M.picking, radius = 14 }) then
        if not M.picking then M.start_pick() end
    end
    if ui:id_button('cp_copy', 24 + btn_w + 12, y, btn_w, M.BTN_H, L_COPY,
                    { tonal = true, radius = 14 }) then
        if M.color then
            local hex = hex_of(M.color)
            if Clipboard.copy(hex) then
                M.ctx.show_bubble(hex .. ' 已复制 📋')
            end
        end
    end
end

function M.shutdown()
    if M.picking then
        M.stop_pick()
    end
    if M.panel then M.panel:destroy() end
end

return M
