local M = {}
local bit = require("bit")
local Panel = require("core.panel")
local Util = require("core.util")

local log = Util.logger("launcher")
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

local XK_Up = 0xff52
local XK_Down = 0xff54
local XK_e = 0x0065
local XK_E = 0x0045
local MOD1_MASK = 0x0008 -- alt

function M.init(ctx)
    M.ctx = ctx
    local cfg = ctx.config.launcher or {}
    M.entries = {}
    for _, e in ipairs(cfg.entries or {}) do
        if e.cmd and e.cmd ~= "" then
            M.entries[#M.entries + 1] = { name = e.name or e.cmd, cmd = e.cmd }
        end
    end
    M.filtered = M.entries
    M.sel = #M.filtered > 0 and 1 or 0
    M.scroll = 0
    M.query = ""

    local lh = ctx.get_primary_line_height()
    M.LH = lh
    M.W = 520
    M.SEARCH_H = lh + 20
    M.ROW_H = lh + 20
    M.VROWS = 8
    M.H = 16 + M.SEARCH_H + 12 + M.VROWS * M.ROW_H + 14

    M.panel = Panel.new(ctx, {
        name = 'launcher',
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
        on_show = function(p)
            M.sel = #M.filtered > 0 and 1 or 0
            M.scroll = 0
            p:focus_input()
        end,
        input = {
            placeholder = "搜索应用，或直接输入命令回车执行",
            on_change = function(v)
                M.query = v
                M.apply_filter()
            end,
            on_submit = function(v) M.submit(v) end,
            on_cancel = function() M.panel:hide() end,
        },
        on_key = function(p, sym, ctrl, shift, text, state)
            -- 键盘被面板 grab 期间全局快捷键收不到，Ctrl+Alt+E 在这里处理隐藏
            local alt = state and bit.band(state, MOD1_MASK) ~= 0
            if ctrl and alt and (sym == XK_e or sym == XK_E) then
                p:hide()
                return true
            end
            if sym == XK_Up then
                M.move_sel(-1)
                return true
            elseif sym == XK_Down then
                M.move_sel(1)
                return true
            end
            return false
        end,
        on_wheel = function(p, btn)
            M.move_sel(btn == 4 and -1 or 1)
        end,
    })

    ctx.register_action("toggle_launcher", function() M.panel:toggle() end)
    ctx.on("tick", function(dt) M.panel:tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)
    log("ready: %d entries", #M.entries)
end

function M.on_ev(t, ev)
    if not M.panel then return false end
    return M.panel:on_ev(t, ev)
end

function M.move_sel(d)
    local n = #M.filtered
    if n == 0 then
        M.sel = 0
        return
    end
    M.sel = M.sel + d
    if M.sel < 1 then M.sel = 1 end
    if M.sel > n then M.sel = n end
    if M.sel < M.scroll + 1 then M.scroll = M.sel - 1 end
    if M.sel > M.scroll + M.VROWS then M.scroll = M.sel - M.VROWS end
    local mx_s = math.max(0, n - M.VROWS)
    if M.scroll > mx_s then M.scroll = mx_s end
    if M.scroll < 0 then M.scroll = 0 end
    M.panel:draw()
end

function M.apply_filter()
    if M.query == "" then
        M.filtered = M.entries
    else
        local ql = M.query:lower()
        local out = {}
        for _, e in ipairs(M.entries) do
            if e.name:lower():find(ql, 1, true) or e.cmd:lower():find(ql, 1, true) then
                out[#out + 1] = e
            end
        end
        M.filtered = out
    end
    M.sel = #M.filtered > 0 and 1 or 0
    M.scroll = 0
end

function M.run(cmd)
    local esc = cmd:gsub("'", "'\\''")
    os.execute(string.format("nohup sh -c '%s' >/dev/null 2>&1 &", esc))
end

function M.launch(e)
    M.run(e.cmd)
    M.ctx.show_bubble("🚀 " .. e.name)
    M.panel:hide()
end

function M.submit(v)
    if M.sel >= 1 and M.filtered[M.sel] then
        M.launch(M.filtered[M.sel])
        return
    end
    local q = (v or ""):match("^%s*(.-)%s*$")
    if q == "" then return end
    for _, e in ipairs(M.entries) do
        if e.name == q or e.cmd == q then
            M.launch(e)
            return
        end
    end
    M.run(q)
    M.ctx.show_bubble("已执行: " .. truncate(q, 40))
    M.panel:hide()
end

function M.draw(p)
    local ui, s, T = p.ui, p.surf, p.ui.theme
    local lh = M.LH
    local W = M.W
    local tw = function(str) return select(1, M.ctx.get_text_size(str)) end

    s:rect(0, 0, W, M.H, T.bg)
    s:rrect(0, 0, W, M.H, 16, T.surface)
    s:rrect(1, 1, W - 2, M.H - 2, 15, T.bg)

    -- 右上角 × 关闭按钮
    local bx = W - 16 - 28
    local by = 16 + math.floor((M.SEARCH_H - 28) / 2)
    p.input:set_rect(16, 16, bx - 8 - 16, M.SEARCH_H)
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
    local close_hover = ui:hover(bx, by, 28, 28)
    s:rrect(bx, by, 28, 28, 14, close_hover and T.surface_hi or T.bg)
    local cl_w = tw("×")
    s:text(bx + math.floor((28 - cl_w) / 2),
           by + math.floor((28 - lh) / 2), "×", T.red)
    if ui:clicked(bx, by, 28, 28) then
        p:hide()
    end

    local list_y = 16 + M.SEARCH_H + 12
    local n = #M.filtered
    for i = 1, M.VROWS do
        local li = M.scroll + i
        if li > n then break end
        local e = M.filtered[li]
        local ry = list_y + (i - 1) * M.ROW_H
        local sel = li == M.sel
        local hover = ui:hover(0, ry, W, M.ROW_H)
        local row_bg = sel and T.surface_hi or (hover and T.surface_hi or T.bg)
        s:rect(8, ry, W - 16, M.ROW_H, row_bg)
        if sel then
            s:rect(8, ry, 4, M.ROW_H, T.primary)
        end
        s:rrect(24, ry + math.floor((M.ROW_H - 8) / 2), 8, 8, 4,
                sel and T.primary or T.outline)
        local ty = ry + math.floor((M.ROW_H - lh) / 2)
        s:text(44, ty, truncate(e.name, 24), sel and T.on_surface or T.on_var)
        local cw = select(1, M.ctx.get_text_size(e.cmd))
        if cw > W - 44 - 24 - 200 then
            s:text(W - 24 - math.min(cw, 260), ty, truncate(e.cmd, 34), T.outline)
        else
            s:text(W - 24 - cw, ty, e.cmd, T.outline)
        end
        if ui:clicked(0, ry, W, M.ROW_H) then
            M.sel = li
            M.launch(e)
        end
    end

    if n == 0 then
        local empty = M.query ~= "" and "没有匹配的应用，回车直接执行命令"
            or "在 config.lua 的 launcher.entries 里配置应用"
        s:text(math.floor(W / 2 - select(1, M.ctx.get_text_size(empty)) / 2),
               list_y + 40, empty, T.outline)
    end
end

return M
