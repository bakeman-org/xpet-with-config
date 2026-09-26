local M = {}
local Panel = require("core.panel")
local Clipboard = require("core.clipboard")
local Util = require("core.util")

local log = Util.logger("clip_hist")
local keybind_hint = Util.keybind_hint
local truncate = Util.truncate

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

local POLL_MS = 2000
local MAX_ENTRY_BYTES = 65536

local L_TITLE = "剪贴板"
local L_CLEAR = "清空"
local L_CLOSE = "×"

local function preview(text)
    local one = text:gsub("[\r\n]+", " ")
    return truncate(one, 64)
end

function M.init(ctx)
    M.ctx = ctx
    local S = ctx._clip_state or {}
    local cfg = ctx.config.clip_hist or {}
    M.max_items = cfg.max_items or 30
    M.history = S.history or {}
    M.last = nil
    M.acc = POLL_MS
    M.scroll = 0
    M.query = ""
    M.hint = keybind_hint(ctx, "toggle_clip_hist")

    local lh = ctx.get_primary_line_height()
    M.LH = lh
    M.W = 560
    M.APPBAR = lh + 30
    M.SEARCH_H = lh + 20
    M.ROW_H = lh + 22
    M.VROWS = 8
    M.H = M.APPBAR + 14 + M.SEARCH_H + 12 + M.VROWS * M.ROW_H + 14

    M.panel = Panel.new(ctx, {
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
        input = {
            placeholder = "筛选历史记录",
            on_change = function(v)
                M.query = v
                M.apply_filter()
            end,
            on_cancel = function() M.panel:blur_input() end,
        },
        on_wheel = function(p, btn)
            local mx_s = math.max(0, #M.filtered - M.VROWS)
            if btn == 4 then
                M.scroll = math.max(0, M.scroll - 2)
            else
                M.scroll = math.min(mx_s, M.scroll + 2)
            end
        end,
    })

    M.apply_filter()
    ctx.register_action("toggle_clip_hist", function() M.panel:toggle() end)
    ctx.on("tick", function(dt) M.on_tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)
    log("ready: %d items, backend=%s", #M.history, Clipboard.backend())
end

function M.on_tick(dt)
    M.panel:tick(dt)
    M.acc = M.acc + dt
    if M.acc >= POLL_MS then
        M.acc = 0
        M.poll()
    end
end

function M.on_ev(t, ev)
    if not M.panel then return false end
    return M.panel:on_ev(t, ev)
end

function M.poll()
    local content = Clipboard.paste()
    if not content or content == "" or content == M.last then return end
    if #content > MAX_ENTRY_BYTES then return end
    M.last = content
    for i, e in ipairs(M.history) do
        if e.text == content then
            table.remove(M.history, i)
            break
        end
    end
    table.insert(M.history, 1, { text = content, t = os.time() })
    while #M.history > M.max_items do
        table.remove(M.history)
    end
    M.apply_filter()
    if M.panel.visible then M.panel:draw() end
end

function M.apply_filter()
    if M.query == "" then
        M.filtered = M.history
    else
        local ql = M.query:lower()
        local out = {}
        for _, e in ipairs(M.history) do
            if e.text:lower():find(ql, 1, true) then
                out[#out + 1] = e
            end
        end
        M.filtered = out
    end
    local mx_s = math.max(0, #M.filtered - M.VROWS)
    if M.scroll > mx_s then M.scroll = mx_s end
end

function M.copy_row(e)
    if Clipboard.copy(e.text) then
        M.last = e.text
        M.ctx.show_bubble("已复制 📋")
    else
        M.ctx.show_bubble("复制失败 😢")
    end
end

function M.clear_all()
    M.history = {}
    M.filtered = M.history
    M.scroll = 0
    M.ctx.show_bubble("剪贴板历史已清空 🧹")
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

    local clear_w = 64
    local clear_x = close_x - 12 - clear_w
    if ui:id_button("clip_clear", clear_x, close_y + 1, clear_w, close_sz - 2,
                    L_CLEAR, { tonal = true, radius = math.floor(close_sz / 2) }) then
        M.clear_all()
    end
    s:rect(0, M.APPBAR - 1, W, 1, T.outline)

    local sy = M.APPBAR + 14
    p.input:set_rect(24, sy, W - 48, M.SEARCH_H)
    p.input:draw(s, {
        bg            = T.surface_hi,
        bg_focus      = T.surface_hi,
        radius        = math.floor(M.SEARCH_H / 2),
        outline_focus = T.primary,
        text          = T.on_surface,
        text_dim      = T.on_var,
        cursor        = T.primary,
        sel_bg        = T.secondary_ctr,
    })

    local list_y = sy + M.SEARCH_H + 12
    local n = #M.filtered
    for i = 1, M.VROWS do
        local li = M.scroll + i
        if li > n then break end
        local e = M.filtered[li]
        local ry = list_y + (i - 1) * M.ROW_H
        local hover = ui:hover(0, ry, W, M.ROW_H)
        local row_bg = hover and T.surface_hi or T.bg
        s:rect(0, ry, W, M.ROW_H, row_bg)
        s:rrect(24, ry + math.floor((M.ROW_H - 8) / 2), 8, 8, 4, T.primary)
        local ty = ry + math.floor((M.ROW_H - lh) / 2)
        s:text(44, ty, preview(e.text), T.on_var)
        local tstr = os.date("%H:%M", e.t)
        local tsw = tw(tstr)
        s:text(W - 24 - tsw, ty, tstr, T.outline)
        if i < M.VROWS and li < n then
            s:rect(24, ry + M.ROW_H - 1, W - 48, 1, T.outline)
        end
        if ui:clicked(0, ry, W, M.ROW_H) then
            M.copy_row(e)
        end
    end

    if n == 0 then
        local empty = M.query ~= "" and "没有匹配的记录" or "剪贴板还是空的，去复制点什么吧~"
        s:text(math.floor(W / 2 - tw(empty) / 2), list_y + 40, empty, T.outline)
    end
end

function M.shutdown()
    if M.ctx then
        M.ctx._clip_state = { history = M.history }
    end
    if M.panel then M.panel:destroy() end
end

return M
