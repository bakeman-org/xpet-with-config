return {
  -- scale sugeested value range of 1-12, don't make it very big, or try it yourself
  scale_factor = 2,
  pet_speed = 2,
  frame_duration = 200,

  pet_source = 'png',
  pet_asset_dir = 'assets/png', -- 编号帧目录 01.png ~ 13.png
  audio_panel_dir = 'assets/music',

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
  click_audio_to_play = 'assets/audio/ciallo_1.mp3',

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
  },

  pomodoro = {
    work_min = 25,
    break_min = 5,
  },

  clip_hist = {
    max_items = 30,
  },

  launcher = {
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
