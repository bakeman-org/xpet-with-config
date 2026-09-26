local M = {}
local ffi = require("ffi")

local S = {}
S.__index = S

function M.new(ctx, w, h)
    local self = setmetatable({}, S)
    self.ctx = ctx
    self.w, self.h = w, h
    self.buf = ffi.new("uint32_t[?]", w * h)
    self.ximg = nil
    return self
end

function S:clear(color)
    self.ctx.FT.surf_fill(self.buf, self.w, self.h, 0, 0, self.w, self.h, color)
end

function S:rect(x, y, w, h, color)
    self.ctx.FT.surf_fill(self.buf, self.w, self.h, x, y, w, h, color)
end

function S:rrect(x, y, w, h, r, color)
    self.ctx.FT.surf_rrect_aa(self.buf, self.w, self.h, x, y, w, h, r, color)
end

function S:text(x, y_top, str, fg)
    self.ctx.FT.xft_draw_rgba(self.ctx.ft_ctx, self.buf, self.w, self.h, x, y_top, str, fg)
end

function S:_ensure_ximg()
    if self.ximg then
        return true
    end
    local ctx, ffi = self.ctx, require("ffi")
    local X11, dpy = ctx.X11, ctx.dpy
    local scr = X11.XDefaultScreen(dpy)
    local visual = X11.XDefaultVisual(dpy, scr)
    local depth = X11.XDefaultDepth(dpy, scr)

    local img = X11.XCreateImage(dpy, visual, depth, 2, 0, nil, self.w, self.h, 32, 0)
    if img == nil then
        return false
    end
    -- hand ownership of `data` to the C shim: it frees X's malloc'd
    -- buffer and points the XImage at our LuaJIT-owned uint32_t array
    ctx.FT.surf_take_ximg_data(img, self.buf)
    self.ximg = img
    return true
end


function S:destroy()
    if self.ximg then
        -- Detach without freeing: img->data points at our LuaJIT GC buffer,
        -- and XDestroyImage would try to free() it otherwise.
        self.ctx.FT.surf_ximg_detach(self.ximg)
        self.ctx.X11.XDestroyImage(self.ximg)
        self.ximg = nil
    end
    self.buf = nil
end

function S:flush(win, gc, dx, dy)
    if not self:_ensure_ximg() then
        return
    end
    local X11 = self.ctx.X11
    X11.XPutImage(self.ctx.dpy, win, gc, self.ximg, 0, 0, dx or 0, dy or 0, self.w, self.h)
    X11.XFlush(self.ctx.dpy)
end

return M
