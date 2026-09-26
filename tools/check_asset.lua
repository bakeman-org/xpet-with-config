-- 宠物素材自检（无窗口）：luajit tools/check_asset.lua <gif 文件 | png 帧目录>
local here = arg[0]:match('^(.*)/')
package.path = (here and here .. '/../?' or '..') .. '/?.lua;' .. package.path

local path = arg[1]
if not path then
  io.stderr:write('usage: luajit tools/check_asset.lua <gif 文件 | png 帧目录>\n')
  os.exit(1)
end

local f = io.open(path, 'rb')
if not f then
  io.stderr:write('not found: ' .. path .. '\n')
  os.exit(1)
end
local head = f:read(8)
f:close()

local Source = require('core.source_png')

if head and head:sub(1, 3) == 'GIF' then
  local w, h, frames = Source.decode_gif(path)
  if not w then
    io.stderr:write('gif decode FAILED: ' .. path .. '\n')
    os.exit(1)
  end
  print(string.format('GIF OK: %d frames, canvas %dx%d', #frames, w, h))
elseif head and head:sub(1, 4) == '\137PNG' then
  local w, h, rgba = Source.decode_png(path)
  if not w then
    io.stderr:write('png decode FAILED: ' .. path .. '\n')
    os.exit(1)
  end
  print(string.format('PNG OK: %dx%d', w, h))
else
  -- 目录：逐张编号帧检查
  local p = io.popen(string.format("ls -1 '%s' 2>/dev/null | sort", path))
  local n, bad, first = 0, 0, nil
  if p then
    for line in p:lines() do
      if line:match('^%d+%.png$') then
        local w, h = Source.decode_png(path .. '/' .. line)
        if not w then
          print('  FAIL ' .. line)
          bad = bad + 1
        else
          first = first or { w = w, h = h }
          n = n + 1
        end
      end
    end
    p:close()
  end
  if n == 0 or bad > 0 then
    io.stderr:write(string.format('PNG frames FAILED: %d ok, %d bad\n', n, bad))
    os.exit(1)
  end
  print(string.format('PNG frames OK: %d frames, size %dx%d', n, first.w, first.h))
end
