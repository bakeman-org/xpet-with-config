local M = {}
local Panel = require("core.panel")
local Util = require("core.util")

local log = Util.logger("pomodoro")
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

local L_TITLE = "番茄钟"
local L_FOCUS = "专注"
local L_BREAK = "休息"
local L_START = "开始"
local L_PAUSE = "暂停"
local L_RESET = "重置"
local L_CLOSE = "×"

local function fmt_ms(ms)
    local s = math.max(0, math.ceil(ms / 1000))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function M.init(ctx)
    M.ctx = ctx
    local S = ctx._pomo_state or {}
    local cfg = ctx.config.pomodoro or {}
    M.work_ms = (cfg.work_min or 25) * 60000
    M.break_ms = (cfg.break_min or 5) * 60000
    M.mode = S.mode or "focus"
    M.running = S.running or false
    M.done = S.done or 0
    M.total = M.mode == "focus" and M.work_ms or M.break_ms
    M.remaining = S.remaining or M.total
    if M.remaining > M.total then M.remaining = M.total end
    M.last_sec = -1
    M.hint = keybind_hint(ctx, "toggle_pomodoro")

    local lh = ctx.get_primary_line_height()
    M.LH = lh
    M.W = 340
    M.APPBAR = lh + 30
    M.BIG_H = lh + 34
    M.CHIP_H = lh + 14
    M.BTN_H = lh + 24
    M.PROG_H = 6
    M.H = M.APPBAR + 20 + M.BIG_H + 16 + M.PROG_H + 18
        + M.CHIP_H + 14 + M.BTN_H + 44

    M.panel = Panel.new(ctx, {
        name = 'pomodoro',
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
    })

    ctx.register_action("toggle_pomodoro", function() M.panel:toggle() end)
    ctx.on("tick", function(dt) M.on_tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)
    log("ready: focus=%dmin break=%dmin",
        math.floor(M.work_ms / 60000), math.floor(M.break_ms / 60000))
end

function M.on_tick(dt)
    M.panel:tick(dt)
    if M.running then
        M.remaining = M.remaining - dt
        if M.remaining <= 0 then
            M.finish()
            return
        end
        -- 每变化一秒刷新一次显示（之前只在鼠标事件时重绘，倒计时看着不动）
        local sec = math.ceil(M.remaining / 1000)
        if sec ~= M.last_sec and M.panel.visible then
            M.last_sec = sec
            M.panel:draw()
        end
    end
end

function M.on_ev(t, ev)
    if not M.panel then return false end
    return M.panel:on_ev(t, ev)
end

function M.finish()
    M.running = false
    if M.mode == "focus" then
        M.done = M.done + 1
        M.mode = "break"
        M.ctx.show_bubble(string.format("🍅 第 %d 个番茄完成，休息一下~", M.done))
    else
        M.mode = "focus"
        M.ctx.show_bubble("☀️ 休息结束，准备下一个番茄！")
    end
    M.total = M.mode == "focus" and M.work_ms or M.break_ms
    M.remaining = M.total
    M.last_sec = -1
    local pet = M.ctx.pet
    if pet then
        if pet.play_audio then pet:play_audio() end
        if pet.set_state then pet:set_state("happy") end
    end
    if M.panel.visible then M.panel:draw() end
end

function M.set_mode(m)
    if M.mode == m then return end
    M.mode = m
    M.running = false
    M.total = m == "focus" and M.work_ms or M.break_ms
    M.remaining = M.total
    M.last_sec = -1
    M.panel:draw()
end

function M.toggle_run()
    M.running = not M.running
    M.last_sec = -1
    M.panel:draw()
end

function M.reset_timer()
    M.running = false
    M.remaining = M.total
    M.last_sec = -1
    M.panel:draw()
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

    local y = M.APPBAR + 20
    local is_focus = M.mode == "focus"
    local tcol = M.running and (is_focus and T.primary or T.green) or T.on_var
    local tstr = fmt_ms(M.remaining)
    s:text(math.floor(W / 2 - tw(tstr) / 2), y, tstr, tcol)

    y = y + M.BIG_H + 16
    local frac = 1 - math.max(0, M.remaining) / M.total
    local pw = W - 48
    s:rrect(24, y, pw, M.PROG_H, 3, T.surface_hi)
    if frac > 0 then
        local fw = math.max(6, math.floor(pw * frac))
        s:rrect(24, y, fw, M.PROG_H, 3, is_focus and T.primary or T.green)
    end

    y = y + M.PROG_H + 18
    local chip_w = 90
    local cx = math.floor((W - (chip_w * 2 + 12)) / 2)
    if ui:id_button("pomo_focus", cx, y, chip_w, M.CHIP_H, L_FOCUS,
                    { filled = is_focus, radius = math.floor(M.CHIP_H / 2) }) then
        M.set_mode("focus")
    end
    if ui:id_button("pomo_break", cx + chip_w + 12, y, chip_w, M.CHIP_H, L_BREAK,
                    { filled = not is_focus, radius = math.floor(M.CHIP_H / 2) }) then
        M.set_mode("break")
    end

    y = y + M.CHIP_H + 14
    local btn_w = 110
    local bx = math.floor((W - (btn_w * 2 + 12)) / 2)
    if ui:id_button("pomo_run", bx, y, btn_w, M.BTN_H,
                    M.running and L_PAUSE or L_START,
                    { filled = true, radius = 14 }) then
        M.toggle_run()
    end
    if ui:id_button("pomo_reset", bx + btn_w + 12, y, btn_w, M.BTN_H, L_RESET,
                    { tonal = true, radius = 14 }) then
        M.reset_timer()
    end

    local dstr = string.format("已完成 %d 个 🍅", M.done)
    s:text(math.floor(W / 2 - tw(dstr) / 2), y + M.BTN_H + 10, dstr, T.outline)
end

function M.shutdown()
    if M.ctx then
        M.ctx._pomo_state = {
            mode = M.mode,
            running = M.running,
            done = M.done,
            remaining = M.remaining,
        }
    end
    if M.panel then M.panel:destroy() end
end

return M
