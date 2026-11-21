#ifndef DALNY_SESSION_H
#define DALNY_SESSION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

typedef struct RDPSession RDPSession;

typedef struct RDPParams
{
	char host[256];
	int port;
	char username[128];
	char password[256];
	int width;
	int height;
	int colorDepth;
	int profile;
	int clipboard;
	char trustedFingerprint[512];
	char pluginsDir[1024];
} RDPParams;

typedef struct RDPHandlers
{
	void* ctx;
	void (*logmsg)(void* ctx, const char* line);
	void (*frame)(void* ctx, const uint8_t* bgra, int width, int height, int stride, int x, int y,
	              int w, int h);
	void (*resized)(void* ctx, int width, int height);
	void (*clipboard_text)(void* ctx, const char* utf8);
	int (*ask_certificate)(void* ctx, const char* fingerprint, int changed);
	void (*disconnected)(void* ctx, int fatal, const char* reason);
} RDPHandlers;

RDPSession* rdp_session_create(const RDPParams* params, const RDPHandlers* handlers);
void rdp_session_start(RDPSession* session);
void rdp_session_stop(RDPSession* session);
void rdp_session_destroy(RDPSession* session);

void rdp_session_send_scancode(RDPSession* session, uint32_t rdpScancode, int down, int repeat);
/* button: 0 move, 1 left, 2 right, 3 middle. down is ignored for move.
   wheelNotches is separate so a click and a wheel are not mixed. */
void rdp_session_send_mouse(RDPSession* session, int x, int y, int button, int down);
void rdp_session_send_wheel(RDPSession* session, int wheelNotches);
void rdp_session_request_resize(RDPSession* session, int width, int height);
void rdp_session_set_clipboard_utf8(RDPSession* session, const char* utf8);
void rdp_session_remote_size(RDPSession* session, int* width, int* height);

#ifdef __cplusplus
}
#endif

#endif
