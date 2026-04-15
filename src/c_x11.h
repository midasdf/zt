// Wrapper header for xcb + xkb + xim + shm translate-c.
// xcb/shm.h declares `extern xcb_extension_t xcb_shm_id;` which translate-c
// (Zig 0.16) cannot render because xcb_extension_t is an opaque struct.
// We rename the symbol via macro so translate-c emits a harmless _zt_xcb_shm_id_stub
// decl that is never referenced. The real xcb_shm_id is declared manually in x11.zig.
#define xcb_shm_id _zt_xcb_shm_id_stub
#include <xcb/xcb.h>
#include <xcb/shm.h>
#undef xcb_shm_id
#include <sys/shm.h>
#include <xcb-imdkit/imclient.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-x11.h>
