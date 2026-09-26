local M = {}
local ffi = require("ffi")
local bit = require("bit")

local STATE_NAMES = {"idle", "sleeping", "dragged", "happy", "walk_north", "walk_south", "walk_east", "walk_west",
                     "walk_northwest", "walk_northeast", "walk_southwest", "walk_southeast"}

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then
        f:close();
        return true
    end
    return false
end

function M.new(ctx)
    local X11 = ctx.X11
    local Xext = ctx.Xext
    local Xpm = ctx.Xpm
    local FT = ctx.FT
    local dpy = ctx.dpy
    local root = ctx.root
    local depth = ctx.depth
    local scr_w = ctx.scr_w
    local scr_h = ctx.scr_h
    local config = ctx.config
    local black = ctx.black
    local white = ctx.white
    local log = ctx.log

    local pet = {
        win = nil,
        gc = nil,
        state = "idle",
        frame = 1,
        frame_time = 0,
        x = math.floor(scr_w / 2),
        y = math.floor(scr_h / 2),
        w = 64,
        h = 64,
        chasing = false,
        frozen = false,
        dragging = false,
        drag_off_x = 0,
        drag_off_y = 0,
        target_x = 0,
        target_y = 0,
        wander_wait = 0,
        animations = {},
        bubble = nil,
        bubble_win = nil,
        bubble_gc = nil,
        bubble_until = 0
    }

    local function scale_pixmap(src, sw, sh, scale)
        if scale <= 1 then
            return src
        end
        local dw, dh = sw * scale, sh * scale
        local dest = X11.XCreatePixmap(dpy, root, dw, dh, depth)
        local gc = X11.XCreateGC(dpy, dest, 0, nil)
        local img = X11.XGetImage(dpy, src, 0, 0, sw, sh, 0xFFFFFFFF, 2)
        if img ~= nil then
            for yy = 0, sh - 1 do
                for xx = 0, sw - 1 do
                    local pixel = X11.XGetPixel(img, xx, yy)
                    X11.XSetForeground(dpy, gc, pixel)
                    X11.XFillRectangle(dpy, dest, gc, xx * scale, yy * scale, scale, scale)
                end
            end
            X11.XDestroyImage(img)
        end
        X11.XFreeGC(dpy, gc)
        return dest
    end

    local function scale_mask(src, sw, sh, scale)
        if scale <= 1 then
            return src
        end
        local dw, dh = sw * scale, sh * scale
        local dest = X11.XCreatePixmap(dpy, root, dw, dh, 1)
        local gc = X11.XCreateGC(dpy, dest, 0, nil)
        local img = X11.XGetImage(dpy, src, 0, 0, sw, sh, 0xFFFFFFFF, 2)
        if img ~= nil then
            for yy = 0, sh - 1 do
                for xx = 0, sw - 1 do
                    local pixel = bit.band(X11.XGetPixel(img, xx, yy), 1)
                    X11.XSetForeground(dpy, gc, pixel)
                    X11.XFillRectangle(dpy, dest, gc, xx * scale, yy * scale, scale, scale)
                end
            end
            X11.XDestroyImage(img)
        end
        X11.XFreeGC(dpy, gc)
        return dest
    end

    local function load_frames(dir, scale)
        scale = scale or 1
        local frames = {}
        local i = 0
        while true do
            local path = string.format("%s/%d.xpm", dir, i)
            if not file_exists(path) then
                break
            end
            local pix_out = ffi.new("Pixmap[1]")
            local mask_out = ffi.new("Pixmap[1]")
            local rc = Xpm.XpmReadFileToPixmap(dpy, root, path, pix_out, mask_out, nil)
            if rc ~= 0 then
                log("XPM read failed: %s (rc=%d)", path, rc)
                break
            end
            local src_pix = pix_out[0]
            local src_mask = mask_out[0]
            local root_ret = ffi.new("Window[1]")
            local xi, yi = ffi.new("int[1]"), ffi.new("int[1]")
            local ww, hh = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
            local bw_, dd_ = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
            X11.XGetGeometry(dpy, src_pix, root_ret, xi, yi, ww, hh, bw_, dd_)
            local sw, sh = ww[0], hh[0]
            if scale > 1 then
                local sp = scale_pixmap(src_pix, sw, sh, scale)
                local sm = scale_mask(src_mask, sw, sh, scale)
                X11.XFreePixmap(dpy, src_pix)
                X11.XFreePixmap(dpy, src_mask)
                frames[#frames + 1] = {
                    pix = sp,
                    mask = sm,
                    w = sw * scale,
                    h = sh * scale
                }
            else
                frames[#frames + 1] = {
                    pix = src_pix,
                    mask = src_mask,
                    w = sw,
                    h = sh
                }
            end
            i = i + 1
        end
        return frames
    end

    function pet:load_animations()
        for _, name in ipairs(STATE_NAMES) do
            local dir = string.format("%s/%s", config.pet_asset_dir, name)
            local frames = load_frames(dir, config.scale_factor or 1)
            if #frames == 0 then
                if pet.animations.idle then
                    frames = pet.animations.idle
                else
                    log("warning: no frames for state '%s'", name)
                end
            end
            pet.animations[name] = frames
        end
        log("animations: idle=%d frames", #(pet.animations.idle or {}))
    end

    function pet:current_frames()
        return pet.animations[pet.state] or pet.animations.idle or {}
    end

    function pet:current_frame()
        local fs = pet:current_frames()
        return fs[pet.frame] or fs[1]
    end

    function pet:create_window()
        local f = pet:current_frame()
        if not f then
            error("no frames available")
        end
        pet.w, pet.h = f.w, f.h
        local attrs = ffi.new("XSetWindowAttributes")
        attrs.override_redirect = 1
        attrs.background_pixmap = f.pix
        attrs.border_pixel = 0
        local mask = 0x0200 + 0x0001 + 0x0008
        pet.win = X11.XCreateWindow(dpy, root, pet.x, pet.y, pet.w, pet.h, 0, depth, 1, nil, mask, attrs)
        X11.XSelectInput(dpy, pet.win, 0x00008000 + 0x00000004 + 0x00000008 + 0x00000040)
        Xext.XShapeCombineMask(dpy, pet.win, 0, 0, 0, f.mask, 0)
        X11.XSetWindowBackgroundPixmap(dpy, pet.win, f.pix)
        X11.XMapWindow(dpy, pet.win)
        X11.XRaiseWindow(dpy, pet.win)
        X11.XFlush(dpy)
        pet.gc = X11.XCreateGC(dpy, pet.win, 0, nil)
    end

    function pet:apply_frame()
        local f = pet:current_frame()
        if not f then
            return
        end
        Xext.XShapeCombineMask(dpy, pet.win, 0, 0, 0, f.mask, 0)
        X11.XSetWindowBackgroundPixmap(dpy, pet.win, f.pix)
        X11.XClearWindow(dpy, pet.win)
    end

    function pet:set_state(name)
        if pet.state ~= name and pet.animations[name] and #pet.animations[name] > 0 then
            pet.state = name
            pet.frame = 1
            pet.frame_time = 0
            pet:apply_frame()
        end
    end

    function pet:tick(dt_ms)
        local fs = pet:current_frames()
        if #fs == 0 then
            return
        end
        pet.frame_time = pet.frame_time + dt_ms
        if pet.frame_time >= (config.frame_duration or 200) then
            pet.frame_time = 0
            pet.frame = pet.frame % #fs + 1
            pet:apply_frame()
        end
        if pet.bubble then
            pet.bubble_until = pet.bubble_until - dt_ms / 1000
            if pet.bubble_until <= 0 then
                pet:hide_bubble()
            end
        end
        if not pet.dragging and not pet.frozen then
            if pet.chasing then
                local mx, my = pet:query_mouse()
                pet:move_towards(mx, my)
            else
                pet:wander(dt_ms)
            end
        end
    end

    function pet:query_mouse()
        local rr = ffi.new("Window[1]");
        local cr = ffi.new("Window[1]")
        local rx = ffi.new("int[1]");
        local ry = ffi.new("int[1]")
        local wx = ffi.new("int[1]");
        local wy = ffi.new("int[1]")
        local mask = ffi.new("unsigned int[1]")
        X11.XQueryPointer(dpy, root, rr, cr, rx, ry, wx, wy, mask)
        return rx[0], ry[0]
    end

    function pet:direction_from_delta(dx, dy)
        local ax, ay = math.abs(dx), math.abs(dy)
        if ax > ay * 2 then
            return dx > 0 and "walk_east" or "walk_west"
        end
        if ay > ax * 2 then
            return dy > 0 and "walk_south" or "walk_north"
        end
        if dx > 0 then
            return dy < 0 and "walk_northeast" or "walk_southeast"
        else
            return dy < 0 and "walk_northwest" or "walk_southwest"
        end
    end

    function pet:move_towards(tx, ty)
        local dx, dy = tx - pet.x, ty - pet.y
        local dist2 = dx * dx + dy * dy
        if dist2 < 4 then
            pet:set_state("idle");
            return true
        end
        local spd = config.pet_speed or 2
        pet:set_state(pet:direction_from_delta(dx, dy))
        if dist2 <= spd * spd then
            pet.x, pet.y = tx, ty
        else
            local len = math.sqrt(dist2)
            pet.x = pet.x + dx / len * spd
            pet.y = pet.y + dy / len * spd
        end
        X11.XMoveWindow(dpy, pet.win, math.floor(pet.x), math.floor(pet.y))
        return false
    end

    function pet:reload_animations(new_config)
        -- swap closure's config reference so load_frames picks up new scale
        config = new_config

        -- free existing pixmaps
        for _, frames in pairs(pet.animations) do
            for _, fr in ipairs(frames) do
                X11.XFreePixmap(dpy, fr.pix)
                X11.XFreePixmap(dpy, fr.mask)
            end
        end
        pet.animations = {}

        -- tear down old window
        if pet.win then
            X11.XDestroyWindow(dpy, pet.win)
            pet.win = nil
        end
        if pet.gc then
            X11.XFreeGC(dpy, pet.gc)
            pet.gc = nil
        end

        -- reload frames at the new scale
        pet:load_animations()

        -- rebuild window with new frame size
        pet.state = "idle"
        pet.frame = 1
        pet.frame_time = 0
        pet:create_window()
        pet:pick_destination()
    end

    function pet:set_config(new_config)
        config = new_config
    end

    function pet:pick_destination()
        local M_ = 100
        local max_x = math.max(M_, scr_w - M_ - pet.w)
        local max_y = math.max(M_, scr_h - M_ - pet.h)
        pet.target_x = M_ + math.random(0, max_x - M_)
        pet.target_y = M_ + math.random(0, max_y - M_)
        pet.wander_wait = 0
    end

    function pet:wander(dt_ms)
        local WMIN, WMAX = 16000, 32000
        local dx, dy = pet.target_x - pet.x, pet.target_y - pet.y
        if dx * dx + dy * dy < 4 then
            if pet.wander_wait <= 0 then
                pet.wander_wait = WMIN + math.random(0, WMAX - WMIN)
                pet:set_state("idle")
            else
                pet.wander_wait = pet.wander_wait - dt_ms
                if pet.wander_wait <= 0 then
                    pet:pick_destination()
                end
            end
            return
        end
        pet:move_towards(pet.target_x, pet.target_y)
    end

    function pet:toggle_chase()
        pet.chasing = not pet.chasing
        if pet.chasing then
            pet.frozen = false;
            pet:set_state("walk_east")
        else
            pet:pick_destination()
        end
    end

    function pet:toggle_freeze()
        pet.frozen = not pet.frozen
        if pet.frozen then
            pet:set_state("idle")
        end
    end

    -- Bubble
    local BUBBLE_PAD = 14

    function pet:compute_bubble_size(text)
        local tw = ffi.new("int[1]")
        local th = ffi.new("int[1]")
        FT.xft_text_extent(ctx.ft_ctx, text, tw, th)
        return tw[0] + BUBBLE_PAD * 2, th[0] + BUBBLE_PAD * 2 + 6
    end

    function pet:draw_bubble_content()
        if not pet.bubble or not pet.bubble_win then
            return
        end
        local root_ret = ffi.new("Window[1]")
        local xi, yi = ffi.new("int[1]"), ffi.new("int[1]")
        local ww, hh = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
        local bw_, dd_ = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
        X11.XGetGeometry(dpy, pet.bubble_win, root_ret, xi, yi, ww, hh, bw_, dd_)
        local bw, bh = ww[0], hh[0]
        X11.XSetForeground(dpy, pet.bubble_gc, white)
        X11.XFillRectangle(dpy, pet.bubble_win, pet.bubble_gc, 0, 0, bw, bh)
        FT.xft_draw(ctx.ft_ctx, dpy, pet.bubble_win, pet.bubble_gc, BUBBLE_PAD, BUBBLE_PAD - 4, pet.bubble, black, white)
        X11.XSetForeground(dpy, pet.bubble_gc, black)
        X11.XDrawRectangle(dpy, pet.bubble_win, pet.bubble_gc, 0, 0, bw - 1, bh - 1)
    end

    function pet:show_bubble(text)
        if not text or text == "" then
            return
        end
        pet.bubble = text
        pet.bubble_until = 5.0
        local bw, bh = pet:compute_bubble_size(text)
        if not pet.bubble_win then
            local attrs = ffi.new("XSetWindowAttributes")
            attrs.override_redirect = 1
            attrs.background_pixel = white
            attrs.border_pixel = black
            local mask = 0x0200 + 0x0002 + 0x0008
            pet.bubble_win = X11.XCreateWindow(dpy, root, 0, 0, bw, bh, 2, depth, 1, nil, mask, attrs)
            X11.XSelectInput(dpy, pet.bubble_win, 0x00008000)
            pet.bubble_gc = X11.XCreateGC(dpy, pet.bubble_win, 0, nil)
        else
            X11.XResizeWindow(dpy, pet.bubble_win, bw, bh)
        end
        local bx = math.max(10, math.min(pet.x + pet.w / 2 - bw / 2, scr_w - 10 - bw))
        local by = math.max(10, math.min(pet.y - bh - 8, scr_h - 10 - bh))
        X11.XMoveWindow(dpy, pet.bubble_win, math.floor(bx), math.floor(by))
        X11.XMapWindow(dpy, pet.bubble_win)
        X11.XRaiseWindow(dpy, pet.bubble_win)
        pet:draw_bubble_content()
        X11.XFlush(dpy)
    end

    function pet:hide_bubble()
        if pet.bubble_win then
            X11.XUnmapWindow(dpy, pet.bubble_win)
        end
        pet.bubble = nil
        pet.bubble_until = 0
        X11.XFlush(dpy)
    end

    function pet:play_audio()
        if not ctx.AUD then
            return
        end
        local cfg = ctx.config
        if not cfg or not cfg.enable_audio then
            return
        end
        local path = cfg.click_audio_to_play
        if not path or path == "" then
            return
        end
        local f = io.open(path, "rb")
        if not f then
            return
        end
        f:close()
        local rc = ctx.AUD.audio_play_sfx(path, 80)
        if rc < 0 then
            log("audio_play_sfx failed (rc=%d), falling back to ffplay", rc)
            os.execute(string.format("ffplay -nodisp -autoexit -loglevel error '%s' >/dev/null 2>&1 &", path))
        end
    end

    function pet:handle_event(t, ev)
        if t == 4 then
            if ev.xbutton.window == pet.win then
                pet:play_audio()
                if ev.xbutton.button == 1 then
                    pet.dragging = true
                    pet.drag_off_x = ev.xbutton.x
                    pet.drag_off_y = ev.xbutton.y
                    pet:set_state("dragged")
                elseif ev.xbutton.button == 3 then
                    local ph = config.phrases
                    if ph and #ph > 0 then
                        pet:show_bubble(ph[math.random(1, #ph)])
                    end
                end
            end
        elseif t == 5 then
            if ev.xbutton.window == pet.win and ev.xbutton.button == 1 then
                pet.dragging = false
                pet:set_state("idle")
                pet:pick_destination()
            end
        elseif t == 6 then
            if pet.dragging and ev.xmotion.window == pet.win then
                pet.x = ev.xmotion.x_root - pet.drag_off_x
                pet.y = ev.xmotion.y_root - pet.drag_off_y
                X11.XMoveWindow(dpy, pet.win, pet.x, pet.y)
                if pet.bubble and pet.bubble_win then
                    local bw, bh = pet:compute_bubble_size(pet.bubble)
                    local bx = math.max(10, math.min(pet.x + pet.w / 2 - bw / 2, scr_w - 10 - bw))
                    local by = math.max(10, math.min(pet.y - bh - 8, scr_h - 10 - bh))
                    X11.XMoveWindow(dpy, pet.bubble_win, math.floor(bx), math.floor(by))
                end
            end
        elseif t == 12 then
            if ev.xexpose.window == pet.win then
                pet:apply_frame()
            elseif ev.xexpose.window == pet.bubble_win and pet.bubble then
                pet:draw_bubble_content()
            end
        end
    end

    function pet:destroy()
        if pet.bubble_win then
            X11.XDestroyWindow(dpy, pet.bubble_win)
        end
        if pet.win then
            X11.XDestroyWindow(dpy, pet.win)
        end
        if pet.gc then
            X11.XFreeGC(dpy, pet.gc)
        end
        if pet.bubble_gc then
            X11.XFreeGC(dpy, pet.bubble_gc)
        end
        for _, frames in pairs(pet.animations) do
            for _, fr in ipairs(frames) do
                X11.XFreePixmap(dpy, fr.pix)
                X11.XFreePixmap(dpy, fr.mask)
            end
        end
    end

    pet:load_animations()
    pet:pick_destination()
    return pet
end

return M
