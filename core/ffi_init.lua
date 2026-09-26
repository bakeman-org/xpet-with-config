return function(SCRIPT_DIR)
  local ffi = require('ffi')
  local bit = require('bit')

  ffi.cdef([[
typedef struct _XDisplay Display;
typedef unsigned long Window;
typedef unsigned long Drawable;
typedef unsigned long Pixmap;
typedef unsigned long Font;
typedef struct _XGC *GC;
typedef unsigned long KeySym;
typedef unsigned char KeyCode;
typedef int Bool;
typedef unsigned long XID;
typedef struct _XImage XImage;

typedef struct _XIM *XIM;
typedef struct _XIC *XIC;
typedef unsigned long XIMStyle;
typedef void *XrmDatabase;

typedef struct {
  int type;
  unsigned long serial;
  int send_event;
  Display *display;
  Window window;
} XAnyEvent;

typedef struct {
  int type;
  unsigned long serial;
  int send_event;
  Display *display;
  Window window;
  Window root;
  Window subwindow;
  unsigned long time;
  int x, y, x_root, y_root;
  unsigned int state;
  unsigned int keycode;
  int same_screen;
} XKeyEvent;
typedef struct {
  int type;
  unsigned long serial;
  int send_event;
  Display *display;
  Window window;
  Window root;
  Window subwindow;
  unsigned long time;
  int x, y, x_root, y_root;
  unsigned int state;
  unsigned int button;
  int same_screen;
} XButtonEvent;
typedef struct {
  int type;
  unsigned long serial;
  int send_event;
  Display *display;
  Window window;
  int x, y, width, height, count;
} XExposeEvent;
typedef struct {
  int type;
  unsigned long serial;
  int send_event;
  Display *display;
  Window window;
  Window root;
  Window subwindow;
  unsigned long time;
  int x, y, x_root, y_root;
  unsigned int state;
  char is_hint;
  int same_screen;
} XMotionEvent;
typedef union {
  int type;
  XAnyEvent xany;
  XKeyEvent xkey;
  XButtonEvent xbutton;
  XExposeEvent xexpose;
  XMotionEvent xmotion;
  long pad[24];
} XEvent;

typedef struct {
  int type;
  Display *display;
  XID resourceid;
  unsigned long serial;
  unsigned char error_code;
  unsigned char request_code;
  unsigned char minor_code;
} XErrorEvent;
typedef int (*XErrorHandler)(Display *, XErrorEvent *);

typedef struct {
  unsigned long background_pixmap;
  unsigned long background_pixel;
  unsigned long border_pixmap;
  unsigned long border_pixel;
  int bit_gravity, win_gravity, backing_store;
  unsigned long backing_planes, backing_pixel;
  int save_under;
  long event_mask;
  long do_not_propagate_mask;
  int override_redirect;
  unsigned long colormap, cursor;
} XSetWindowAttributes;

typedef struct {
  int valuemask;
  void *visual;
  unsigned long colormap;
  unsigned int depth;
  int width;
  int height;
  int x_hotspot;
  int y_hotspot;
  unsigned int cpp;
  void *pixels;
  unsigned int npixels;
  void *colorsymbols;
  unsigned int numsymbols;
  char *rgb_fname;
  unsigned int nextensions;
  void *extensions;
  unsigned int ncolors;
  void *colorTable;
  int nkeys;
  char **xpm_data;
  int xpm_data_size;
  void *data_colors;
  int n_data_colors;
} XpmAttributes;

Display *XOpenDisplay(const char *display_name);
int XCloseDisplay(Display *display);
int XDefaultScreen(Display *display);
Window XRootWindow(Display *display, int screen_number);
int XDefaultDepth(Display *display, int screen_number);
unsigned long XBlackPixel(Display *display, int screen_number);
unsigned long XWhitePixel(Display *display, int screen_number);
int XDisplayWidth(Display *display, int screen_number);
int XDisplayHeight(Display *display, int screen_number);
Window XCreateWindow(Display *display, Window parent, int x, int y,
                     unsigned int width, unsigned int height,
                     unsigned int border_width, int depth, unsigned int class_,
                     void *visual, unsigned long valuemask,
                     XSetWindowAttributes *attributes);
int XDestroyWindow(Display *display, Window w);
int XSelectInput(Display *display, Window window, long event_mask);
int XMapWindow(Display *display, Window window);
int XUnmapWindow(Display *display, Window window);
int XMoveWindow(Display *display, Window window, int x, int y);
int XResizeWindow(Display *display, Window window, unsigned int width,
                  unsigned int height);
int XRaiseWindow(Display *display, Window window);
int XClearWindow(Display *display, Window window);
int XFlush(Display *display);
int XSync(Display *display, Bool discard);
int XPending(Display *display);
int XNextEvent(Display *display, XEvent *event);
Pixmap XCreatePixmap(Display *display, Drawable d, unsigned int width,
                     unsigned int height, unsigned int depth);
int XFreePixmap(Display *display, Pixmap pixmap);
GC XCreateGC(Display *display, Drawable d, unsigned long valuemask,
             void *values);
int XFreeGC(Display *display, GC gc);
int XSetForeground(Display *display, GC gc, unsigned long foreground);
int XSetBackground(Display *display, GC gc, unsigned long background);
int XFillRectangle(Display *display, Drawable d, GC gc, int x, int y,
                   unsigned int width, unsigned int height);
int XFillArc(Display *display, Drawable d, GC gc, int x, int y,
             unsigned int width, unsigned int height, int angle1, int angle2);
int XDrawRectangle(Display *display, Drawable d, GC gc, int x, int y,
                   unsigned int width, unsigned int height);
int XCopyArea(Display *display, Drawable src, Drawable dest, GC gc, int src_x,
              int src_y, unsigned int width, unsigned int height, int dest_x,
              int dest_y);
int XGrabKey(Display *display, int keycode, unsigned int modifiers,
             Window grab_window, Bool owner_events, int pointer_mode,
             int keyboard_mode);
int XUngrabKey(Display *display, int keycode, unsigned int modifiers,
               Window grab_window);
KeySym XStringToKeysym(const char *string);
KeyCode XKeysymToKeycode(Display *display, KeySym keysym);
const char *XKeysymToString(KeySym keysym);
XErrorHandler XSetErrorHandler(XErrorHandler handler);
int XGetGeometry(Display *display, Drawable d, Window *root_return,
                 int *x_return, int *y_return, unsigned int *width_return,
                 unsigned int *height_return, unsigned int *border_width_return,
                 unsigned int *depth_return);
int XSetWindowBackgroundPixmap(Display *display, Window w, Pixmap pixmap);
int XQueryPointer(Display *display, Window w, Window *root_return,
                  Window *child_return, int *root_x_return, int *root_y_return,
                  int *win_x_return, int *win_y_return,
                  unsigned int *mask_return);
XImage *XGetImage(Display *display, Drawable d, int x, int y,
                  unsigned int width, unsigned int height,
                  unsigned long plane_mask, int format);
unsigned long XGetPixel(XImage *ximage, int x, int y);
XImage *XCreateImage(Display *display, void *visual, unsigned int depth,
                     int format, int offset, char *data, unsigned int width,
                     unsigned int height, int bitmap_pad, int bytes_per_line);
int XPutImage(Display *display, Drawable d, GC gc, XImage *image, int src_x,
              int src_y, int dest_x, int dest_y, unsigned int width,
              unsigned int height);
void *XDefaultVisual(Display *display, int screen_number);
int XDestroyImage(XImage *ximage);

void XShapeCombineMask(Display *dpy, Window dest, int destKind, int xOff,
                       int yOff, Pixmap src, int op);
int XpmReadFileToPixmap(Display *display, Drawable d, const char *filename,
                        Pixmap *pixmap_return, Pixmap *mask_return,
                        XpmAttributes *attributes);

KeySym XLookupKeysym(XKeyEvent *key_event, int index);
int XLookupString(XKeyEvent *event_struct, char *buffer_return,
                  int bytes_buffer, KeySym *keysym_return, void *status_in_out);

int XGrabKeyboard(Display *display, Window grab_window, Bool owner_events,
                  int pointer_mode, int keyboard_mode, unsigned long time);
int XUngrabKeyboard(Display *display, unsigned long time);
int XSetInputFocus(Display *display, Window focus, int revert_to,
                   unsigned long time);
Window XGetInputFocus(Display *display, Window *focus_return,
                      int *revert_to_return);
int XAllowEvents(Display *display, int event_mode, unsigned long time);

XIM XOpenIM(Display *display, XrmDatabase db, char *res_name, char *res_class);
int XCloseIM(XIM im);
XIC XCreateIC(XIM im, ...);
void XDestroyIC(XIC ic);
void XSetICFocus(XIC ic);
void XUnsetICFocus(XIC ic);
Bool XFilterEvent(XEvent *event, Window w);
int Xutf8LookupString(XIC ic, XKeyEvent *event, char *buffer_return,
                      int bytes_buffer, KeySym *keysym_return,
                      int *status_return);

int usleep(unsigned int usec);

int xft_init(void);
void *xft_load(const char *primary_path, int size, const char *fallback_paths);
void xft_done(void *ctx);
int xft_line_height(void *ctx);
void xft_text_extent(void *ctx, const char *text, int *w_out, int *h_out);
void xft_draw(void *ctx, Display *dpy, Drawable d, GC gc, int x, int y,
              const char *text, unsigned long fg, unsigned long bg);
void xft_draw_rgba(void *ctx, uint32_t *buf, int bw, int bh, int x, int y,
                   const char *text, unsigned long fg);
void surf_fill(uint32_t *buf, int W, int H, int x, int y, int w, int h,
               unsigned int color);
void surf_rrect_aa(uint32_t *buf, int W, int H, int x, int y, int w, int h,
                   int r, unsigned int color);
void surf_take_ximg_data(void *img, void *buf);
int xft_primary_line_height(void *ctx);
Pixmap xpm_make_rrect_mask(Display *dpy, Window win, int W, int H, int r);
void surf_ximg_detach(void *img);

int audio_init(void);
void audio_shutdown(void);
int audio_play(const char *path);
void audio_toggle_pause(void);
void audio_stop(void);
int audio_is_playing(void);
int audio_is_paused(void);
void audio_set_volume(int v0_100);
double audio_get_position(void);
double audio_get_duration(void);
int audio_scan_dir(const char *dir);
const char *audio_scan_get(int idx);
void audio_seek(double sec);
double audio_probe_duration(const char *path);
int audio_play_sfx(const char *path, int vol_0_100);
int audio_finished(void);
    ]])

  local X11 = ffi.load('X11')
  local Xext = ffi.load('Xext')
  local Xpm = ffi.load('Xpm')
  local libc = ffi.load('c')
  local FT = ffi.load(SCRIPT_DIR .. '/xpet_ft.so')

  local has_aud, AUD = pcall(function()
    return ffi.load(SCRIPT_DIR .. '/xpet_audio.so')
  end)
  if not has_aud then
    AUD = nil
  end

  return {
    ffi = ffi,
    bit = bit,
    X11 = X11,
    Xext = Xext,
    Xpm = Xpm,
    libc = libc,
    FT = FT,
    AUD = AUD,
  }
end
