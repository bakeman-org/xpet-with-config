#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include <hb-ft.h>
#include <hb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_FALLBACKS 16

static FT_Library g_lib = 0;

typedef struct {
  FT_Face primary;
  FT_Face fallback[MAX_FALLBACKS];
  int n_fallback;
  int size;
} XftCtx;

int xft_init(void) { return FT_Init_FreeType(&g_lib); }

static void set_size_or_select(FT_Face face, int size) {
  if (FT_Set_Pixel_Sizes(face, 0, size) != 0) {
    if (face->num_fixed_sizes > 0) {
      int best = 0, best_diff = 1 << 30;
      for (int i = 0; i < face->num_fixed_sizes; i++) {
        int h = face->available_sizes[i].height;
        int d = h > size ? h - size : size - h;
        if (d < best_diff) {
          best_diff = d;
          best = i;
        }
      }
      FT_Select_Size(face, best);
    }
  }
}

void *xft_load(const char *primary_path, int size, const char *fallback_paths) {
  XftCtx *ctx = (XftCtx *)calloc(1, sizeof(XftCtx));
  if (!ctx)
    return 0;
  ctx->size = size;

  if (FT_New_Face(g_lib, primary_path, 0, &ctx->primary) != 0) {
    free(ctx);
    return 0;
  }
  set_size_or_select(ctx->primary, size);

  if (fallback_paths && fallback_paths[0]) {
    char *dup = strdup(fallback_paths);
    char *save = NULL;
    char *line = strtok_r(dup, "\n", &save);
    while (line && ctx->n_fallback < MAX_FALLBACKS) {
      if (line[0]) {
        FT_Face fb = 0;
        if (FT_New_Face(g_lib, line, 0, &fb) == 0) {
          set_size_or_select(fb, size);
          ctx->fallback[ctx->n_fallback++] = fb;
        } else {
          fprintf(stderr, "[xpet_ft] cannot load fallback: %s\n", line);
        }
      }
      line = strtok_r(NULL, "\n", &save);
    }
    free(dup);
  }
  return ctx;
}

void xft_done(void *ptr) {
  if (!ptr)
    return;
  XftCtx *ctx = (XftCtx *)ptr;
  if (ctx->primary)
    FT_Done_Face(ctx->primary);
  for (int i = 0; i < ctx->n_fallback; i++)
    if (ctx->fallback[i])
      FT_Done_Face(ctx->fallback[i]);
  free(ctx);
}

static int utf8_decode(const unsigned char *s, unsigned int *cp) {
  unsigned char c = s[0];
  if (c < 0x80) {
    *cp = c;
    return 1;
  }
  if ((c & 0xE0) == 0xC0 && s[1]) {
    *cp = ((c & 0x1F) << 6) | (s[1] & 0x3F);
    return 2;
  }
  if ((c & 0xF0) == 0xE0 && s[1] && s[2]) {
    *cp = ((c & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    return 3;
  }
  if ((c & 0xF8) == 0xF0 && s[1] && s[2] && s[3]) {
    *cp = ((c & 0x07) << 18) | ((s[1] & 0x3F) << 12) | ((s[2] & 0x3F) << 6) |
          (s[3] & 0x3F);
    return 4;
  }
  *cp = 0xFFFD;
  return 1;
}

static FT_Face pick_face(XftCtx *ctx, unsigned int cp) {
  if (FT_Get_Char_Index(ctx->primary, cp) != 0)
    return ctx->primary;
  for (int i = 0; i < ctx->n_fallback; i++)
    if (FT_Get_Char_Index(ctx->fallback[i], cp) != 0)
      return ctx->fallback[i];
  return ctx->primary;
}

static double face_scale(FT_Face face, int desired_size) {
  if (FT_IS_SCALABLE(face))
    return 1.0;
  if (face->num_fixed_sizes == 0)
    return 1.0;
  int strike_h = (int)face->size->metrics.y_ppem;
  if (strike_h <= 0)
    strike_h = face->available_sizes[0].height;
  if (strike_h <= 0 || strike_h == desired_size)
    return 1.0;
  return (double)desired_size / (double)strike_h;
}

int xft_line_height(void *ptr) {
  XftCtx *ctx = (XftCtx *)ptr;
  int h = (int)((ctx->primary->size->metrics.ascender -
                 ctx->primary->size->metrics.descender) >>
                6);
  for (int i = 0; i < ctx->n_fallback; i++) {
    FT_Face fb = ctx->fallback[i];
    if (!FT_IS_SCALABLE(fb))
      continue;
    int fh =
        (int)((fb->size->metrics.ascender - fb->size->metrics.descender) >> 6);
    if (fh > h)
      h = fh;
  }
  if (h < 8)
    h = 16;
  return h;
}

/* 只返回主字体的 ascender-descender。UI 文字对齐用这个，
   避免被 emoji / CJK fallback 撑大的 line height 带偏。
   多行文本的行距仍用 xft_line_height，那个必须包含所有 fallback。 */
int xft_primary_line_height(void *ptr) {
  XftCtx *ctx = (XftCtx *)ptr;
  int h = (int)((ctx->primary->size->metrics.ascender -
                 ctx->primary->size->metrics.descender) >>
                6);
  if (h < 8)
    h = 16;
  return h;
}

static void shape_run(FT_Face face, const unsigned char *start, size_t len,
                      hb_buffer_t *buf) {
  hb_buffer_clear_contents(buf);
  hb_buffer_add_utf8(buf, (const char *)start, (int)len, 0, (int)len);
  hb_buffer_guess_segment_properties(buf);
  hb_font_t *hf = hb_ft_font_create_referenced(face);
  hb_shape(hf, buf, NULL, 0);
  hb_font_destroy(hf);
}

void xft_text_extent(void *ptr, const char *text, int *w_out, int *h_out) {
  XftCtx *ctx = (XftCtx *)ptr;
  int max_w = 0, total_h = 0;
  int lh = xft_line_height(ptr);
  const char *ls = text;
  hb_buffer_t *buf = hb_buffer_create();

  while (1) {
    const char *le = strchr(ls, '\n');
    size_t line_len = le ? (size_t)(le - ls) : strlen(ls);
    if (line_len > 0) {
      int lw = 0;
      const unsigned char *p = (const unsigned char *)ls;
      const unsigned char *end = p + line_len;
      while (p < end) {
        unsigned int cp;
        int n = utf8_decode(p, &cp);
        FT_Face run_face = pick_face(ctx, cp);
        const unsigned char *q = p + n;
        while (q < end) {
          unsigned int c2;
          int n2 = utf8_decode(q, &c2);
          if (pick_face(ctx, c2) != run_face)
            break;
          q += n2;
        }
        double sc = face_scale(run_face, ctx->size);
        shape_run(run_face, p, (size_t)(q - p), buf);
        unsigned int gc = 0;
        hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, &gc);
        for (unsigned int i = 0; i < gc; i++)
          lw += (int)((pos[i].x_advance >> 6) * sc);
        p = q;
      }
      if (lw > max_w)
        max_w = lw;
    }
    total_h += lh + 4;
    if (!le)
      break;
    ls = le + 1;
  }
  hb_buffer_destroy(buf);
  *w_out = max_w;
  *h_out = total_h;
}

static inline void blend(uint32_t *dst, uint8_t r, uint8_t g, uint8_t b,
                         uint8_t a) {
  if (a == 0)
    return;
  uint32_t e = *dst;
  uint8_t er = (e >> 16) & 0xFF;
  uint8_t eg = (e >> 8) & 0xFF;
  uint8_t eb = e & 0xFF;
  uint16_t inv = 255 - a;
  uint8_t nr = (uint8_t)((r * a + er * inv) / 255);
  uint8_t ng = (uint8_t)((g * a + eg * inv) / 255);
  uint8_t nb = (uint8_t)((b * a + eb * inv) / 255);
  *dst = ((uint32_t)nr << 16) | ((uint32_t)ng << 8) | nb;
}

static void rasterize_glyph(uint32_t *img_buf, int img_w, int img_h,
                            FT_Face face, unsigned int gi, int gx, int gy,
                            unsigned long fg, double scale) {
  FT_Error err = FT_Load_Glyph(face, gi, FT_LOAD_COLOR | FT_LOAD_TARGET_LIGHT);
  if (err != 0)
    return;
  FT_GlyphSlot slot = face->glyph;

  int is_color = (slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA);

  if (!is_color) {
    err = FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL);
    if (err != 0)
      return;
  }

  FT_Bitmap *bm = &slot->bitmap;
  int src_w = (int)bm->width;
  int src_h = (int)bm->rows;
  if (src_w <= 0 || src_h <= 0)
    return;

  int do_scale = (scale < 0.99 || scale > 1.01);

  int dst_w, dst_h, dst_left, dst_top;
  if (do_scale) {
    dst_w = (int)(src_w * scale + 0.5);
    dst_h = (int)(src_h * scale + 0.5);
    dst_left = (int)(slot->bitmap_left * scale + 0.5);
    dst_top = (int)(slot->bitmap_top * scale + 0.5);
    if (dst_w < 1)
      dst_w = 1;
    if (dst_h < 1)
      dst_h = 1;
  } else {
    dst_w = src_w;
    dst_h = src_h;
    dst_left = slot->bitmap_left;
    dst_top = slot->bitmap_top;
  }

  int bx = gx + dst_left;
  int by = gy - dst_top;

  uint8_t fr = (fg >> 16) & 0xFF;
  uint8_t fgn = (fg >> 8) & 0xFF;
  uint8_t fb = fg & 0xFF;

  for (int dy = 0; dy < dst_h; dy++) {
    int py = by + dy;
    if (py < 0 || py >= img_h)
      continue;
    uint32_t *dst_row = img_buf + py * img_w;

    int sy = do_scale ? (int)((double)dy / scale) : dy;
    if (sy >= src_h)
      sy = src_h - 1;

    for (int dx = 0; dx < dst_w; dx++) {
      int px = bx + dx;
      if (px < 0 || px >= img_w)
        continue;

      int sx = do_scale ? (int)((double)dx / scale) : dx;
      if (sx >= src_w)
        sx = src_w - 1;

      if (is_color) {
        int idx = sy * bm->pitch + sx * 4;
        uint8_t b = bm->buffer[idx + 0];
        uint8_t g = bm->buffer[idx + 1];
        uint8_t r = bm->buffer[idx + 2];
        uint8_t a = bm->buffer[idx + 3];
        if (a == 0)
          continue;
        uint32_t e = dst_row[px];
        uint8_t er = (e >> 16) & 0xFF;
        uint8_t eg = (e >> 8) & 0xFF;
        uint8_t eb = e & 0xFF;
        uint16_t inv = 255 - a;
        uint8_t nr = (uint8_t)((r * a + er * inv) / 255);
        uint8_t ng = (uint8_t)((g * a + eg * inv) / 255);
        uint8_t nb = (uint8_t)((b * a + eb * inv) / 255);
        dst_row[px] = ((uint32_t)nr << 16) | ((uint32_t)ng << 8) | nb;
      } else {
        uint8_t a = bm->buffer[sy * bm->pitch + sx];
        if (a == 0)
          continue;
        blend(&dst_row[px], fr, fgn, fb, a);
      }
    }
  }
}

void xft_draw(void *ptr, Display *dpy, Drawable d, GC gc, int x, int y,
              const char *text, unsigned long fg, unsigned long bg) {
  XftCtx *ctx = (XftCtx *)ptr;

  int tw, th;
  xft_text_extent(ptr, text, &tw, &th);
  if (tw <= 0 || th <= 0)
    return;

  int lh = xft_line_height(ptr);
  int pad_top = 4;
  int pad_bot = 2;
  int pad_lr = 2;

  int img_w = tw + pad_lr * 2;
  int img_h = th + pad_top + pad_bot;

  uint32_t *buf = (uint32_t *)malloc((size_t)img_w * img_h * sizeof(uint32_t));
  if (!buf)
    return;

  uint32_t bg_pixel = (uint32_t)(bg & 0xFFFFFF);
  for (int i = 0; i < img_w * img_h; i++)
    buf[i] = bg_pixel;

  int pen_y = pad_top + (int)(ctx->primary->size->metrics.ascender >> 6);
  const char *ls = text;
  hb_buffer_t *hb_buf = hb_buffer_create();

  while (1) {
    const char *le = strchr(ls, '\n');
    size_t line_len = le ? (size_t)(le - ls) : strlen(ls);

    if (line_len > 0) {
      double pen_x = pad_lr;
      const unsigned char *p = (const unsigned char *)ls;
      const unsigned char *end = p + line_len;

      while (p < end) {
        unsigned int cp;
        int n = utf8_decode(p, &cp);
        FT_Face run_face = pick_face(ctx, cp);
        const unsigned char *q = p + n;
        while (q < end) {
          unsigned int c2;
          int n2 = utf8_decode(q, &c2);
          if (pick_face(ctx, c2) != run_face)
            break;
          q += n2;
        }
        size_t run_len = (size_t)(q - p);
        double sc = face_scale(run_face, ctx->size);

        shape_run(run_face, p, run_len, hb_buf);
        unsigned int gc2;
        hb_glyph_info_t *info = hb_buffer_get_glyph_infos(hb_buf, &gc2);
        hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(hb_buf, &gc2);

        for (unsigned int i = 0; i < gc2; i++) {
          int gx = (int)(pen_x + (pos[i].x_offset >> 6) * sc);
          int gy = pen_y + (int)((pos[i].y_offset >> 6) * sc);
          rasterize_glyph(buf, img_w, img_h, run_face, info[i].codepoint, gx,
                          gy, fg, sc);
          pen_x += (pos[i].x_advance >> 6) * sc;
        }
        p = q;
      }
    }

    if (!le)
      break;
    pen_y += lh + 4;
    ls = le + 1;
  }
  hb_buffer_destroy(hb_buf);

  int scr = DefaultScreen(dpy);
  Visual *visual = DefaultVisual(dpy, scr);
  int scr_depth = DefaultDepth(dpy, scr);

  XImage *img = XCreateImage(dpy, visual, scr_depth, ZPixmap, 0, NULL, img_w,
                             img_h, 32, 0);
  if (!img) {
    free(buf);
    return;
  }

  img->data = (char *)calloc(1, (size_t)img->bytes_per_line * img_h);
  if (!img->data) {
    img->data = NULL;
    XDestroyImage(img);
    free(buf);
    return;
  }

  if (img->bits_per_pixel == 32) {
    for (int yy = 0; yy < img_h; yy++) {
      memcpy(img->data + (size_t)yy * img->bytes_per_line,
             buf + (size_t)yy * img_w, (size_t)img_w * 4);
    }
  } else {
    for (int yy = 0; yy < img_h; yy++)
      for (int xx = 0; xx < img_w; xx++)
        XPutPixel(img, xx, yy, buf[(size_t)yy * img_w + xx]);
  }

  XSetFunction(dpy, gc, GXcopy);
  XPutImage(dpy, d, gc, img, 0, 0, x, y, img_w, img_h);

  XDestroyImage(img);
  free(buf);
}

/* ── Software surface helpers ───────────────────────────── */
static inline void blend_px(uint32_t *dst, uint32_t srgb, uint8_t a) {
  if (a == 0)
    return;
  if (a == 255) {
    *dst = srgb & 0xFFFFFF;
    return;
  }
  uint32_t d = *dst;
  uint16_t inv = 255 - a;
  uint8_t dr = (d >> 16) & 0xFF, dg = (d >> 8) & 0xFF, db = d & 0xFF;
  uint8_t sr = (srgb >> 16) & 0xFF, sg = (srgb >> 8) & 0xFF, sb = srgb & 0xFF;
  uint8_t nr = (uint8_t)((sr * a + dr * inv) / 255);
  uint8_t ng = (uint8_t)((sg * a + dg * inv) / 255);
  uint8_t nb = (uint8_t)((sb * a + db * inv) / 255);
  *dst = ((uint32_t)nr << 16) | ((uint32_t)ng << 8) | nb;
}

void surf_fill(uint32_t *buf, int W, int H, int x, int y, int w, int h,
               unsigned int color) {
  if (x < 0) {
    w += x;
    x = 0;
  }
  if (y < 0) {
    h += y;
    y = 0;
  }
  if (x + w > W)
    w = W - x;
  if (y + h > H)
    h = H - y;
  if (w <= 0 || h <= 0)
    return;
  uint32_t c = color & 0xFFFFFF;
  for (int i = 0; i < h; i++) {
    uint32_t *row = buf + (size_t)(y + i) * W + x;
    for (int j = 0; j < w; j++)
      row[j] = c;
  }
}

static void corner_aa(uint32_t *buf, int W, int H, int rx, int ry, int r,
                      uint32_t color, int cx_dir, int cy_dir) {
  /* rx, ry = top-left of the r×r corner box; cx_dir/cy_dir: +1 or -1 */
  const int N = 4;
  const float step = 1.0f / N;
  float ccx = rx + (cx_dir > 0 ? r : 0);
  float ccy = ry + (cy_dir > 0 ? r : 0);
  float rr = (float)r * r;
  for (int py = 0; py < r; py++) {
    int Y = ry + py;
    if (Y < 0 || Y >= H)
      continue;
    for (int px = 0; px < r; px++) {
      int X = rx + px;
      if (X < 0 || X >= W)
        continue;
      int hits = 0;
      for (int sy = 0; sy < N; sy++) {
        for (int sx = 0; sx < N; sx++) {
          float fx = X + (sx + 0.5f) * step;
          float fy = Y + (sy + 0.5f) * step;
          float dx = fx - ccx, dy = fy - ccy;
          if (dx * dx + dy * dy <= rr)
            hits++;
        }
      }
      if (hits > 0) {
        uint8_t a = (uint8_t)((hits * 255) / (N * N));
        blend_px(&buf[(size_t)Y * W + X], color, a);
      }
    }
  }
}

void surf_rrect_aa(uint32_t *buf, int W, int H, int x, int y, int w, int h,
                   int r, unsigned int color) {
  uint32_t c = color & 0xFFFFFF;
  if (r <= 0 || r * 2 >= w || r * 2 >= h) {
    surf_fill(buf, W, H, x, y, w, h, c);
    return;
  }
  /* 3 solid slabs */
  surf_fill(buf, W, H, x + r, y, w - 2 * r, h, c);
  surf_fill(buf, W, H, x, y + r, r, h - 2 * r, c);
  surf_fill(buf, W, H, x + w - r, y + r, r, h - 2 * r, c);
  /* 4 corners */
  corner_aa(buf, W, H, x, y, r, c, +1, +1);
  corner_aa(buf, W, H, x + w - r, y, r, c, -1, +1);
  corner_aa(buf, W, H, x, y + h - r, r, c, +1, -1);
  corner_aa(buf, W, H, x + w - r, y + h - r, r, c, -1, -1);
}

/* Draw text directly into a caller-provided ARGB buffer */
void xft_draw_rgba(void *ptr, uint32_t *buf, int bw, int bh, int x, int y,
                   const char *text, unsigned long fg) {
  XftCtx *ctx = (XftCtx *)ptr;
  int lh = xft_line_height(ptr);
  const char *ls = text;
  hb_buffer_t *hb_buf = hb_buffer_create();

  int baseline = y + (int)(ctx->primary->size->metrics.ascender >> 6);

  while (1) {
    const char *le = strchr(ls, '\n');
    size_t line_len = le ? (size_t)(le - ls) : strlen(ls);
    if (line_len > 0) {
      double pen_x = x;
      const unsigned char *p = (const unsigned char *)ls;
      const unsigned char *end = p + line_len;
      while (p < end) {
        unsigned int cp;
        int n = utf8_decode(p, &cp);
        FT_Face run_face = pick_face(ctx, cp);
        const unsigned char *q = p + n;
        while (q < end) {
          unsigned int c2;
          int n2 = utf8_decode(q, &c2);
          if (pick_face(ctx, c2) != run_face)
            break;
          q += n2;
        }
        double sc = face_scale(run_face, ctx->size);
        shape_run(run_face, p, (size_t)(q - p), hb_buf);
        unsigned int gc2;
        hb_glyph_info_t *info = hb_buffer_get_glyph_infos(hb_buf, &gc2);
        hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(hb_buf, &gc2);
        for (unsigned int i = 0; i < gc2; i++) {
          int gx = (int)(pen_x + (pos[i].x_offset >> 6) * sc);
          int gy = baseline + (int)((pos[i].y_offset >> 6) * sc);
          rasterize_glyph(buf, bw, bh, run_face, info[i].codepoint, gx, gy, fg,
                          sc);
          pen_x += (pos[i].x_advance >> 6) * sc;
        }
        p = q;
      }
    }
    if (!le)
      break;
    baseline += lh + 4;
    ls = le + 1;
  }
  hb_buffer_destroy(hb_buf);
}

/* Attach a caller-owned buffer to an XImage, freeing X's internal one.
   Keeps the XImage struct layout hidden from Lua FFI. */
void surf_take_ximg_data(void *img_ptr, void *buf) {
  XImage *img = (XImage *)img_ptr;
  if (!img)
    return;
  if (img->data)
    free(img->data);
  img->data = (char *)buf;
}

/* 生成一个 1-bit 圆角遮罩 pixmap，供 XShapeCombineMask 使用 */
Pixmap xpm_make_rrect_mask(Display *dpy, Window win, int W, int H, int r) {
  Pixmap p = XCreatePixmap(dpy, win, W, H, 1);
  if (!p)
    return 0;
  GC gc = XCreateGC(dpy, p, 0, NULL);
  XSetForeground(dpy, gc, 0);
  XFillRectangle(dpy, p, gc, 0, 0, W, H);
  XSetForeground(dpy, gc, 1);
  if (r <= 0 || r * 2 >= W || r * 2 >= H) {
    XFillRectangle(dpy, p, gc, 0, 0, W, H);
  } else {
    XFillRectangle(dpy, p, gc, r, 0, W - 2 * r, H);
    XFillRectangle(dpy, p, gc, 0, r, r, H - 2 * r);
    XFillRectangle(dpy, p, gc, W - r, r, r, H - 2 * r);
    int D = 64;
    XFillArc(dpy, p, gc, 0, 0, 2 * r, 2 * r, 90 * D, 90 * D);
    XFillArc(dpy, p, gc, W - 2 * r, 0, 2 * r, 2 * r, 0, 90 * D);
    XFillArc(dpy, p, gc, 0, H - 2 * r, 2 * r, 2 * r, 180 * D, 90 * D);
    XFillArc(dpy, p, gc, W - 2 * r, H - 2 * r, 2 * r, 2 * r, 270 * D, 90 * D);
  }
  XFreeGC(dpy, gc);
  return p;
}

/* Detach the XImage from whatever data pointer it holds, WITHOUT freeing.
   Used before XDestroyImage when data is owned by the caller (LuaJIT GC). */
void surf_ximg_detach(void *img_ptr) {
  XImage *img = (XImage *)img_ptr;
  if (img)
    img->data = NULL;
}
