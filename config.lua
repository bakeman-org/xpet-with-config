return {
    scale_factor    = 2,
    pet_speed       = 2,
    frame_duration  = 200,

    pet_asset_dir   = "assets/pets/neko",
    audio_panel_dir = "assets/music",

    font_path = "/home/etcix/.local/share/fonts/FiraCodeNerdFont-Bold.ttf",
    font_size = 24,
    fallback_font_paths = {
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    },

    enable_audio          = true,
    click_audio_to_play   = "assets/audio/ciallo_1.mp3",

    phrases = {
        "Get off the chair, you lazybones~ 😀",
        "Oh wow, you're too chubby time to exercise~ 🏃",
        "Woof! A stranger's approaching? I'll protect you! 🐕",
        "Woof! Wanna play fetch? Throw the ball already~ 🎾",
        "The weather's great today wanna go for a walk? ☀️",
        "Whimper~ I'm kinda hungry, need foodies! 🍖",
        "Master, play with me please? I'm so bored~ 😢",
        "I like you so much! I'll always follow you~ ❤️",
        "你好 世界 こんにちは 안녕하세요",
        "مرحبا שלום สวัสดี नमस्ते",
    },

    keybinds = {
        { mod = "ctrl+alt",         key = "f", action = "toggle_chase"        },
        { mod = "ctrl+alt",         key = "s", action = "toggle_freeze"       },
        { mod = "ctrl+alt",         key = "q", action = "quit"                },
        { mod = "ctrl+alt",         key = "p", action = "say_hello"           },
        { mod = "ctrl+alt",         key = "h", action = "show_keybinds_help"  },
        { mod = "ctrl+alt",         key = "m", action = "toggle_music_player" },
        { mod = "ctrl+alt",         key = "r", action = "hot_reload"          },
        { mod = "ctrl+alt+shift",   key = "a", action = "toggle_auto_reload"  },
        { mod = "ctrl+alt",   key = "d", action = "toggle_ui_demo"  },

    },
    plugins = {
        "keybinds_help",
        "music_player",
        "ui_demo",

    },
}