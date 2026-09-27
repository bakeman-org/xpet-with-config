local M = { plugins = {}, plugin_list = {}, mtimes = {}, watch_enabled = true }
local Util = require('core.util')
local log = Util.logger('plugin_mgr')

local function load_one(name, ctx)
  local path = ctx.SCRIPT_DIR .. '/plugins/' .. name .. '.lua'
  local chunk, err = loadfile(path)
  if not chunk then
    log('failed to load %s: %s', name, tostring(err))
    return
  end
  local ok, plugin = pcall(chunk)
  if not ok or type(plugin) ~= 'table' or type(plugin.init) ~= 'function' then
    log('plugin %s invalid: %s', name, tostring(plugin))
    return
  end
  local ok2, err2 = pcall(plugin.init, ctx)
  if not ok2 then
    log('plugin %s init error: %s', name, tostring(err2))
    return
  end
  M.plugins[#M.plugins + 1] = { name = name, mod = plugin }
  log('loaded: %s', name)
end

local function unload_all()
  for _, p in ipairs(M.plugins) do
    if type(p.mod.shutdown) == 'function' then
      pcall(p.mod.shutdown)
    end
  end
  M.plugins = {}
end

function M.load_all(plugin_list, ctx)
  M.plugin_list = plugin_list or {}
  for _, name in ipairs(M.plugin_list) do
    load_one(name, ctx)
  end
  M.snapshot_mtimes(ctx)
end

function M.shutdown()
  unload_all()
end

-- 关键：reload 接受新的 plugin 列表（来自 config.plugins）
-- 这样运行时添加的插件也会被加载，移除的插件也会被卸载。
function M.reload(ctx, new_list)
  new_list = new_list or M.plugin_list or {}
  log('--- hot reload (old=%d, new=%d) ---', #M.plugin_list, #new_list)

  unload_all()
  for _, name in ipairs(new_list) do
    package.loaded['plugins.' .. name] = nil
  end

  M.plugin_list = new_list
  for _, name in ipairs(M.plugin_list) do
    load_one(name, ctx)
  end
  M.snapshot_mtimes(ctx)
  log('--- reload done (%d plugins) ---', #M.plugins)
end

function M.watch_paths(ctx)
  -- 监听实际使用的配置文件（可能是 config-png2.lua 等），而非写死 config.lua
  local paths = { ctx.config_path or (ctx.SCRIPT_DIR .. '/config.lua') }
  for _, name in ipairs(M.plugin_list) do
    paths[#paths + 1] = ctx.SCRIPT_DIR .. '/plugins/' .. name .. '.lua'
  end
  return paths
end

function M.snapshot_mtimes(ctx)
  M.mtimes = {}
  for _, p in ipairs(M.watch_paths(ctx)) do
    M.mtimes[p] = Util.file_mtime(p)
  end
end

function M.check_changes(ctx)
  if not M.watch_enabled then
    return false
  end
  local changed = false
  for _, p in ipairs(M.watch_paths(ctx)) do
    local mt = Util.file_mtime(p)
    if mt and M.mtimes[p] and M.mtimes[p] ~= mt then
      log('changed: %s', p)
      changed = true
    end
    M.mtimes[p] = mt
  end
  return changed
end

function M.set_watch(enabled)
  M.watch_enabled = enabled
  log('auto-reload %s', enabled and 'ON' or 'OFF')
end

return M
