local M = {}
local X11C = require("core.x11_const")
local Panel = require("core.panel")
local Keybinds = require("core.keybinds")

local REFRESH_MS   = 1000
local HISTORY_LEN  = 60
local MAX_CORES    = 8
local CLK_TCK      = 100
local PAGE_SIZE    = 4096
local PROC_FETCH_N = 200

local XK_k = 0x6b

local THEME = {
    bg = 0x141218, surface = 0x1d1b20, surface_hi = 0x2b2930,
    primary = 0xb69eff, primary_hi = 0xcfbcff, on_surface = 0xe6e1e5,
    on_var = 0xcac4d0, outline = 0x49454f, secondary_ctr = 0x4a4458,
    green = 0xa6e3a1, yellow = 0xf9e2af, red = 0xf38ba8,
    track = 0x1e1e2e, select = 0x3b383e, search_bg = 0x2b2930,
}

local function read_cpu_stat()
    local f = io.open("/proc/stat", "r")
    if not f then return nil end
    local res = { cores = {} }
    for line in f:lines() do
        if line:sub(1, 3) == "cpu" then
            local name = line:match("^(cpu%d*)")
            local n = {}
            for num in line:gmatch("%d+") do n[#n + 1] = tonumber(num) end
            local total = 0
            for i = 1, 8 do total = total + (n[i] or 0) end
            local idle = (n[4] or 0) + (n[5] or 0)
            local rec = { total = total, busy = total - idle }
            if name == "cpu" then res.agg = rec
            else res.cores[#res.cores + 1] = rec end
        else break end
    end
    f:close()
    return res
end

local function read_mem()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil end
    local m = {}
    for line in f:lines() do
        local k, v = line:match("^(%w+):%s+(%d+)")
        if k then m[k] = tonumber(v) end
    end
    f:close()
    return m
end

local function list_pids()
    local pids = {}
    local p = io.popen("ls -1 /proc 2>/dev/null")
    if not p then return pids end
    for line in p:lines() do
        local pid = tonumber(line)
        if pid then pids[#pids + 1] = pid end
    end
    p:close()
    return pids
end

local function read_proc(pid)
    local f = io.open("/proc/" .. pid .. "/stat", "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    local name = line:match("%(([^%)]+)%)") or "?"
    local rest = line:match("%)%s+(.*)$")
    if not rest then return nil end
    local fields = {}
    for tok in rest:gmatch("%S+") do fields[#fields + 1] = tok end
    return {
        pid = pid, name = name,
        utime = tonumber(fields[12]) or 0,
        stime = tonumber(fields[13]) or 0,
        rss = tonumber(fields[22]) or 0,
    }
end

local function delta_pct(prev, cur)
    if not prev then return 0 end
    local dt = cur.total - prev.total
    local db = cur.busy - prev.busy
    if dt <= 0 then return 0 end
    return db / dt * 100
end

function M:sample()
    local cur = read_cpu_stat()
    if not cur or not cur.agg then return end
    local prev = M.prev_cpu
    local ncpu = #cur.cores
    if ncpu < 1 then ncpu = 1 end

    if prev then
        local agg = delta_pct(prev.agg, cur.agg)
        M.cur_cpu_agg = agg
        M.history_head = (M.history_head % HISTORY_LEN) + 1
        M.history[M.history_head] = agg

        M.cur_cores = {}
        for i, c in ipairs(cur.cores) do
            M.cur_cores[i] = delta_pct(prev.cores[i], c)
        end

        local dt_sec = (cur.agg.total - prev.agg.total) / ncpu / CLK_TCK
        if dt_sec > 0.01 then
            local list, snap = {}, {}
            local count = 0
            for _, pid in ipairs(list_pids()) do
                if count >= PROC_FETCH_N then break end
                count = count + 1
                local p = read_proc(pid)
                if p then
                    local pp = M.prev_procs[pid]
                    local cpu_pct = 0
                    if pp then
                        local d = (p.utime + p.stime) - (pp.utime + pp.stime)
                        if d > 0 then
                            cpu_pct = d / CLK_TCK / dt_sec * 100
                        end
                    end
                    list[#list + 1] = {
                        pid = p.pid, name = p.name,
                        cpu = cpu_pct, mem = p.rss * PAGE_SIZE,
                    }
                    snap[pid] = { utime = p.utime, stime = p.stime }
                end
            end
            M.prev_procs = snap
            table.sort(list, function(a, b) return a.cpu > b.cpu end)
            M.procs = list
            M:apply_filter()
        end
    end
    M.prev_cpu = cur
    M.cur_mem = read_mem()
end

function M:apply_filter()
    local q = M.search_query
    if not q or q == "" then
        M.filtered = M.procs
    else
        local ql = q:lower()
        local out = {}
        for _, p in ipairs(M.procs) do
            if p.name:lower():find(ql, 1, true)
               or tostring(p.pid):find(ql, 1, true) then
                out[#out + 1] = p
            end
        end
        M.filtered = out
    end
    M:clamp_scroll()
end

function M:clamp_scroll()
    local max_scroll = math.max(0, #M.filtered - M.VISIBLE_ROWS)
    if M.scroll > max_scroll then M.scroll = max_scroll end
    if M.scroll < 0 then M.scroll = 0 end
end

local function compute_layout(lh, ncores_display, scr_h)
    local L = {}
    L.W = 840
    L.PAD = 20
    L.HEADER_H = lh + 24
    L.BAR_H = 8
    L.SPARK_H = 40
    L.ROW_H = lh + 8
    L.CORE_H = lh + 4
    L.LABEL_W = 60
    L.PCT_W = 76
    L.FOOTER_H = lh + 16
    L.CPU_H = L.ROW_H + L.SPARK_H + 12
    L.CORES_H = ncores_display * L.CORE_H + 12
    L.MEM_H = L.ROW_H * 2 + 12
    L.PHDR_H = L.ROW_H

    local want_h = math.min(math.floor(scr_h * 0.82), 880)
    if want_h < 500 then want_h = 500 end
    local fixed = L.HEADER_H + L.CPU_H + L.CORES_H + L.MEM_H
                + L.PHDR_H + L.FOOTER_H + 30
    local list_h = want_h - fixed
    if list_h < L.ROW_H * 4 then
        list_h = L.ROW_H * 4
        want_h = fixed + list_h
    end
    L.H = want_h
    L.VISIBLE_ROWS = math.max(4, math.floor(list_h / L.ROW_H))
    return L
end

function M.init(ctx)
    M.ctx = ctx
    M.ready = true

    local lh = ctx.get_primary_line_height()
    M.LH = lh

    local probe = read_cpu_stat()
    local ncores_all = probe and #probe.cores or 4
    M.ncores_display = math.min(MAX_CORES, ncores_all)

    local L = compute_layout(lh, M.ncores_display, ctx.scr_h)
    for k, v in pairs(L) do M[k] = v end

    M.Y_SHOWN = math.max(10, math.floor((ctx.scr_h - M.H) / 2))

    M.prev_cpu = nil
    M.prev_procs = {}
    M.cur_cpu_agg = 0
    M.cur_cores = {}
    M.cur_mem = nil
    M.procs = {}
    M.filtered = {}
    M.history = {}
    M.history_head = 0

    M.scroll = 0
    M.selected_pid = nil
    M.search_query = ""
    M.refresh_acc = 0

    M.rect_close = { x = 0, y = 0, w = 0, h = 0 }
    M.rect_list  = { x = 0, y = 0, w = 0, h = 0 }

    M._code_k = ctx.X11.XKeysymToKeycode(ctx.dpy,
                ctx.X11.XStringToKeysym("k"))

    M.panel = Panel.new(ctx, {
        name = 'sysmon',
        w = M.W, h = M.H,
        theme = THEME,
        open_key = "f",
        draw = function(p) M.draw(p) end,
        input = {
            placeholder = "Ctrl+F 搜索进程名或 PID",
            on_change   = function(v) M.search_query = v; M:apply_filter() end,
            on_submit   = function() M.panel:blur_input() end,
            on_cancel   = function() M.panel:blur_input() end,
        },
        on_show = function(p)
            if p._code_open and p._code_open ~= 0 then
                Keybinds.grab_root_key(ctx.X11, ctx.dpy, ctx.root, ctx.bit,
                                       p._code_open, X11C.CONTROL_MASK)
            end
            M:sample()
        end,
        on_hide = function(p)
            if p._code_open and p._code_open ~= 0 then
                Keybinds.ungrab_root_key(ctx.X11, ctx.dpy, ctx.root, ctx.bit,
                                         p._code_open, X11C.CONTROL_MASK)
            end
        end,
        on_key = function(p, sym, ctrl)
            if ctrl and sym == XK_k then
                M:kill_selected()
                return true
            end
            return false
        end,
        on_hotkey = function(p, ev, _, ctrl)
            if ctrl and ev.xkey.keycode == M._code_k then
                M:kill_selected()
                return true
            end
            return false
        end,
        on_wheel = function(p, btn)
            if btn == 4 then
                M.scroll = math.max(0, M.scroll - 3)
            else
                M.scroll = M.scroll + 3
                M:clamp_scroll()
            end
        end,
        on_press = function(p, mx, my, btn)
            local function in_rect(r)
                return mx >= r.x and mx < r.x + r.w
                   and my >= r.y and my < r.y + r.h
            end
            if in_rect(M.rect_close) then
                p:hide()
                return true
            end
            if in_rect(M.rect_list) then
                local row = math.floor((my - M.rect_list.y) / M.ROW_H)
                local idx = M.scroll + row + 1
                if idx >= 1 and idx <= #M.filtered then
                    M.selected_pid = M.filtered[idx].pid
                    if btn == 3 then M:kill_selected() end
                end
                p:draw()
                return true
            end
            return false
        end,
        tick = function(p, dt)
            M.refresh_acc = M.refresh_acc + dt
            if M.refresh_acc >= REFRESH_MS then
                M.refresh_acc = 0
                M:sample()
                p:draw()
            elseif p.input.focused then
                p:draw()
            end
        end,
    })

    ctx.register_action("toggle_sysmon", function() M.toggle() end)
    ctx.on("tick", function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)

    M.prev_cpu = read_cpu_stat()
    for _, pid in ipairs(list_pids()) do
        local p = read_proc(pid)
        if p then
            M.prev_procs[pid] = { utime = p.utime, stime = p.stime }
        end
    end
end

function M.toggle()
    if not M.ready then return end
    M.panel:toggle()
end

function M.on_ev(t, ev)
    if not M.ready or not M.panel then return false end
    return M.panel:on_ev(t, ev)
end

function M.tick(dt)
    if not M.ready or not M.panel then return end
    M.panel:tick(dt)
end

function M:kill_selected()
    local pid = M.selected_pid
    if not pid or type(pid) ~= "number" then return end
    os.execute("kill -TERM " .. pid .. " 2>/dev/null")
    if M.ctx.show_bubble then
        M.ctx.show_bubble(
            string.format("已发送 SIGTERM → PID %d", pid),
            { style = "warning", duration = 2 })
    end
    M.selected_pid = nil
    M:sample()
end

local function load_color(pct)
    if pct >= 80 then return THEME.red end
    if pct >= 50 then return THEME.yellow end
    return THEME.green
end

local function draw_bar(s, x, y, w, h, pct, color)
    s:rect(x, y, w, h, THEME.track)
    local fill = math.floor(w * math.max(0, math.min(100, pct)) / 100)
    if fill > 0 then s:rect(x, y, fill, h, color) end
end

local function fmt_bytes_kb(kb)
    if not kb then return "--" end
    local gib = kb / 1024 / 1024
    if gib >= 1024 then return string.format("%.1f TiB", gib / 1024) end
    return string.format("%.1f GiB", gib)
end

function M.draw(p)
    if not p.surf then return end
    local s, T = p.surf, p.ui.theme
    local lh, PAD = M.LH, M.PAD
    local inner_w = M.W - PAD * 2
    local LABEL_W, PCT_W = M.LABEL_W, M.PCT_W
    local bar_x = PAD + LABEL_W
    local bar_w = inner_w - LABEL_W - PCT_W - 8

    s:rect(0, 0, M.W, M.HEADER_H, T.surface)
    local hy = math.floor((M.HEADER_H - lh) / 2)
    s:text(PAD, hy, "系统监视", T.primary)

    -- 搜索框：交给 TextInput 绘制
    local search_x = PAD + 110
    local search_w = M.W - search_x - 200
    local search_h = lh + 4
    local search_y = math.floor((M.HEADER_H - search_h) / 2)

    p.input:set_rect(search_x, search_y, search_w, search_h)
    p.input:draw(s, {
        bg            = T.search_bg,
        bg_focus      = T.search_bg,
        radius        = math.floor(search_h / 2),
        outline_focus = T.primary,
        text          = T.on_surface,
        text_dim      = T.on_var,
        cursor        = T.primary,
        sel_bg        = T.secondary_ctr,
    })

    local hint = "Ctrl+Alt+T"
    local hw = select(1, M.ctx.get_text_size(hint))
    s:text(M.W - PAD - 30 - hw, hy, hint, T.outline)

    local close_x = M.W - PAD - 22
    M.rect_close.x, M.rect_close.y = close_x - 4, hy - 2
    M.rect_close.w, M.rect_close.h = 22, lh + 4
    s:text(close_x, hy, "×", T.red)
    s:rect(0, M.HEADER_H - 1, M.W, 1, T.outline)

    local y = M.HEADER_H + 12

    local pct = M.cur_cpu_agg or 0
    s:text(PAD, y, "CPU", T.on_var)
    draw_bar(s, bar_x, y + math.floor((lh - M.BAR_H) / 2),
             bar_w, M.BAR_H, pct, load_color(pct))
    s:text(M.W - PAD - PCT_W, y, string.format("%6.1f%%", pct), T.on_surface)
    y = y + M.ROW_H

    s:rect(PAD, y, inner_w, M.SPARK_H, THEME.track)
    local slot_w = inner_w / HISTORY_LEN
    for i = 0, HISTORY_LEN - 1 do
        local idx = ((M.history_head + i) % HISTORY_LEN) + 1
        local v = M.history[idx] or 0
        local bh = math.floor((M.SPARK_H - 2) * v / 100)
        if bh > 0 then
            local bx = math.floor(PAD + i * slot_w)
            local by = y + M.SPARK_H - 1 - bh
            local bw = math.max(1, math.floor(slot_w) - 1)
            s:rect(bx, by, bw, bh, load_color(v))
        end
    end
    y = y + M.SPARK_H + 12

    for i = 1, M.ncores_display do
        local v = M.cur_cores[i] or 0
        s:text(PAD, y, string.format("c%-2d", i - 1), T.outline)
        draw_bar(s, bar_x, y + math.floor((lh - 4) / 2),
                 bar_w, 4, v, load_color(v))
        s:text(M.W - PAD - PCT_W, y, string.format("%6.1f%%", v), T.on_var)
        y = y + M.CORE_H
    end
    y = y + 8
    s:rect(PAD, y, inner_w, 1, T.outline)
    y = y + 10

    local mem = M.cur_mem or {}
    local mem_total = mem.MemTotal or 1
    local mem_avail = mem.MemAvailable or mem.MemFree or 0
    local mem_used = mem_total - mem_avail
    local mem_pct = mem_used / mem_total * 100

    s:text(PAD, y, "内存", T.on_var)
    draw_bar(s, bar_x, y + math.floor((lh - M.BAR_H) / 2),
             bar_w, M.BAR_H, mem_pct, load_color(mem_pct))
    local mem_str = string.format("%s/%s %3.0f%%",
        fmt_bytes_kb(mem_used), fmt_bytes_kb(mem_total), mem_pct)
    local mw = select(1, M.ctx.get_text_size(mem_str))
    s:text(M.W - PAD - mw, y, mem_str, T.on_surface)
    y = y + M.ROW_H

    local swp_total = mem.SwapTotal or 0
    local swp_free = mem.SwapFree or 0
    local swp_used = swp_total - swp_free
    local swp_pct = swp_total > 0 and (swp_used / swp_total * 100) or 0
    s:text(PAD, y, "交换", T.on_var)
    draw_bar(s, bar_x, y + math.floor((lh - M.BAR_H) / 2),
             bar_w, M.BAR_H, swp_pct, load_color(swp_pct))
    local swp_str = swp_total > 0 and
        string.format("%s/%s %3.0f%%",
            fmt_bytes_kb(swp_used), fmt_bytes_kb(swp_total), swp_pct)
        or "--"
    local sw = select(1, M.ctx.get_text_size(swp_str))
    s:text(M.W - PAD - sw, y, swp_str, T.on_surface)
    y = y + M.ROW_H + 10
    s:rect(PAD, y, inner_w, 1, T.outline)
    y = y + 10

    local pid_x = PAD
    local name_x = PAD + 90
    local cpu_x = PAD + 440
    local mem_x = PAD + 520
    s:text(pid_x, y, "PID", T.outline)
    s:text(name_x, y, "NAME", T.outline)
    s:text(cpu_x, y, "CPU%", T.outline)
    s:text(mem_x, y, "MEM%", T.outline)

    M.rect_list.x = PAD
    M.rect_list.y = y + M.ROW_H
    M.rect_list.w = inner_w - 8
    M.rect_list.h = M.VISIBLE_ROWS * M.ROW_H
    y = y + M.ROW_H

    local row_h = M.ROW_H
    local name_max_w = cpu_x - name_x - 12
    M:clamp_scroll()
    for i = 0, M.VISIBLE_ROWS - 1 do
        local idx = M.scroll + i + 1
        if idx > #M.filtered then break end
        local proc = M.filtered[idx]
        local ry = y + i * row_h
        local selected = (proc.pid == M.selected_pid)
        if selected then
            s:rect(PAD - 4, ry, inner_w + 8, row_h, THEME.select)
        end
        s:text(pid_x, ry, string.format("%-7d", proc.pid),
               selected and T.on_surface or T.on_var)
        local name = proc.name
        if select(1, M.ctx.get_text_size(name)) > name_max_w then
            local cut = #name
            while cut > 0 do
                if select(1, M.ctx.get_text_size(
                        name:sub(1, cut) .. "…")) <= name_max_w then
                    name = name:sub(1, cut) .. "…"
                    break
                end
                cut = cut - 1
            end
        end
        s:text(name_x, ry, name, T.on_surface)
        local cpu_col = proc.cpu >= 80 and T.red
                     or proc.cpu >= 30 and T.yellow or T.green
        s:text(cpu_x, ry, string.format("%6.1f", proc.cpu), cpu_col)
        local mp = proc.mem / (mem_total * 1024) * 100
        s:text(mem_x, ry, string.format("%6.1f%%", mp), T.on_var)
    end

    local list_top = M.rect_list.y
    local list_h = M.rect_list.h
    local sbar_x = M.rect_list.x + M.rect_list.w + 2
    if #M.filtered > M.VISIBLE_ROWS then
        s:rect(sbar_x, list_top, 6, list_h, THEME.track)
        local bar_h = math.max(30,
            math.floor(list_h * M.VISIBLE_ROWS / #M.filtered))
        local max_scroll = #M.filtered - M.VISIBLE_ROWS
        local bar_y = list_top +
            math.floor((list_h - bar_h) * M.scroll / max_scroll)
        s:rrect(sbar_x, bar_y, 6, bar_h, 3, T.outline)
    end

    local by = M.H - M.FOOTER_H + 4
    s:rect(PAD, by - 6, inner_w, 1, T.outline)
    local total = #M.procs
    local shown = #M.filtered
    local status = (shown < total)
        and string.format("筛选 %d / %d · Ctrl+F 搜索 · Ctrl+K 杀进程 · PgUp/PgDn 翻页",
                          shown, total)
        or  string.format("%d 进程 · Ctrl+F 搜索 · Ctrl+K 杀进程 · PgUp/PgDn 翻页",
                          total)
    s:text(PAD, by + 4, status, T.outline)
end

function M.shutdown()
    if M.panel then
        if M.panel.visible then M.panel:hide() end
        M.panel:destroy()
    end
    M.ready = false
end

return M
