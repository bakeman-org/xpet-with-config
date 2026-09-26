local M = {}
local UI = require("core.ui")
local Surface = require("core.surface")
local ffi = require("ffi")

local REFRESH_MS   = 1000
local HISTORY_LEN  = 60
local MAX_CORES    = 8
local CLK_TCK      = 100
local PAGE_SIZE    = 4096
local PROC_FETCH_N = 200

local CTRL_MASK     = 0x4
local LOCK_VARIANTS = { 0, 0x2, 0x10, 0x12 }
local XK_BackSpace  = 0xff08
local XK_Return     = 0xff0d
local XK_Escape     = 0xff1b
local XK_Up         = 0xff52
local XK_Down       = 0xff54
local XK_Page_Up    = 0xff55
local XK_Page_Down  = 0xff56
local XK_Home       = 0xff50
local XK_End        = 0xff57

local THEME = {
    bg = 0x141218, surface = 0x1d1b20, surface_hi = 0x2b2930,
    primary = 0xb69eff, primary_hi = 0xcfbcff, on_surface = 0xe6e1e5,
    on_var = 0xcac4d0, outline = 0x49454f,
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
                        if d > 0 then cpu_pct = d / CLK_TCK / dt_sec * 100 end
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

function M:_grab_ctrl_f()
    if M._grabbed then return end
    local X = M.ctx.X11
    local dpy = M.ctx.dpy
    if not M._code_f or M._code_f == 0 then return end
    for _, extra in ipairs(LOCK_VARIANTS) do
        X.XGrabKey(dpy, M._code_f, M.ctx.bit.bor(CTRL_MASK, extra),
                   M.ctx.root, 0, 1, 1)
    end
    X.XFlush(dpy)
    M._grabbed = true
end

function M:_ungrab_ctrl_f()
    if not M._grabbed then return end
    local X = M.ctx.X11
    local dpy = M.ctx.dpy
    if not M._code_f or M._code_f == 0 then return end
    for _, extra in ipairs(LOCK_VARIANTS) do
        X.XUngrabKey(dpy, M._code_f, M.ctx.bit.bor(CTRL_MASK, extra),
                     M.ctx.root)
    end
    X.XFlush(dpy)
    M._grabbed = false
end

function M.init(ctx)
    M.ctx = ctx
    M.ready = true
    M.visible = false

    local lh = ctx.get_primary_line_height()
    M.LH = lh

    local probe = read_cpu_stat()
    local ncores_all = probe and #probe.cores or 4
    M.ncores_display = math.min(MAX_CORES, ncores_all)

    local L = compute_layout(lh, M.ncores_display, ctx.scr_h)
    for k, v in pairs(L) do M[k] = v end

    M.X = math.floor((ctx.scr_w - M.W) / 2)
    M.Y_SHOWN = math.max(10, math.floor((ctx.scr_h - M.H) / 2))
    M.Y_HIDDEN = -(M.H + 4)

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
    M.search_active = false
    M.search_query = ""

    M.anim_y = M.Y_HIDDEN
    M.target_y = M.Y_HIDDEN
    M.refresh_acc = 0

    M.rect_search = { x = 0, y = 0, w = 0, h = 0 }
    M.rect_close  = { x = 0, y = 0, w = 0, h = 0 }
    M.rect_list   = { x = 0, y = 0, w = 0, h = 0 }

    -- 缓存 Ctrl+F 的 keycode
    M._code_f = ctx.X11.XKeysymToKeycode(ctx.dpy,
                ctx.X11.XStringToKeysym("f"))
    M._grabbed = false

    M.surf = Surface.new(ctx, M.W, M.H)
    M.ui = UI.new(ctx, THEME)
    M.ui:attach(M.surf)

    M.canvas = ctx.create_canvas(M.W, M.H, {
        x = M.X, y = M.Y_HIDDEN,
        bg = THEME.bg, border = THEME.bg, border_width = 1,
    })

    ctx.register_action("toggle_sysmon", function() M.toggle() end)
    ctx.on("tick", function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) M.on_ev(t, ev) end)

    M.prev_cpu = read_cpu_stat()
    for _, pid in ipairs(list_pids()) do
        local p = read_proc(pid)
        if p then
            M.prev_procs[pid] = { utime = p.utime, stime = p.stime }
        end
    end
end

function M:_close()
    M.visible = false
    M.target_y = M.Y_HIDDEN
    M.search_active = false
    M:_ungrab_ctrl_f()
end

function M.toggle()
    if not M.ready then return end
    M.visible = not M.visible
    if M.visible then
        M:_grab_ctrl_f()
        M:sample()
        M.anim_y = M.Y_HIDDEN
        M.target_y = M.Y_SHOWN
        M.canvas:move(M.X, math.floor(M.anim_y))
        M.canvas:show()
        M.draw()
    else
        M:_close()
    end
end

function M.on_ev(t, ev)
    if not M.ready then return end

    -- 键盘：无论是否可见都接受（Ctrl+F 只在可见时 grab）
    if t == 2 then
        if not M.visible then return end

        if M.search_active then
            local sym = M.ctx.X11.XLookupKeysym(
                ffi.cast("XKeyEvent*", ev), 0)
            if sym == XK_Escape then
                M.search_active = false
                M.search_query = ""
                M:apply_filter()
            elseif sym == XK_Return then
                M.search_active = false
            elseif sym == XK_BackSpace then
                if #M.search_query > 0 then
                    M.search_query = M.search_query:sub(1, -2)
                end
                M:apply_filter()
            elseif sym == XK_Up then
                M.scroll = math.max(0, M.scroll - 1)
            elseif sym == XK_Down then
                M.scroll = M.scroll + 1
                M:clamp_scroll()
            elseif sym == XK_Page_Up then
                M.scroll = math.max(0, M.scroll - M.VISIBLE_ROWS)
            elseif sym == XK_Page_Down then
                M.scroll = M.scroll + M.VISIBLE_ROWS
                M:clamp_scroll()
            elseif sym == XK_Home then
                M.scroll = 0
            elseif sym == XK_End then
                M.scroll = math.max(0, #M.filtered - M.VISIBLE_ROWS)
            elseif sym >= 0x20 and sym <= 0x7e then
                M.search_query = M.search_query .. string.char(sym)
                M:apply_filter()
            end
            M.draw()
            return
        end

        -- 未激活：Ctrl+F 打开搜索
        if ev.xkey.keycode == M._code_f then
            M.search_active = true
            M.search_query = ""
            M:apply_filter()
            M.draw()
        end
        return
    end

    if not M.visible then return end

    if t == 12 and ev.xexpose.window == M.canvas.win then
        M.draw()
        return
    end

    if t == 4 or t == 5 then
        if ev.xbutton.window ~= M.canvas.win then return end
    elseif t == 6 then
        if ev.xmotion.window ~= M.canvas.win then return end
    else
        return
    end

    M.ui:on_event(t, ev)

    if t == 4 then
        local mx, my = ev.xbutton.x, ev.xbutton.y
        local btn = ev.xbutton.button

        if btn == 4 then
            M.scroll = math.max(0, M.scroll - 3)
            M.draw(); return
        elseif btn == 5 then
            M.scroll = M.scroll + 3
            M:clamp_scroll(); M.draw(); return
        end

        local function in_rect(r)
            return mx >= r.x and mx < r.x + r.w
               and my >= r.y and my < r.y + r.h
        end

        if in_rect(M.rect_close) then
            M:_close(); return
        end

        if in_rect(M.rect_search) then
            M.search_active = true
            M.draw(); return
        end

        if in_rect(M.rect_list) then
            local row = math.floor((my - M.rect_list.y) / M.ROW_H)
            local idx = M.scroll + row + 1
            if idx >= 1 and idx <= #M.filtered then
                M.selected_pid = M.filtered[idx].pid
                M.search_active = false
                if btn == 3 then M:kill_selected() end
            end
            M.draw(); return
        end

        if M.search_active then
            M.search_active = false
            M.draw()
        end
    end
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

function M.tick(dt_ms)
    if not M.ready then return end

    if M.anim_y ~= M.target_y then
        local d = M.target_y - M.anim_y
        if math.abs(d) < 1.5 then M.anim_y = M.target_y
        else M.anim_y = M.anim_y + d * 0.3 end
        M.canvas:move(M.X, math.floor(M.anim_y))
        if M.anim_y == M.target_y and M.target_y < 0 then
            M.canvas:hide()
            return
        end
    end

    if not M.visible then return end

    M.refresh_acc = M.refresh_acc + dt_ms
    if M.refresh_acc >= REFRESH_MS then
        M.refresh_acc = 0
        M:sample()
        M.draw()
    end
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

function M.draw()
    if not M.surf then return end
    local ui, s, T = M.ui, M.surf, M.ui.theme
    local lh, PAD = M.LH, M.PAD
    local inner_w = M.W - PAD * 2
    local LABEL_W, PCT_W = M.LABEL_W, M.PCT_W
    local bar_x = PAD + LABEL_W
    local bar_w = inner_w - LABEL_W - PCT_W - 8

    s:clear(T.bg)
    ui:begin()

    -- Header
    s:rect(0, 0, M.W, M.HEADER_H, T.surface)
    local hy = math.floor((M.HEADER_H - lh) / 2)
    s:text(PAD, hy, "系统监视", T.primary)

    local search_x = PAD + 110
    local search_w = M.W - search_x - 200
    local search_h = lh + 4
    local search_y = math.floor((M.HEADER_H - search_h) / 2)
    M.rect_search.x, M.rect_search.y = search_x, search_y
    M.rect_search.w, M.rect_search.h = search_w, search_h
    s:rrect(search_x, search_y, search_w, search_h,
            math.floor(search_h / 2), T.search_bg)
    local search_text
    if M.search_active then
        search_text = M.search_query .. "█"
    elseif M.search_query ~= "" then
        search_text = M.search_query
    else
        search_text = "Ctrl+F 搜索进程名或 PID"
    end
    s:text(search_x + 12,
           math.floor(search_y + (search_h - lh) / 2),
           search_text,
           M.search_active and T.on_surface or T.outline)

    local hint = "Ctrl+Alt+T"
    local hw = select(1, M.ctx.get_text_size(hint))
    s:text(M.W - PAD - 30 - hw, hy, hint, T.outline)

    local close_x = M.W - PAD - 22
    M.rect_close.x, M.rect_close.y = close_x - 4, hy - 2
    M.rect_close.w, M.rect_close.h = 22, lh + 4
    s:text(close_x, hy, "✕", T.red)
    s:rect(0, M.HEADER_H - 1, M.W, 1, T.outline)

    local y = M.HEADER_H + 12

    -- CPU
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

    -- Mem
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

    -- 进程表头
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
        local p = M.filtered[idx]
        local ry = y + i * row_h
        local selected = (p.pid == M.selected_pid)
        if selected then
            s:rect(PAD - 4, ry, inner_w + 8, row_h, THEME.select)
        end
        s:text(pid_x, ry, string.format("%-7d", p.pid),
               selected and T.on_surface or T.on_var)
        local name = p.name
        if select(1, M.ctx.get_text_size(name)) > name_max_w then
            local cut = #name
            while cut > 0 do
                if select(1, M.ctx.get_text_size(
                        name:sub(1, cut) .. "…")) <= name_max_w then
                    name = name:sub(1, cut) .. "…"; break
                end
                cut = cut - 1
            end
        end
        s:text(name_x, ry, name, T.on_surface)
        local cpu_col = p.cpu >= 80 and T.red
                     or p.cpu >= 30 and T.yellow or T.green
        s:text(cpu_x, ry, string.format("%6.1f", p.cpu), cpu_col)
        local mp = p.mem / (mem_total * 1024) * 100
        s:text(mem_x, ry, string.format("%6.1f%%", mp), T.on_var)
    end

    -- 滚动条
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

    -- Footer
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

    ui:end_frame()
    s:flush(M.canvas.win, M.canvas.wgc, 0, 0)
end

function M.shutdown()
    M:_ungrab_ctrl_f()
    M.ready = false
    if M.surf then M.surf:destroy() end
    if M.canvas then M.canvas:destroy() end
end

return M