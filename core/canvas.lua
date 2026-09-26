local M = {}
local ffi = require("ffi")

function M.new(ctx, w, h, opts)
    opts = opts or {}
    local bg         = opts.bg or 0x1a1b26
    local border     = opts.border or bg
    local border_w   = opts.border_width or 1
    local init_x     = opts.x or math.floor(ctx.scr_w / 2 - w / 2)
    local init_y     = opts.y or math.floor(ctx.scr_h / 2 - h / 2)

    local X11 = ctx.X11
    local dpy = ctx.dpy

    local attrs = ffi.new("XSetWindowAttributes")
    attrs.override_redirect = 1
    attrs.background_pixel  = bg
    attrs.border_pixel      = border

    local mask = 0x0200 + 0x0002 + 0x0008

    local win = X11.XCreateWindow(
        dpy, ctx.root, init_x, init_y, w, h, border_w, ctx.depth, 1, nil, mask, attrs)

    X11.XSelectInput(dpy, win, 0x00008000 + 0x00000004 + 0x00000008 + 0x00000040)

    local pixmap = X11.XCreatePixmap(dpy, win, w, h, ctx.depth)
    local pgc    = X11.XCreateGC(dpy, pixmap, 0, nil)
    local wgc    = X11.XCreateGC(dpy, win, 0, nil)

    local canvas = {
        win = win, w = w, h = h,
        pixmap = pixmap, pgc = pgc, wgc = wgc,
        bg = bg, visible = false,
    }

    function canvas.clear()
        X11.XSetForeground(dpy, pgc, bg)
        X11.XFillRectangle(dpy, pixmap, pgc, 0, 0, w, h)
    end

    function canvas.text(self, x, y_top, str, fg, bg_override)
        local pad_top = 4
        local draw_y  = y_top - pad_top
        ctx.FT.xft_draw(ctx.ft_ctx, dpy, pixmap, pgc, x, draw_y, str,
                        fg, bg_override or bg)
    end

    function canvas.rect(self, x, y, ww, hh, color)
        X11.XSetForeground(dpy, pgc, color)
        X11.XFillRectangle(dpy, pixmap, pgc, x, y, ww, hh)
    end

    -- rounded rectangle via 3 rectangles + 4 arcs (64ths of a degree)
    function canvas.rrect(self, x, y, ww, hh, r, color)
        X11.XSetForeground(dpy, pgc, color)
        if r <= 0 or r * 2 >= ww or r * 2 >= hh then
            X11.XFillRectangle(dpy, pixmap, pgc, x, y, ww, hh)
            return
        end
        local D = 64
        X11.XFillRectangle(dpy, pixmap, pgc, x + r,     y,         ww - 2*r, hh)
        X11.XFillRectangle(dpy, pixmap, pgc, x,         y + r,     r,       hh - 2*r)
        X11.XFillRectangle(dpy, pixmap, pgc, x + ww - r, y + r,    r,       hh - 2*r)
        X11.XFillArc(dpy, pixmap, pgc, x,              y,           2*r, 2*r,  90*D, 90*D)
        X11.XFillArc(dpy, pixmap, pgc, x + ww - 2*r,   y,           2*r, 2*r,   0,   90*D)
        X11.XFillArc(dpy, pixmap, pgc, x,              y + hh - 2*r, 2*r, 2*r, 180*D, 90*D)
        X11.XFillArc(dpy, pixmap, pgc, x + ww - 2*r,   y + hh - 2*r, 2*r, 2*r, 270*D, 90*D)
    end

    function canvas.flush()
        X11.XCopyArea(dpy, pixmap, win, wgc, 0, 0, w, h, 0, 0)
        X11.XFlush(dpy)
    end

    function canvas.show()
        X11.XMapWindow(dpy, win)
        X11.XRaiseWindow(dpy, win)
        X11.XFlush(dpy)
        canvas.visible = true
    end

    function canvas.hide()
        X11.XUnmapWindow(dpy, win)
        X11.XFlush(dpy)
        canvas.visible = false
    end

    function canvas.move(nx, ny)
        X11.XMoveWindow(dpy, win, nx, ny)
    end

    function canvas.resize(nw, nh)
        X11.XResizeWindow(dpy, win, nw, nh)
    end

    function canvas.destroy()
        X11.XFreePixmap(dpy, pixmap)
        X11.XFreeGC(dpy, pgc)
        X11.XFreeGC(dpy, wgc)
        X11.XDestroyWindow(dpy, win)
    end

    return canvas
end

return M