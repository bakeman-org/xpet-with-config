local M = {}
local Util = require('core.util')

function M.resolve_path(p, base)
  if p and p:sub(1, 1) == '~' then
    p = (os.getenv('HOME') or '') .. p:sub(2)
  end
  p = p or ''
  if p == '' then
    return p
  end
  if p:sub(1, 1) == '/' then
    return p
  end
  return base .. '/' .. p
end

function M.load(path, base)
  local chunk, err = loadfile(path)
  if not chunk then
    error('load config: ' .. tostring(err))
  end
  local ok, cfg = pcall(chunk)
  if not ok then
    error('run config: ' .. tostring(cfg))
  end
  if type(cfg) ~= 'table' then
    error('config must return a table')
  end

  cfg.pet_asset_dir = M.resolve_path(cfg.pet_asset_dir, base)
  cfg.audio_panel_dir = M.resolve_path(cfg.audio_panel_dir, base)
  cfg.font_path = M.resolve_path(cfg.font_path, base)
  cfg.click_audio_to_play = cfg.click_audio_to_play and M.resolve_path(cfg.click_audio_to_play, base)
    or nil
  cfg.fallback_font_paths = cfg.fallback_font_paths or {}
  for i, p in ipairs(cfg.fallback_font_paths) do
    cfg.fallback_font_paths[i] = M.resolve_path(p, base)
  end
  return cfg
end

M.file_exists = Util.file_exists

return M
