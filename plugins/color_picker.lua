local M = {}
local bit = require("bit")
local Panel = require("core.panel")
local Clipboard = require("core.clipboard")
local X11C = require("core.x11_const")
local Util = require("core.util")

local log = Util.logger("color_picker")
local keybind_hint = Util.keybind_hint

local THEME = {
    bg            = 0x141218,
    surface       = 0x1d1b20,
    surface_hi    = 0x2b2930,
    surface_hover = 0x3b383e,
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

local L_TITLE = "取色器"
local L_PICK = "取色"
local L_PICKING = "取色中…"
local L_COPY = "复制"
local L_CLOSE = "×"
local L_PICKING_TIP = "移动鼠标预览，左键确认，Esc 取消"
local L_EMPTY = "点击「取色」，然后点屏幕上的任意位置"

local function hex_of(c)
    return string.format("#%02X%02X%02X", c.r, c.g, c.b)
end

function M.init(ctx)
    M.ctx = ctx
    M.picking = false
    M.color = nil
    M.cursor = nil
    local ks = ctx.X11.XStringToKeysym("Escape")
    M.esc_code = ctx.X11.XKeysymToKeycode(ctx.dpy, ks)
    M.hint = keybind_hint(ctx, "toggle_color_picker")

    local lh = ctx.get_primary_line_height()
    M.LH = lh
    M.W = 320
    M.APPBAR = lh + 30
    M.SWATCH_H = 64
    M.BTN_H = lh + 24
    M.H = M.APPBAR + 18 + M.SWATCH_H + 14 + (lh + 4) * 2 + 14 + M.BTN_H + 20

    M.panel = Panel.new(ctx, {
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
    })

    ctx.register_action("toggle_color_picker", function() M.panel:toggle() end)
    ctx.on("tick", function(dt) M.panel:tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)
    log("ready")
end

function M.on_ev(t, ev)
    if not M.panel then return false end
    if M.picking then
        if t == 6 then
            M.sample(ev.xmotion.x_root, ev.xmotion.y_root)
            return true
        elseif t == 4 then
            if ev.xbutton.button == 1 then
                M.sample(ev.xbutton.x_root, ev.xbutton.y_root)
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

function M.sample(x, y)
    local X, dpy, root = M.ctx.X11, M.ctx.dpy, M.ctx.root
    if x < 0 or y < 0 or x >= M.ctx.scr_w or y >= M.ctx.scr_h then
        return
    end
    local img = X.XGetImage(dpy, root, x, y, 1, 1, 0xFFFFFFFF, 2)
    if not img then return end
    local p = X.XGetPixel(img, 0, 0)
    X.XDestroyImage(img)
    M.color = {
        r = bit.band(bit.rshift(p, 16), 0xFF),
        g = bit.band(bit.rshift(p, 8), 0xFF),
        b = bit.band(p, 0xFF),
    }
    if M.panel.visible then M.panel:draw() end
end

function M.start_pick()
    local X, dpy = M.ctx.X11, M.ctx.dpy
    M.cursor = X.XCreateFontCursor(dpy, XC_CROSSHAIR)
    local mask = X11C.BUTTON_PRESS_MASK + X11C.BUTTON_RELEASE_MASK
        + X11C.POINTER_MOTION_MASK
    X.XGrabPointer(dpy, M.ctx.root, 0, mask, 1, 1, 0, M.cursor, 0)
    X.XGrabKeyboard(dpy, M.ctx.root, 0, 1, 1, 0)
    M.picking = true
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
    M.picking = false
end

function M.finish_pick(ok)
    M.stop_pick()
    if ok and M.color then
        local hex = hex_of(M.color)
        if Clipboard.copy(hex) then
            M.ctx.show_bubble(hex .. " 已复制 🎨")
        else
            M.ctx.show_bubble(hex .. "（复制失败）😢")
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
        if e_w < W - 72 then
            s:text(math.floor(W / 2 - e_w / 2),
                   y + math.floor((M.SWATCH_H - lh) / 2), L_EMPTY, T.on_var)
        end
    end

    y = y + M.SWATCH_H + 14
    if M.color then
        local hex = hex_of(M.color)
        s:text(24, y, hex, T.on_surface)
        local rgb = string.format("R %d  G %d  B %d", M.color.r, M.color.g, M.color.b)
        s:text(W - 24 - tw(rgb), y, rgb, T.on_var)
        s:text(24, y + lh + 4, M.picking and L_PICKING_TIP or " ", T.outline)
    else
        s:text(24, y, M.picking and L_PICKING_TIP or " ", T.on_var)
    end

    y = y + (lh + 4) * 2 + 14
    local btn_w = math.floor((W - 48 - 12) / 2)
    if ui:id_button("cp_pick", 24, y, btn_w, M.BTN_H,
                    M.picking and L_PICKING or L_PICK,
                    { filled = not M.picking, radius = 14 }) then
        if not M.picking then M.start_pick() end
    end
    if ui:id_button("cp_copy", 24 + btn_w + 12, y, btn_w, M.BTN_H, L_COPY,
                    { tonal = true, radius = 14 }) then
        if M.color then
            local hex = hex_of(M.color)
            if Clipboard.copy(hex) then
                M.ctx.show_bubble(hex .. " 已复制 📋")
            end
        end
    end
end

return M
