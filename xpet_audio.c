// xpet_audio.c
#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <string.h>
#include <dirent.h>
#include <strings.h>
#include <stdlib.h>

static int g_ready = 0;
static Mix_Music* g_music = NULL;
static int g_paused = 0;
static int g_playing = 0;

#define SCAN_MAX 2048
#define SCAN_LEN 512
static char g_scan[SCAN_MAX][SCAN_LEN];
static int  g_scan_n = 0;

#define MAX_SFX_CHANNELS 32
static Mix_Chunk* g_chunk_slots[MAX_SFX_CHANNELS];

static int has_ext(const char* n) {
    const char* d = strrchr(n, '.');
    if (!d) return 0;
    d++;
    return !strcasecmp(d,"mp3") || !strcasecmp(d,"wav") ||
           !strcasecmp(d,"ogg") || !strcasecmp(d,"flac") ||
           !strcasecmp(d,"m4a");
}

static int cmp_p(const void* a, const void* b) {
    return strcmp((const char*)a, (const char*)b);
}


static void sfx_channel_finished(int channel) {
    if (channel < 0 || channel >= MAX_SFX_CHANNELS) return;
    if (g_chunk_slots[channel]) {
        Mix_FreeChunk(g_chunk_slots[channel]);
        g_chunk_slots[channel] = NULL;
    }
}

int audio_init(void) {
    if (g_ready) return 0;
    if (SDL_Init(SDL_INIT_AUDIO) < 0) return -1;
    if (Mix_OpenAudio(44100, AUDIO_S16SYS, 2, 2048) < 0) {
        SDL_Quit();
        return -2;
    }
    Mix_Init(MIX_INIT_MP3 | MIX_INIT_OGG | MIX_INIT_FLAC);
    Mix_AllocateChannels(MAX_SFX_CHANNELS);
    Mix_ChannelFinished(sfx_channel_finished);
    memset(g_chunk_slots, 0, sizeof(g_chunk_slots));
    g_ready = 1;
    return 0;
}

void audio_shutdown(void) {
    if (g_music) { Mix_FreeMusic(g_music); g_music = NULL; }
    for (int i = 0; i < MAX_SFX_CHANNELS; i++) {
        if (g_chunk_slots[i]) {
            Mix_FreeChunk(g_chunk_slots[i]);
            g_chunk_slots[i] = NULL;
        }
    }
    if (g_ready) {
        Mix_CloseAudio();
        Mix_Quit();
        SDL_Quit();
        g_ready = 0;
    }
    g_paused = 0;
    g_playing = 0;
}

int audio_play(const char* path) {
    if (!g_ready) return -1;
    if (g_music) {
        Mix_HaltMusic();
        Mix_FreeMusic(g_music);
        g_music = NULL;
    }
    g_music = Mix_LoadMUS(path);
    if (!g_music) return -2;
    if (Mix_PlayMusic(g_music, 0) < 0) {
        Mix_FreeMusic(g_music);
        g_music = NULL;
        return -3;
    }
    g_paused = 0;
    g_playing = 1;
    return 0;
}

int audio_play_sfx(const char* path, int vol_0_100) {
    if (!path || path[0] == 0) return -1;
    if (!g_ready) {
        if (audio_init() != 0) return -1;
    }
    Mix_Chunk* chunk = Mix_LoadWAV(path);
    if (!chunk) return -2;
    int mv = vol_0_100 * 128 / 100;
    if (mv < 0) mv = 0;
    if (mv > 128) mv = 128;
    Mix_VolumeChunk(chunk, mv);
    int ch = Mix_PlayChannel(-1, chunk, 0);
    if (ch < 0) {
        Mix_FreeChunk(chunk);
        return -3;
    }
    if (ch < MAX_SFX_CHANNELS) {
        if (g_chunk_slots[ch]) Mix_FreeChunk(g_chunk_slots[ch]);
        g_chunk_slots[ch] = chunk;
    }
    return ch;
}

void audio_toggle_pause(void) {
    if (!g_music || !g_playing) return;
    if (g_paused) { Mix_ResumeMusic(); g_paused = 0; }
    else          { Mix_PauseMusic();  g_paused = 1; }
}

void audio_stop(void) {
    if (g_music) Mix_HaltMusic();
    g_playing = 0;
    g_paused = 0;
}

int audio_is_playing(void) { return g_playing; }
int audio_is_paused(void)  { return g_paused; }

void audio_set_volume(int v0_100) {
    if (v0_100 < 0) v0_100 = 0;
    if (v0_100 > 100) v0_100 = 100;
    int mv = v0_100 * 128 / 100;
    if (mv > 128) mv = 128;
    Mix_VolumeMusic(mv);
}

double audio_get_position(void) {
    if (!g_music) return 0.0;
    double p = Mix_GetMusicPosition(g_music);
    return p < 0 ? 0.0 : p;
}

double audio_get_duration(void) {
    if (!g_music) return 0.0;
#if defined(Mix_MusicDuration)
    double d = Mix_MusicDuration(g_music);
#elif defined(Mix_GetMusicDuration)
    double d = Mix_GetMusicDuration(g_music);
#else
    double d = 0.0;
#endif
    return d < 0 ? 0.0 : d;
}

void audio_seek(double sec) {
    if (!g_music) return;
    if (sec < 0) sec = 0;
    Mix_SetMusicPosition(sec);
}

int audio_finished(void) {
    if (!g_playing) return 0;
    if (g_paused) return 0;
    if (Mix_PlayingMusic() == 0) {
        g_playing = 0;
        g_paused = 0;
        return 1;
    }
    return 0;
}


int audio_scan_dir(const char* dir) {
    g_scan_n = 0;
    DIR* d = opendir(dir);
    if (!d) return -1;
    struct dirent* e;
    while ((e = readdir(d)) && g_scan_n < SCAN_MAX) {
        if (e->d_name[0] == '.') continue;
        if (!has_ext(e->d_name)) continue;
        snprintf(g_scan[g_scan_n], SCAN_LEN, "%s/%s", dir, e->d_name);
        g_scan_n++;
    }
    closedir(d);
    qsort(g_scan, g_scan_n, SCAN_LEN, cmp_p);
    return g_scan_n;
}

const char* audio_scan_get(int idx) {
    if (idx < 0 || idx >= g_scan_n) return 0;
    return g_scan[idx];
}

double audio_probe_duration(const char* path) {
    if (!g_ready && audio_init() != 0) return -1.0;
    Mix_Music* m = Mix_LoadMUS(path);
    if (!m) return -1.0;
    double d = 0.0;
#if defined(Mix_MusicDuration)
    d = Mix_MusicDuration(m);
#elif defined(Mix_GetMusicDuration)
    d = Mix_GetMusicDuration(m);
#endif
    Mix_FreeMusic(m);
    return d > 0 ? d : -1.0;
}