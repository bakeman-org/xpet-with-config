CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2 -fPIC -Wall

FT_CFLAGS := $(shell $(PKG_CONFIG) --cflags freetype2)
FT_LIBS   := $(shell $(PKG_CONFIG) --libs freetype2)
HB_CFLAGS := $(shell $(PKG_CONFIG) --cflags harfbuzz)
HB_LIBS   := $(shell $(PKG_CONFIG) --libs harfbuzz)
SDL_CFLAGS := $(shell $(PKG_CONFIG) --cflags sdl2 SDL2_mixer)
SDL_LIBS   := $(shell $(PKG_CONFIG) --libs sdl2 SDL2_mixer)

all: xpet_ft.so xpet_audio.so run
run:
	luajit xpet.lua

xpet_ft.so: xpet_ft.c
	$(CC) $(CFLAGS) $(FT_CFLAGS) $(HB_CFLAGS) -shared -o $@ $< $(FT_LIBS) $(HB_LIBS) -lX11

xpet_audio.so: xpet_audio.c
	$(CC) $(CFLAGS) $(SDL_CFLAGS) -shared -o $@ $< $(SDL_LIBS)

clean:
	rm -f xpet_ft.so xpet_audio.so

.PHONY: all clean