local M = {}
local UI = require("core.ui")
local Surface = require("core.surface")

function M.init(ctx)
    M.ctx = ctx
    M.ready = true -- ← add

    M.ui = UI.new(ctx, {
        primary = 0xb69eff, -- from your reference: soft lavender
        on_primary = 0x2e1065,
        secondary_ctr = 0x4a4458,
        green = 0xd6f26a -- lime accent
    })
    M.val = 0.42
    M.on = true
    M.t = 0
    M.w, M.h = 480, 460
    M.surf = Surface.new(ctx, M.w, M.h)
    M.ui:attach(M.surf)

    M.canvas = ctx.create_canvas(M.w, M.h, {
        x = 200,
        y = 160,
        bg = M.ui.theme.bg
    })
    M.canvas:show()

    ctx.register_action("toggle_ui_demo", function()
        if M.canvas.visible then
            M.canvas:hide()
        else
            M.canvas:show()
        end
    end)
    ctx.on("xevent", function(t, ev)
        M.ui:on_event(t, ev)
    end)
    ctx.on("tick", function(dt)
        M:tick(dt)
    end)
end

function M:tick(dt)
    if not M.ready then
        return
    end -- ← add

    if not M.canvas.visible then
        return
    end
    M.t = M.t + dt
    local ui, s, T = M.ui, M.surf, M.ui.theme
    s:clear(T.bg)
    ui:begin()

    local LH = ui:line_h() -- 一行的高度（含 leading）
    local PAD = 24

    -- 顶栏
    ui:label(PAD, 20, "UI 组件库", T.on_surface)
    ui:label(M.w - 130, 22, "M3 · 深色", T.on_var)

    -- Hero 卡：高度由内容决定
    local card_y = 60
    local card_h = LH * 3 + 32
    ui:card(PAD, card_y, M.w - PAD * 2, card_h, {
        radius = 20
    })

    local ly = card_y + 16
    ui:label(PAD + 20, ly, "Material You", T.primary)
    ui:label(PAD + 20, ly + LH, "动态色彩 · 圆角 · 无锯齿渲染", T.on_var)
    ui:label(PAD + 20, ly + LH * 2, "Material 3 组件示例", T.outline)

    -- 按钮行
    local by = card_y + card_h + 24
    ui:button(PAD, by, 120, 44, "主操作", {
        filled = true
    })
    ui:button(PAD + 132, by, 120, 44, "次级", {
        tonal = true
    })
    ui:button(PAD + 264, by, 120, 44, "文字", {})

    -- 滑块
    local sy = by + 60
    ui:label(PAD, sy, string.format("进度  %.0f%%", M.val * 100), T.on_var)
    local nv, ch = ui:slider("demo1", PAD, sy + LH, M.w - PAD * 2, M.val)
    if ch then
        M.val = nv
    end

    -- Toggle
    local ty = sy + LH + 40
    ui:label(PAD, ty, "启用发光", T.on_var)
    local nv2, ch2 = ui:toggle("demo2", M.w - PAD - 76, ty - 8, 76, 40, M.on)
    if ch2 then
        M.on = nv2
    end

    -- 呼吸条
    local ay = ty + LH + 16
    ui:label(PAD, ay, "动画", T.on_var)
    local pulse = 0.5 + 0.5 * math.sin(M.t / 400)
    s:rrect(PAD + 96, ay + 8, M.w - PAD * 2 - 96, 6, 3, T.surface_hi)
    s:rrect(PAD + 96, ay + 8, math.floor((M.w - PAD * 2 - 96) * pulse), 6, 3, T.green)

    ui:end_frame()
    s:flush(M.canvas.win, M.canvas.wgc, 0, 0)
end

function M.shutdown()
    M.ready = false -- ← add (before destroying!)

    if M.surf then
        M.surf:destroy()
    end
    if M.canvas then
        M.canvas:destroy()
    end
end

return M
