# xpet with lua config
- mainly use luajit to redevelop the bitchcreateshiteare's xpet-with-config(codebase already missing, shit github already clean my codebase)

# build
- x11 freetype2 harfbuzz sdl2 sdl2-mixer ...
- luajit(tested with version 2.1.1737090214)
- prepare your assets folder first
```bash
# path to config lua file
luajit xpet.lua config.lua
```


# features
- working in progress


# pet assets (png/gif 后端)

`config.lua` 中设置 `pet_source = 'png'`，`pet_asset_dir` 支持两种最简布局（不再需要 xpm 那种 `<state>/<n>.png` 多状态目录）：

**1. 单个 GIF 文件** —— 所有帧自动拆成动画：

```lua
pet_source = 'png',
pet_asset_dir = 'assets/pets/my_pet.gif',
```

**2. PNG 序列帧目录** —— 目录里放 `01.png` ~ `99.png`（按数字排序，容忍 `1.png` 写法和跳号）：

```lua
pet_source = 'png',
pet_asset_dir = 'assets/pets/my_pet/',   -- 目录以 / 结尾与否均可
```

说明：
- 整套素材只有一个动画，所有行为状态（idle / walk / ...）自动回退到它
- PNG 各帧尺寸可以不同：程序会把小帧底部居中衬到最大帧的画布上（脚踩地面），窗口按最大帧创建，不会裁切
- 动画帧间隔由程序控制（`frame_duration`，毫秒），GIF 内置 delay 暂不读取
- 整数缩放用 `scale_factor`（如 2 = 每像素放大 2x2）
- PNG 解码支持：非隔行、8/16 位、灰度 / RGB / 灰度+alpha / RGBA（调色板类型暂不支持）
- GIF 解码支持：标准 LZW、透明索引、disposal、隔行

## 测试素材（无需跑起整个宠物）

```bash
# 检查 gif 文件 / png 帧目录 / 单张 png
luajit tools/check_asset.lua assets/pets/my_pet.gif
luajit tools/check_asset.lua assets/pets/my_pet/
```

看到 `OK: N frames` 即可改好 config 后运行 `luajit xpet.lua config.lua` 查看实际效果。
（`pet_source = 'xpm'` 的旧结构仍可用于 xpm 后端，互不影响。）



# NOTICE
- this project is not a fork of the original xpet-with-config, it is a reimplementation of it
- clanker driven code, please be careful
- feel free to PR or fork, I don't care because I don't have token anymore :(


# TODO
1. I will pack the program later by mockup.py, mainly provide for linux, if your system is not work, don't expect me to fix, ask clanker to fix for for you


# ref links
- thanks for original repo provided xpms: https://github.com/uint23/xpet 
- thanks for chillhop provided musics: https://stream.chillhop.com/
- zako ciallo audio you can find at, resource from the Internet: https://codeberg.org/etcix/momoisay-zako
