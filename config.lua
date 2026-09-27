return {
  -- scale 支持任意小数（0.1 缩小 ~ 12 放大），最近邻采样
  scale_factor = 2,
  pet_speed = 2,
  frame_duration = 200,
  -- 启动时冻结宠物（不乱跑）；Ctrl+Alt+S 可手动切换
  pet_frozen = true,

  pet_source = 'xpm',
  pet_asset_dir = 'assets/pets/bsd',
  audio_panel_dir = 'assets/music',

  -- 面板默认位置与进场动画（单个面板可在 Panel opts 里覆盖）
  -- pos: center/top/bottom/left/right/top_left/top_right/bottom_left/bottom_right
  -- anim: auto/slide_down/slide_up/slide_left/slide_right/none
  ui = {
    pos = 'center',
    anim = 'auto',
  },

  font_path = '/home/etcix/.local/share/fonts/MiSans-Regular.ttf',
  font_size = 24,
  fallback_font_paths = {
    '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf',
    '/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf',
    '/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf',
    '/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  },

  enable_audio = true,
  click_audio_to_play = 'assets/audio/zako_1.mp3',

  phrases = {
    'Get off the chair, you lazybones~ 😀',
    "Oh wow, you're too chubby time to exercise~ 🏃",
    "Woof! A stranger's approaching? I'll protect you! 🐕",
    'Woof! Wanna play fetch? Throw the ball already~ 🎾',
    "The weather's great today wanna go for a walk? ☀️",
    "Whimper~ I'm kinda hungry, need foodies! 🍖",
    "Master, play with me please? I'm so bored~ 😢",
    "I like you so much! I'll always follow you~ ❤️",
    '你好 世界 こんにちは 안녕하세요',
    'مرحبا שלום สวัสดี नमस्ते',
  },

  keybinds = {
    {
      mod = 'ctrl+alt',
      key = 'f',
      action = 'toggle_chase',
    },
    {
      mod = 'ctrl+alt',
      key = 's',
      action = 'toggle_freeze',
    },
    {
      mod = 'ctrl+alt',
      key = 'q',
      action = 'quit',
    },
    {
      mod = 'ctrl+alt',
      key = 'p',
      action = 'say_hello',
    },
    {
      mod = 'ctrl+alt',
      key = 'h',
      action = 'show_keybinds_help',
    },
    {
      mod = 'ctrl+alt',
      key = 'm',
      action = 'toggle_music_player',
    },
    {
      mod = 'ctrl+alt',
      key = 'r',
      action = 'hot_reload',
    },
    {
      mod = 'ctrl+alt+shift',
      key = 'a',
      action = 'toggle_auto_reload',
    }, -- { mod = "ctrl+alt",   key = "d", action = "toggle_ui_demo"  },
    {
      mod = 'ctrl+alt',
      key = 'w',
      action = 'toggle_weather',
    },
    {
      mod = 'ctrl+alt',
      key = 'i',
      action = 'toggle_sysinfo',
    },
    {
      mod = 'ctrl+alt',
      key = 't',
      action = 'toggle_sysmon',
    },
    {
      mod = 'ctrl+alt',
      key = 'b',
      action = 'toggle_pomodoro',
    },
    {
      mod = 'ctrl+alt',
      key = 'v',
      action = 'toggle_clip_hist',
    },
    {
      mod = 'ctrl+alt',
      key = 'e',
      action = 'toggle_launcher',
    },
    {
      mod = 'ctrl+alt',
      key = 'c',
      action = 'toggle_color_picker',
    },
       {
      mod = 'ctrl+alt',
      key = 'd',
      action = 'hide_all_windows',
    },
  },
  plugins = {
    'keybinds_help',
    'music_player', -- "ui_demo",
    'weather',
    'sysinfo',
    'sysmon',
    'pomodoro',
    'clip_hist',
    'launcher',
    'color_picker',
        'hide_all',        -- ← 新增

  },

  pomodoro = {
    work_min = 25,
    break_min = 5,
  },

  clip_hist = {
    max_items = 30,
  },

  launcher = {
    pos = 'top', -- dmenu 风格：贴顶；想居中就删掉这行（回落到 ui.pos）
    anim = 'slide_down',
    use_dmenu_path = true, -- ← 新增；设为 false 就退回旧行为（只用 entries）

    entries = {
      { name = '终端', cmd = 'alacritty' },
      { name = '文件管理器', cmd = 'pcmanfm' },
      { name = '浏览器', cmd = 'firefox' },
      { name = '编辑器', cmd = 'code' },
      { name = '系统监视', cmd = 'alacritty -e btop' },
    },
  },

  weather = {
    units = 'c',
    refresh_sec = 300, -- 300 seconds

    -- 手动指定城市（最高优先级）
    -- 填了就跳过 ip-api.com 定位，直接用这个城市查 wttr.in
    -- 比如上面 curl 出来的 ipinfo 是 Guangzhou，想保险就写死：
    -- manual_city = "Guangzhou",
    manual_city = '东莞',
    -- manual_city = nil,   -- 或者注释掉，走自动定位
  },
}
