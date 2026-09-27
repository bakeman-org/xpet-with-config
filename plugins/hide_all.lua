-- plugins/hide_all.lua
-- 一键收起所有已打开的 xpet 面板（注意：是 xpet 自己的面板，不是系统窗口！）
--
-- 实现方式：
--   1. core/panel.lua 里每个 Panel 实例都会把自己注册到 ctx._panels
--   2. 本插件遍历 ctx._panels，对每个 visible 的面板调 hide()
--   3. hide() 会自动：释放键盘 grab、触发滑出动画、调用面板自己的 on_hide 回调
--
-- 兼容性：
--   - 主 action 名：'hide_all_panels'
--   - 别名：'hide_all_windows'（旧 config 里绑的可能是这个名字，保留兼容）
--
-- 使用前提：
--   - core/panel.lua 必须是带"面板注册表"的版本（M.new 里注册、destroy 里反注册）
--   - core/panel.lua 的 on_ev KEY_PRESS 分支必须支持全局 keybind 透传，
--     否则面板 grab 键盘时（比如 launcher 打开着）本快捷键收不到

local M = {}
local Util = require('core.util')

local log = Util.logger('hide_all')

function M.init(ctx)
  M.ctx = ctx
  -- 主 action 名
  ctx.register_action('hide_all_panels', function() M.hide_all() end)
  -- 兼容别名
  ctx.register_action('hide_all_windows', function() M.hide_all() end)
  log('ready')
end

-- 遍历 ctx._panels，对所有 visible 的面板调用 hide()
function M.hide_all()
  local ctx = M.ctx
  if not ctx then
    return
  end

  local panels = ctx._panels or {}
  local count = 0
  for _, p in ipairs(panels) do
    if p.visible then
      p:hide()
      count = count + 1
    end
  end

  if count > 0 then
    ctx.show_bubble(string.format('🫥 已收起 %d 个面板', count))
  else
    ctx.show_bubble('没有打开的面板')
  end
end

function M.shutdown()
  M.ctx = nil
end

return M