local SCRIPT_DIR = (arg[0] or "xpet.lua"):match("^(.*)/[^/]*$") or "."
if SCRIPT_DIR == "" then
    SCRIPT_DIR = "."
end
package.path = SCRIPT_DIR .. "/?.lua;" .. package.path
package.cpath = SCRIPT_DIR .. "/?.so;" .. package.cpath

local ffi_init = require("core.ffi_init")(SCRIPT_DIR)
local x11_helpers = require("core.x11_helpers")
local canvas_mod = require("core.canvas")
local pet_mod = require("core.pet")
local plugin_mgr = require("core.plugin_mgr")

local ffi = ffi_init.ffi
local bit = ffi_init.bit
local X11 = ffi_init.X11
local FT = ffi_init.FT
local AUD = ffi_init.AUD
local libc = ffi_init.libc

local function log(fmt, ...)
    io.stderr:write("[xpet] " .. string.format(fmt, ...) .. "\n")
end

local function expand_tilde(p)
    if p and p:sub(1, 1) == "~" then
        return (os.getenv("HOME") or "") .. p:sub(2)
    end
    return p
end

local function resolve_path(p)
    p = expand_tilde(p or "")
    if p == "" then
        return p
    end
    if p:sub(1, 1) == "/" then
        return p
    end
    return SCRIPT_DIR .. "/" .. p
end

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then
        f:close();
        return true
    end
    return false
end

local CONFIG_PATH = (arg[1] and arg[1] ~= "") and resolve_path(arg[1]) or (SCRIPT_DIR .. "/config.lua")
if not file_exists(CONFIG_PATH) then
    error("config not found: " .. CONFIG_PATH)
end

local function load_config()
    local chunk, err = loadfile(CONFIG_PATH)
    if not chunk then
        error("load config: " .. tostring(err))
    end
    local ok, cfg = pcall(chunk)
    if not ok then
        error("run config: " .. tostring(cfg))
    end
    if type(cfg) ~= "table" then
        error("config must return a table")
    end

    cfg.pet_asset_dir = resolve_path(cfg.pet_asset_dir)
    cfg.audio_panel_dir = resolve_path(cfg.audio_panel_dir)
    cfg.font_path = resolve_path(cfg.font_path)
    cfg.click_audio_to_play = cfg.click_audio_to_play and resolve_path(cfg.click_audio_to_play) or nil
    cfg.fallback_font_paths = cfg.fallback_font_paths or {}
    for i, p in ipairs(cfg.fallback_font_paths) do
        cfg.fallback_font_paths[i] = resolve_path(p)
    end
    return cfg
end

local config = load_config()
log("config: %s", CONFIG_PATH)

local d = x11_helpers.open(ffi_init)
log("X11: %dx%d depth=%d", d.scr_w, d.scr_h, d.depth)

if FT.xft_init() ~= 0 then
    error("FreeType init failed")
end

local function load_font(cfg)
    local fb_joined = table.concat(cfg.fallback_font_paths or {}, "\n")
    return FT.xft_load(cfg.font_path, cfg.font_size or 24, #fb_joined > 0 and fb_joined or nil)
end

local ft_ctx = load_font(config)
if ft_ctx == nil then
    error("font load failed: " .. tostring(config.font_path))
end
log("font: %s @ %d", config.font_path, config.font_size or 24)

local listeners = {}
local actions = {}

local ctx = {
    SCRIPT_DIR = SCRIPT_DIR,
    ffi = ffi,
    bit = bit,
    X11 = X11,
    Xext = ffi_init.Xext,
    Xpm = ffi_init.Xpm,
    FT = FT,
    AUD = AUD,
    libc = libc,
    config = config,
    dpy = d.dpy,
    screen = d.screen,
    root = d.root,
    depth = d.depth,
    black = d.black,
    white = d.white,
    scr_w = d.scr_w,
    scr_h = d.scr_h,
    ft_ctx = ft_ctx,
    log = log,
    actions = actions
}

function ctx.on(event, fn)
    listeners[event] = listeners[event] or {}
    listeners[event][#listeners[event] + 1] = fn
end

function ctx.emit(event, ...)
    local ls = listeners[event]
    if not ls then
        return
    end
    for _, fn in ipairs(ls) do
        local ok, err = pcall(fn, ...)
        if not ok then
            log("listener error [%s]: %s", event, tostring(err))
        end
    end
end

function ctx.register_action(name, fn)
    actions[name] = fn
end

function ctx.get_text_size(text)
    local w = ffi.new("int[1]")
    local h = ffi.new("int[1]")
    FT.xft_text_extent(ft_ctx, text, w, h)
    return w[0], h[0]
end

function ctx.get_line_height()
    return FT.xft_line_height(ft_ctx)
end

function ctx.get_primary_line_height()
    return FT.xft_primary_line_height(ft_ctx)
end

function ctx.create_canvas(w, h, opts)
    return canvas_mod.new(ctx, w, h, opts)
end

if AUD then
    local rc = AUD.audio_init()
    if rc ~= 0 then
        log("audio_init failed: %d (click sound disabled)", rc)
    else
        log("audio subsystem initialized")
    end
end

local pet = pet_mod.new(ctx)
pet:create_window()
ctx.pet = pet

ctx.show_bubble = function(text, opts)
    pet:show_bubble(text, opts)
end

actions.quit = function()
    plugin_mgr.shutdown()
    ctx.emit("shutdown")
    if AUD then
        AUD.audio_shutdown()
    end -- <-- ADD THIS LINE
    pet:destroy()
    FT.xft_done(ft_ctx)
    X11.XCloseDisplay(d.dpy)
    os.exit(0)
end

actions.toggle_chase = function()
    pet:toggle_chase()
end
actions.toggle_freeze = function()
    pet:toggle_freeze()
end
actions.say_hello = function()
    pet:show_bubble("hello world 😀🎉")
end

plugin_mgr.load_all(config.plugins or {}, ctx)

-- ============================================================
-- Keybind registration (re-usable for hot reload)
-- ============================================================
local AnyModifier = 0x8000

local MASK_NAMES = {
    shift = 0x1,
    lock = 0x2,
    caps = 0x2,
    ctrl = 0x4,
    control = 0x4,
    alt = 0x8,
    mod1 = 0x8,
    mod2 = 0x10,
    num = 0x10,
    mod3 = 0x20,
    super = 0x40,
    mod4 = 0x40,
    win = 0x40,
    cmd = 0x40,
    meta = 0x40,
    mod5 = 0x80,
    shiftmask = 0x1,
    lockmask = 0x2,
    controlmask = 0x4,
    mod1mask = 0x8,
    mod2mask = 0x10,
    mod3mask = 0x20,
    mod4mask = 0x40,
    mod5mask = 0x80
}

local function parse_mods(s)
    if type(s) ~= "string" then
        return nil
    end
    local mask = 0
    for part in s:gmatch("[^+]+") do
        part = part:match("^%s*(.-)%s*$"):lower()
        local m = MASK_NAMES[part]
        if not m then
            return nil
        end
        mask = bit.bor(mask, m)
    end
    return mask == 0 and nil or mask
end

local KEYCODE_TO_ACTION = {}
local lock_variants = {0, 0x2, 0x10, bit.bor(0x2, 0x10)}

local function rebuild_keybinds()
    for k in pairs(KEYCODE_TO_ACTION) do
        KEYCODE_TO_ACTION[k] = nil
    end
    X11.XUngrabKey(d.dpy, 0, AnyModifier, d.root)

    for _, kb in ipairs(config.keybinds or {}) do
        local mask = parse_mods(kb.mod)
        if not mask then
            log("unknown modifier: %s", tostring(kb.mod))
        else
            local sym = X11.XStringToKeysym(kb.key)
            local code = X11.XKeysymToKeycode(d.dpy, sym)
            if code == 0 then
                log("unknown key: %s", tostring(kb.key))
            else
                KEYCODE_TO_ACTION[code] = kb.action
                for _, extra in ipairs(lock_variants) do
                    X11.XGrabKey(d.dpy, code, bit.bor(mask, extra), d.root, 0, 1, 1)
                end
            end
        end
    end
    X11.XFlush(d.dpy)
    X11.XSync(d.dpy, 0)
end

rebuild_keybinds()

-- ============================================================
-- Hot reload
-- ============================================================
local function do_hot_reload(silent)
    local ok, newcfg = pcall(load_config)
    if not ok then
        log("hot reload failed (config): %s", tostring(newcfg))
        if not silent then
            ctx.show_bubble("reload failed: config 😢")
        end
        return false
    end

    -- (a) Font changed?
    local font_changed = newcfg.font_path ~= config.font_path or newcfg.font_size ~= config.font_size
    if not font_changed then
        local a = table.concat(config.fallback_font_paths or {}, "\n")
        local b = table.concat(newcfg.fallback_font_paths or {}, "\n")
        font_changed = (a ~= b)
    end

    -- (b) Pet asset dir or scale changed?
    local pet_changed = newcfg.pet_asset_dir ~= config.pet_asset_dir or (newcfg.scale_factor or 1) ~=
                            (config.scale_factor or 1) or (newcfg.frame_duration or 200) ~=
                            (config.frame_duration or 200)

    -- swap config refs BEFORE anything that reads it
    config = newcfg
    ctx.config = config
    pet:set_config(config) -- <-- ADD THIS LINE

    if font_changed then
        local new_ctx = load_font(config)
        if new_ctx then
            FT.xft_done(ft_ctx)
            ft_ctx = new_ctx
            ctx.ft_ctx = new_ctx
            log("font reloaded")
        else
            log("font reload failed, keeping old")
        end
    end

    if pet_changed then
        pet:reload_animations(config)
        log("pet reloaded (scale=%s)", tostring(config.scale_factor))
    end

    plugin_mgr.reload(ctx)
    rebuild_keybinds()

    if not silent then
        ctx.show_bubble("hot reload done 🚀")
    end
    return true
end

actions.hot_reload = function()
    do_hot_reload(false)
end

actions.toggle_auto_reload = function()
    local on = not plugin_mgr.watch_enabled
    plugin_mgr.set_watch(on)
    if on then
        plugin_mgr.snapshot_mtimes(ctx)
        ctx.show_bubble("auto-reload ON 👀")
    else
        ctx.show_bubble("auto-reload OFF 💤")
    end
end

-- ============================================================
-- Main loop
-- ============================================================
local ev = ffi.new("XEvent")
local FRAME_MS = 16
local WATCH_INTERVAL_MS = 800
local watch_accum = 0

log("xpet running (Alt+R = hot reload, Alt+Shift+R = toggle auto-reload)")

while true do
    while X11.XPending(d.dpy) > 0 do
        X11.XNextEvent(d.dpy, ev)
        local t = ev.type
        if t == 2 then
            local action = KEYCODE_TO_ACTION[ev.xkey.keycode]
            if action and actions[action] then
                local ok, err = pcall(actions[action])
                if not ok then
                    log("action error: %s", tostring(err))
                end
            end
        else
            pet:handle_event(t, ev)
            ctx.emit("xevent", t, ev)
        end
    end

    -- Auto hot-reload: periodic file mtime check
    if plugin_mgr.watch_enabled then
        watch_accum = watch_accum + FRAME_MS
        if watch_accum >= WATCH_INTERVAL_MS then
            watch_accum = 0
            if plugin_mgr.check_changes(ctx) then
                log("auto-reload triggered")
                do_hot_reload(true)
            end
        end
    end

    pet:tick(FRAME_MS)
    ctx.emit("tick", FRAME_MS)
    libc.usleep(FRAME_MS * 1000)
end
