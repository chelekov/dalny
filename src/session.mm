#include "session.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/dc.h>
#include <freerdp/gdi/region.h>
#include <freerdp/codec/color.h>
#include <freerdp/constants.h>
#include <freerdp/addin.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/error.h>

#include <winpr/wlog.h>
#include <winpr/clipboard.h>
#include <winpr/user.h>
#include <winpr/synch.h>
#include <winpr/collections.h>
#include <winpr/string.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>

static void wipe_bytes(void* buffer, size_t length)
{
	volatile unsigned char* bytes = (volatile unsigned char*)buffer;
	while (length > 0)
		bytes[--length] = 0;
}

struct RDPSession
{
	RDPParams params;
	RDPHandlers handlers;
	rdpContext* context;
	freerdp* instance;
	pthread_t thread;
	int threadStarted;
	volatile int stop;
	int authFailed;
	int certRejected;
	HANDLE stopEvent;
	HANDLE resizeEvent;
	int resizeWidth;
	int resizeHeight;
	int remoteWidth;
	int remoteHeight;
	pthread_mutex_t lock;

	CliprdrClientContext* cliprdr;
	wClipboard* clipboard;
	UINT32* serverFormatIds;
	char** serverFormatNames;
	UINT32 serverFormatCount;
	UINT32 requestedFormatId;
	char* pendingClipboard;
	BYTE* pendingDib;
	UINT32 pendingDibLength;
	/* When the Mac last offered a picture. The server's clipboard helper re-offers that picture
	 * as image/png + image/bmp, and xrdp then announces it back to us; the first picture-only
	 * announcement shortly after is that echo and is not fetched. */
	uint64_t sentDibMs;

	DispClientContext* disp;
	int resizeNoteLogged;

	/* Link probe: when the server has been quiet for a while, ask it to repaint a tiny area
	 * (Refresh Rect PDU) and time the answer. Any update counts as an answer. */
	volatile uint64_t lastActivityMs;
	volatile uint64_t probeSentMs;
	uint64_t lastProbeMs;
	uint64_t lastLinkReportMs;
	volatile int probesAnswered;
};

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

typedef struct
{
	rdpClientContext common;
	RDPSession* session;
} DalnyContext;

static FREERDP_LOAD_CHANNEL_ADDIN_ENTRY_FN g_previousProvider = nullptr;
static char g_pluginDir[1024] = {0};

static void log_line(RDPSession* session, const char* line)
{
	if (session && session->handlers.logmsg && line)
		session->handlers.logmsg(session->handlers.ctx, line);
}

/* FreeRDP WLog -> in-app log. Warnings and errors of the active session. */
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;
static RDPSession* g_logSession = nullptr;
static pthread_once_t g_wlogOnce = PTHREAD_ONCE_INIT;

static BOOL wlog_message(const wLogMessage* msg)
{
	if (!msg || !msg->TextString)
		return TRUE;
	if (msg->Level >= WLOG_WARN)
		fprintf(stderr, "%s\n", msg->TextString);
	if (msg->Level < WLOG_WARN || msg->Level > WLOG_FATAL)
		return TRUE;
	const char* level = msg->Level >= WLOG_FATAL ? "FATAL" : (msg->Level >= WLOG_ERROR ? "ERROR" : "WARN");
	char line[1024];
	snprintf(line, sizeof(line), "FreeRDP %s [%s]: %s", level,
	         msg->FunctionName ? msg->FunctionName : "?", msg->TextString);
	pthread_mutex_lock(&g_logLock);
	log_line(g_logSession, line);
	pthread_mutex_unlock(&g_logLock);
	return TRUE;
}

static void wlog_install(void)
{
	wLog* root = WLog_GetRoot();
	if (!root || !WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK))
		return;
	wLogCallbacks callbacks;
	memset(&callbacks, 0, sizeof(callbacks));
	callbacks.message = wlog_message;
	wLogAppender* appender = WLog_GetLogAppender(root);
	if (appender)
		(void)WLog_ConfigureAppender(appender, "callbacks", &callbacks);
}

static void set_log_session(RDPSession* session, RDPSession* expected)
{
	pthread_mutex_lock(&g_logLock);
	if (!expected || g_logSession == expected)
		g_logSession = session;
	pthread_mutex_unlock(&g_logLock);
}

static void log_last_error(RDPSession* session, const char* stage, UINT32 code)
{
	const char* name = freerdp_get_last_error_name(code);
	const char* text = freerdp_get_last_error_string(code);
	char line[512];
	snprintf(line, sizeof(line), "%s: %s (0x%08X) — %s", stage, name ? name : "?", (unsigned)code,
	         text ? text : "?");
	log_line(session, line);
}

static int error_is_config(UINT32 code)
{
	return code == FREERDP_ERROR_PRE_CONNECT_FAILED || code == FREERDP_ERROR_POST_CONNECT_FAILED;
}

/* Wrong or missing user name / password. The UI asks for them again instead of retrying. */
static int error_is_credentials(UINT32 code)
{
	return code == FREERDP_ERROR_AUTHENTICATION_FAILED || code == FREERDP_ERROR_CONNECT_LOGON_FAILURE ||
	       code == FREERDP_ERROR_CONNECT_WRONG_PASSWORD ||
	       code == FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS;
}

static RDPSession* session_from(rdpContext* context)
{
	if (!context)
		return nullptr;
	return ((DalnyContext*)context)->session;
}

static char* normalize_fingerprint(const char* fingerprint)
{
	if (!fingerprint)
		return nullptr;
	size_t length = strlen(fingerprint);
	char* out = (char*)calloc(length + 1, 1);
	if (!out)
		return nullptr;
	size_t j = 0;
	for (size_t i = 0; i < length; i++)
	{
		unsigned char c = (unsigned char)fingerprint[i];
		if (c == ':' || c == ' ' || c == '\t')
			continue;
		out[j++] = (char)tolower(c);
	}
	return out;
}

static int fingerprints_match(const char* stored, const char* presented)
{
	if (!stored || !stored[0] || !presented || !presented[0])
		return 0;
	char* a = normalize_fingerprint(stored);
	char* b = normalize_fingerprint(presented);
	int match = (a && b && strcmp(a, b) == 0);
	free(a);
	free(b);
	return match;
}

static DWORD verify_certificate(freerdp* instance, const char* fingerprint)
{
	RDPSession* session = session_from(instance ? instance->context : nullptr);
	if (!session)
		return 0;
	if (!fingerprint)
		fingerprint = "";

	if (fingerprints_match(session->params.trustedFingerprint, fingerprint))
	{
		log_line(session, "Сертификат совпал с сохранённым отпечатком.");
		return 1;
	}

	int changed = session->params.trustedFingerprint[0] != '\0';
	char line[768];
	snprintf(line, sizeof(line), "Проверка сертификата: %s", fingerprint);
	log_line(session, line);

	int accept = 0;
	if (session->handlers.ask_certificate)
		accept = session->handlers.ask_certificate(session->handlers.ctx, fingerprint, changed);
	if (!accept)
	{
		session->certRejected = 1;
		log_line(session, "Сертификат отклонён.");
		return 0;
	}

	snprintf(session->params.trustedFingerprint, sizeof(session->params.trustedFingerprint), "%s",
	         fingerprint);
	log_line(session, changed ? "Сохранён новый отпечаток сертификата."
	                          : "Отпечаток сертификата сохранён.");
	return 1;
}

static DWORD verify_cert_ex(freerdp* instance, const char* host, UINT16 port, const char* commonName,
                            const char* subject, const char* issuer, const char* fingerprint,
                            DWORD flags)
{
	(void)host;
	(void)port;
	(void)commonName;
	(void)subject;
	(void)issuer;
	(void)flags;
	return verify_certificate(instance, fingerprint);
}

static DWORD verify_changed_cert_ex(freerdp* instance, const char* host, UINT16 port,
                                    const char* commonName, const char* subject, const char* issuer,
                                    const char* fingerprint, const char* oldSubject,
                                    const char* oldIssuer, const char* oldFingerprint, DWORD flags)
{
	(void)host;
	(void)port;
	(void)commonName;
	(void)subject;
	(void)issuer;
	(void)oldSubject;
	(void)oldIssuer;
	(void)oldFingerprint;
	(void)flags;
	return verify_certificate(instance, fingerprint);
}

static BOOL authenticate_ex(freerdp* instance, char** username, char** password, char** domain,
                            rdp_auth_reason reason)
{
	(void)domain;
	RDPSession* session = session_from(instance ? instance->context : nullptr);
	if (reason == AUTH_SMARTCARD_PIN)
		return FALSE;
	if (username && *username && *username[0] && password && *password && *password[0])
		return TRUE;
	if (!session || !session->params.password[0] || !session->params.username[0])
	{
		if (session)
			session->authFailed = 1;
		return FALSE;
	}
	if (username && !*username)
		*username = _strdup(session->params.username);
	if (password && !*password)
		*password = _strdup(session->params.password);
	return TRUE;
}

static int logon_error_info(freerdp* instance, UINT32 data, UINT32 type)
{
	RDPSession* session = session_from(instance ? instance->context : nullptr);
	const char* dataText = freerdp_get_logon_error_info_data(data);
	const char* typeText = freerdp_get_logon_error_info_type(type);
	char line[512];
	snprintf(line, sizeof(line), "Ответ входа: %s (%s)", typeText ? typeText : "?",
	         dataText ? dataText : "?");
	if (session)
	{
		log_line(session, line);
		if (typeText && (strstr(typeText, "FAIL") || strstr(typeText, "ERR") ||
		                 strstr(typeText, "DENIED")))
			session->authFailed = 1;
	}
	return 1;
}

static BOOL begin_paint(rdpContext* context)
{
	rdpGdi* gdi = context ? context->gdi : nullptr;
	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd ||
	    !gdi->primary->hdc->hwnd->invalid)
		return TRUE;
	gdi->primary->hdc->hwnd->invalid->null = TRUE;
	return TRUE;
}

static void note_activity(RDPSession* session)
{
	if (!session)
		return;
	uint64_t now = now_ms();
	uint64_t sent = session->probeSentMs;
	session->lastActivityMs = now;
	if (sent)
	{
		session->probeSentMs = 0;
		session->probesAnswered += 1;
		if (session->handlers.link)
			session->handlers.link(session->handlers.ctx, (int)(now - sent), 0, 1);
	}
}

static BOOL end_paint(rdpContext* context)
{
	RDPSession* session = session_from(context);
	note_activity(session);
	rdpGdi* gdi = context ? context->gdi : nullptr;
	if (!session || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
		return TRUE;
	HGDI_RGN invalid = gdi->primary->hdc->hwnd->invalid;
	if (!invalid || invalid->null)
		return TRUE;

	int x = invalid->x;
	int y = invalid->y;
	int w = invalid->w;
	int h = invalid->h;
	gdi->primary->hdc->hwnd->ninvalid = 0;
	session->remoteWidth = gdi->width;
	session->remoteHeight = gdi->height;
	if (session->handlers.frame && gdi->primary_buffer)
	{
		session->handlers.frame(session->handlers.ctx, gdi->primary_buffer, gdi->width, gdi->height,
		                        (int)gdi->stride, x, y, w, h);
	}
	return TRUE;
}

static BOOL desktop_resize(rdpContext* context)
{
	RDPSession* session = session_from(context);
	if (!context || !context->gdi)
		return TRUE;
	UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
	UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
	if (!gdi_resize(context->gdi, width, height))
		return FALSE;
	if (session)
	{
		session->remoteWidth = (int)width;
		session->remoteHeight = (int)height;
		if (session->handlers.resized)
			session->handlers.resized(session->handlers.ctx, (int)width, (int)height);
		char line[128];
		snprintf(line, sizeof(line), "Размер рабочего стола: %ux%u", width, height);
		log_line(session, line);
	}
	return TRUE;
}

static void free_server_formats(RDPSession* session)
{
	if (!session->serverFormatNames)
	{
		free(session->serverFormatIds);
		session->serverFormatIds = nullptr;
		session->serverFormatCount = 0;
		return;
	}
	for (UINT32 i = 0; i < session->serverFormatCount; i++)
		free(session->serverFormatNames[i]);
	free(session->serverFormatNames);
	free(session->serverFormatIds);
	session->serverFormatNames = nullptr;
	session->serverFormatIds = nullptr;
	session->serverFormatCount = 0;
}

/* Largest picture accepted either way: 64 MB of DIB data. */
#define DALNY_CLIP_MAX_DIB (64u * 1024u * 1024u)

/* Put pendingClipboard (text) into the WinPR clipboard, or empty it. Caller holds the lock. */
static void clip_load_text(RDPSession* session)
{
	if (!session->clipboard)
		return;
	ClipboardEmpty(session->clipboard);
	if (session->pendingClipboard)
	{
		UINT32 format = ClipboardRegisterFormat(session->clipboard, "text/plain;charset=utf-8");
		ClipboardSetData(session->clipboard, format, session->pendingClipboard,
		                 (UINT32)strlen(session->pendingClipboard) + 1);
	}
}

/* Text formats come from WinPR (it adds CF_UNICODETEXT, CF_TEXT, ...). A picture is offered as
 * CF_DIB, which xrdp 0.9 turns into image/bmp for X applications. Caller holds the lock. */
static UINT clip_send_format_list(RDPSession* session)
{
	if (!session->cliprdr || !session->clipboard)
		return CHANNEL_RC_OK;

	UINT32* ids = nullptr;
	UINT32 count = session->pendingClipboard ? ClipboardGetFormatIds(session->clipboard, &ids) : 0;
	CLIPRDR_FORMAT* formats = (CLIPRDR_FORMAT*)calloc(count + 1, sizeof(CLIPRDR_FORMAT));
	if (!formats)
	{
		free(ids);
		return CHANNEL_RC_NO_MEMORY;
	}
	UINT32 used = 0;
	for (UINT32 i = 0; i < count; i++)
	{
		if (ids[i] == CF_DIB || ids[i] == CF_DIBV5)
			continue;
		formats[used].formatId = ids[i];
		const char* name = ClipboardGetFormatName(session->clipboard, ids[i]);
		if (ids[i] > CF_MAX && name)
			formats[used].formatName = _strdup(name);
		used++;
	}
	if (session->pendingDib && session->pendingDibLength > 0)
	{
		formats[used].formatId = CF_DIB;
		used++;
	}

	CLIPRDR_FORMAT_LIST list = {};
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = used;
	list.formats = formats;
	UINT result = session->cliprdr->ClientFormatList(session->cliprdr, &list);
	for (UINT32 i = 0; i < used; i++)
		free(formats[i].formatName);
	free(formats);
	free(ids);
	return result;
}

static UINT clip_monitor_ready(CliprdrClientContext* cliprdr, const CLIPRDR_MONITOR_READY* ready)
{
	(void)ready;
	RDPSession* session = (RDPSession*)cliprdr->custom;
	CLIPRDR_CAPABILITIES caps;
	CLIPRDR_GENERAL_CAPABILITY_SET general;
	memset(&caps, 0, sizeof(caps));
	memset(&general, 0, sizeof(general));
	caps.cCapabilitiesSets = 1;
	caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = 12;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
	cliprdr->ClientCapabilities(cliprdr, &caps);

	pthread_mutex_lock(&session->lock);
	clip_load_text(session);
	UINT result = clip_send_format_list(session);
	pthread_mutex_unlock(&session->lock);
	log_line(session, "Буфер обмена подключён: текст и картинки в обе стороны.");
	return result;
}

static UINT clip_server_format_list(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST* list)
{
	RDPSession* session = (RDPSession*)cliprdr->custom;
	CLIPRDR_FORMAT_LIST_RESPONSE response;
	memset(&response, 0, sizeof(response));
	response.common.msgType = CB_FORMAT_LIST_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_OK;
	cliprdr->ClientFormatListResponse(cliprdr, &response);

	pthread_mutex_lock(&session->lock);
	free_server_formats(session);
	session->serverFormatCount = list->numFormats;
	if (list->numFormats > 0)
	{
		session->serverFormatIds = (UINT32*)calloc(list->numFormats, sizeof(UINT32));
		session->serverFormatNames = (char**)calloc(list->numFormats, sizeof(char*));
		for (UINT32 i = 0; i < list->numFormats; i++)
		{
			session->serverFormatIds[i] = list->formats[i].formatId;
			if (list->formats[i].formatName)
				session->serverFormatNames[i] = _strdup(list->formats[i].formatName);
		}
	}
	/* Text first (Unicode, then 8-bit). A picture only when there is no text. */
	UINT32 wanted = 0;
	int haveDib = 0;
	int haveDibV5 = 0;
	for (UINT32 i = 0; i < session->serverFormatCount; i++)
	{
		UINT32 id = session->serverFormatIds[i];
		if (id == CF_UNICODETEXT)
			wanted = CF_UNICODETEXT;
		else if (wanted != CF_UNICODETEXT && (id == CF_TEXT || id == CF_OEMTEXT))
			wanted = id;
		else if (id == CF_DIB)
			haveDib = 1;
		else if (id == CF_DIBV5)
			haveDibV5 = 1;
	}
	if (wanted == 0 && haveDib)
		wanted = CF_DIB;
	if (wanted == 0 && haveDibV5)
		wanted = CF_DIBV5;
	int echo = 0;
	if ((wanted == CF_DIB || wanted == CF_DIBV5) && session->sentDibMs != 0 &&
	    now_ms() - session->sentDibMs < 15000)
		echo = 1;
	session->sentDibMs = 0;
	if (echo)
		wanted = 0;
	session->requestedFormatId = wanted;
	pthread_mutex_unlock(&session->lock);
	if (echo)
		log_line(session, "Сервер принял картинку из буфера Мака (приложения на сервере видят её как PNG и BMP).");

	if (wanted == 0)
		return CHANNEL_RC_OK;
	CLIPRDR_FORMAT_DATA_REQUEST request = {};
	request.common.msgType = CB_FORMAT_DATA_REQUEST;
	request.requestedFormatId = wanted;
	return cliprdr->ClientFormatDataRequest(cliprdr, &request);
}

static UINT clip_format_list_response(CliprdrClientContext* cliprdr,
                                      const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
	(void)cliprdr;
	(void)response;
	return CHANNEL_RC_OK;
}

static UINT clip_format_data_request(CliprdrClientContext* cliprdr,
                                     const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	RDPSession* session = (RDPSession*)cliprdr->custom;
	UINT32 size = 0;
	BYTE* data = nullptr;
	pthread_mutex_lock(&session->lock);
	if (request->requestedFormatId == CF_DIB)
	{
		if (session->pendingDib && session->pendingDibLength > 0)
		{
			data = (BYTE*)malloc(session->pendingDibLength);
			if (data)
			{
				memcpy(data, session->pendingDib, session->pendingDibLength);
				size = session->pendingDibLength;
			}
		}
	}
	else if (session->pendingClipboard && session->clipboard)
		data = (BYTE*)ClipboardGetData(session->clipboard, request->requestedFormatId, &size);
	pthread_mutex_unlock(&session->lock);

	CLIPRDR_FORMAT_DATA_RESPONSE response = {};
	response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
	response.common.dataLen = data ? size : 0;
	response.requestedFormatData = data;
	UINT result = cliprdr->ClientFormatDataResponse(cliprdr, &response);
	free(data);
	return result;
}

static UINT clip_format_data_response(CliprdrClientContext* cliprdr,
                                      const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	RDPSession* session = (RDPSession*)cliprdr->custom;
	if (!session || (response->common.msgFlags & CB_RESPONSE_FAIL))
		return CHANNEL_RC_OK;

	pthread_mutex_lock(&session->lock);
	UINT32 formatId = session->requestedFormatId;
	if (formatId == CF_DIB || formatId == CF_DIBV5)
	{
		pthread_mutex_unlock(&session->lock);
		UINT32 length = response->common.dataLen;
		if (!response->requestedFormatData || length < 40)
			return CHANNEL_RC_OK;
		if (length > DALNY_CLIP_MAX_DIB)
		{
			log_line(session, "Картинка в буфере сервера больше 64 МБ, не копирую.");
			return CHANNEL_RC_OK;
		}
		if (session->handlers.clipboard_image)
			session->handlers.clipboard_image(session->handlers.ctx, response->requestedFormatData,
			                                  length, formatId == CF_DIBV5);
		return CHANNEL_RC_OK;
	}
	if (formatId == 0)
	{
		pthread_mutex_unlock(&session->lock);
		return CHANNEL_RC_OK;
	}
	ClipboardSetData(session->clipboard, formatId, response->requestedFormatData,
	                 response->common.dataLen);
	UINT32 utf8Id = ClipboardRegisterFormat(session->clipboard, "text/plain;charset=utf-8");
	UINT32 utf8Size = 0;
	char* utf8 = (char*)ClipboardGetData(session->clipboard, utf8Id, &utf8Size);
	pthread_mutex_unlock(&session->lock);

	if (utf8 && session->handlers.clipboard_text)
	{
		if (utf8Size > 0 && utf8[utf8Size - 1] == '\0')
			utf8Size--;
		utf8[utf8Size] = '\0';
		session->handlers.clipboard_text(session->handlers.ctx, utf8);
	}
	free(utf8);
	return CHANNEL_RC_OK;
}

static UINT clip_capabilities(CliprdrClientContext* cliprdr, const CLIPRDR_CAPABILITIES* caps)
{
	(void)cliprdr;
	(void)caps;
	return CHANNEL_RC_OK;
}

static UINT clip_lock(CliprdrClientContext* cliprdr, const CLIPRDR_LOCK_CLIPBOARD_DATA* data)
{
	(void)cliprdr;
	(void)data;
	return CHANNEL_RC_OK;
}

static UINT clip_unlock(CliprdrClientContext* cliprdr, const CLIPRDR_UNLOCK_CLIPBOARD_DATA* data)
{
	(void)cliprdr;
	(void)data;
	return CHANNEL_RC_OK;
}

static UINT clip_file_request(CliprdrClientContext* cliprdr,
                              const CLIPRDR_FILE_CONTENTS_REQUEST* request)
{
	(void)cliprdr;
	(void)request;
	return CHANNEL_RC_OK;
}

static UINT clip_file_response(CliprdrClientContext* cliprdr,
                               const CLIPRDR_FILE_CONTENTS_RESPONSE* response)
{
	(void)cliprdr;
	(void)response;
	return CHANNEL_RC_OK;
}

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* event)
{
	DalnyContext* dalny = (DalnyContext*)context;
	RDPSession* session = dalny ? dalny->session : nullptr;
	if (!session || !event || !event->name)
		return;

	if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		CliprdrClientContext* clip = (CliprdrClientContext*)event->pInterface;
		clip->custom = session;
		session->cliprdr = clip;
		if (!session->clipboard)
			session->clipboard = ClipboardCreate();
		clip->MonitorReady = clip_monitor_ready;
		clip->ServerCapabilities = clip_capabilities;
		clip->ServerFormatList = clip_server_format_list;
		clip->ServerFormatListResponse = clip_format_list_response;
		clip->ServerLockClipboardData = clip_lock;
		clip->ServerUnlockClipboardData = clip_unlock;
		clip->ServerFormatDataRequest = clip_format_data_request;
		clip->ServerFormatDataResponse = clip_format_data_response;
		clip->ServerFileContentsRequest = clip_file_request;
		clip->ServerFileContentsResponse = clip_file_response;
		return;
	}

	if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0 || strcmp(event->name, "disp") == 0)
	{
		session->disp = (DispClientContext*)event->pInterface;
		log_line(session, "Сервер разрешил менять размер экрана.");
		return;
	}

	freerdp_client_OnChannelConnectedEventHandler(context, event);
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* event)
{
	DalnyContext* dalny = (DalnyContext*)context;
	RDPSession* session = dalny ? dalny->session : nullptr;
	if (session && event && event->name)
	{
		if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
			session->cliprdr = nullptr;
		if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0 || strcmp(event->name, "disp") == 0)
			session->disp = nullptr;
	}
	freerdp_client_OnChannelDisconnectedEventHandler(context, event);
}

static void apply_graphics(rdpSettings* settings, const RDPParams* params)
{
	int profile = params->profile;
	if (profile < 0 || profile > 3)
		profile = 0;
	/* 3: extreme economy. 8 bpp (256 colors) is the smallest depth RDP offers to xrdp. */
	int extreme = profile == 3;
	int depth = params->colorDepth == 8 ? 8 : (params->colorDepth == 16 ? 16 : 32);
	UINT32 width = (UINT32)(params->width < 200 ? 200 : params->width);
	UINT32 height = (UINT32)(params->height < 200 ? 200 : params->height);
	width &= ~1u;
	height &= ~1u;

	freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width);
	freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height);
	freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, (UINT32)depth);

	freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, extreme ? FALSE : TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_NSCodec, extreme ? FALSE : TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_NSCodecAllowSubsampling, profile == 0 || extreme);
	freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_GfxH264, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_JpegCodec, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_UnicodeInput, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, FALSE);
	freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType,
	                            extreme ? CONNECTION_TYPE_MODEM : CONNECTION_TYPE_LAN);
	freerdp_settings_set_bool(settings, FreeRDP_CompressionEnabled, TRUE);
	freerdp_settings_set_uint32(settings, FreeRDP_CompressionLevel, PACKET_COMPR_TYPE_RDP61);
	freerdp_settings_set_bool(settings, FreeRDP_BitmapCacheEnabled, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_BitmapCompressionDisabled, FALSE);

	freerdp_settings_set_bool(settings, FreeRDP_DisableWallpaper, profile != 2);
	freerdp_settings_set_bool(settings, FreeRDP_DisableFullWindowDrag, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_DisableMenuAnims, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_DisableThemes, profile == 0 || extreme);
	freerdp_settings_set_bool(settings, FreeRDP_AllowFontSmoothing, profile == 2);
	freerdp_settings_set_bool(settings, FreeRDP_DisableCursorShadow, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_DisableCursorBlinking, extreme ? TRUE : FALSE);
	/* RDP has no frame-rate cap outside GFX (which xrdp 0.9 does not offer); extreme economy
	 * relies on 8 bpp, the bitmap cache and compression instead. */
	freerdp_settings_set_bool(settings, FreeRDP_AllowDesktopComposition, FALSE);

	freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, 0x00000409);
	freerdp_settings_set_uint32(settings, FreeRDP_KeyboardType, 4);
	freerdp_settings_set_uint32(settings, FreeRDP_KeyboardSubType, 0);
	freerdp_settings_set_uint32(settings, FreeRDP_KeyboardFunctionKey, 12);

	freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_TcpKeepAlive, TRUE);
	freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveDelay, 10);
	freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveInterval, 5);
	freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveRetries, 3);
	/* Heartbeat, multitransport and auto-detect make FreeRDP force rdpdr plus an
	 * "rdpsnd sys:fake" static channel. rdpsnd is not built (CHANNEL_RDPSND=OFF), so channel
	 * loading failed and every connect ended in PRE_CONNECT_FAILED. TCP keepalive and SSH
	 * ServerAlive detect dead links instead. */
	freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE);
	freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, 15000);
	freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_FastPathInput, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, params->clipboard ? TRUE : FALSE);
	freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE);
	freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH);
	freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH);
}

static BOOL pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	rdpSettings* settings = context->settings;
	RDPSession* session = session_from(context);
	context->update->BeginPaint = begin_paint;
	context->update->EndPaint = end_paint;
	context->update->DesktopResize = desktop_resize;
	if (session)
		apply_graphics(settings, &session->params);
	freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH);
	freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH);
	PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected);
	PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
	return TRUE;
}

/* Called by FreeRDP inside freerdp_prepare_connect(). FALSE here becomes
 * PRE_CONNECT_FAILED ("A configuration error ..."), so say which step failed. */
static BOOL load_channels(freerdp* instance)
{
	RDPSession* session = session_from(instance->context);
	if (freerdp_client_load_channels(instance))
	{
		log_line(session, "FreeRDP: каналы загружены.");
		return TRUE;
	}
	log_line(session, "FreeRDP: не удалось загрузить каналы (подробности выше).");
	return FALSE;
}

static BOOL post_connect(freerdp* instance)
{
	if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
		return FALSE;
	RDPSession* session = session_from(instance->context);
	if (session && instance->context->gdi)
	{
		session->remoteWidth = instance->context->gdi->width;
		session->remoteHeight = instance->context->gdi->height;
		char line[160];
		snprintf(line, sizeof(line), "Сеанс открыт, %dx%d, %d бит.", session->remoteWidth,
		         session->remoteHeight,
		         (int)freerdp_settings_get_uint32(instance->context->settings, FreeRDP_ColorDepth));
		log_line(session, line);
	}
	return TRUE;
}

static void post_disconnect(freerdp* instance)
{
	if (!instance || !instance->context)
		return;
	PubSub_UnsubscribeChannelConnected(instance->context->pubSub, on_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected);
	gdi_free(instance);
}

static BOOL client_new(freerdp* instance, rdpContext* context)
{
	(void)context;
	instance->PreConnect = pre_connect;
	instance->PostConnect = post_connect;
	instance->PostDisconnect = post_disconnect;
	instance->LoadChannels = load_channels;
	instance->AuthenticateEx = authenticate_ex;
	instance->VerifyCertificateEx = verify_cert_ex;
	instance->VerifyChangedCertificateEx = verify_changed_cert_ex;
	instance->LogonErrorInfo = logon_error_info;
	return TRUE;
}

static void client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}

static int client_entry(RDP_CLIENT_ENTRY_POINTS* entry)
{
	entry->Version = RDP_CLIENT_INTERFACE_VERSION;
	entry->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry->ContextSize = sizeof(DalnyContext);
	entry->ClientNew = client_new;
	entry->ClientFree = client_free;
	return 0;
}

static PVIRTUALCHANNELENTRY load_plugin(const char* name, DWORD flags)
{
	if (!name || !g_pluginDir[0])
		return nullptr;
	const char* suffix = "VirtualChannelEntryEx";
	if (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC)
		suffix = "DVCPluginEntry";
	else if ((flags & FREERDP_ADDIN_CHANNEL_STATIC) && !(flags & FREERDP_ADDIN_CHANNEL_ENTRYEX))
		suffix = "VirtualChannelEntry";

	char path[1200];
	snprintf(path, sizeof(path), "%s/lib%s-client.dylib", g_pluginDir, name);
	void* library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!library)
	{
		snprintf(path, sizeof(path), "%s/lib%s-client.3.dylib", g_pluginDir, name);
		library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	}
	if (!library)
		return nullptr;
	void* symbol = dlsym(library, suffix);
	if (!symbol)
		symbol = dlsym(library, "VirtualChannelEntryEx");
	if (!symbol)
		symbol = dlsym(library, "DVCPluginEntry");
	if (!symbol)
	{
		dlclose(library);
		return nullptr;
	}
	return (PVIRTUALCHANNELENTRY)symbol;
}

static PVIRTUALCHANNELENTRY addin_provider(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags)
{
	(void)subsystem;
	(void)type;
	PVIRTUALCHANNELENTRY entry = nullptr;
	if (g_previousProvider)
		entry = g_previousProvider(name, subsystem, type, flags);
	if (!entry)
		entry = load_plugin(name, flags);
	return entry;
}

static void process_input_queue(freerdp* instance)
{
	wMessageQueue* queue = freerdp_get_message_queue(instance, FREERDP_INPUT_MESSAGE_QUEUE);
	wMessage message;
	if (!queue)
		return;
	while (MessageQueue_Peek(queue, &message, TRUE))
	{
		if (!freerdp_message_queue_process_message(instance, FREERDP_INPUT_MESSAGE_QUEUE, &message))
			break;
	}
}

static void send_resize(RDPSession* session)
{
	int width = 0;
	int height = 0;
	pthread_mutex_lock(&session->lock);
	width = session->resizeWidth;
	height = session->resizeHeight;
	session->resizeWidth = 0;
	session->resizeHeight = 0;
	pthread_mutex_unlock(&session->lock);
	if (width < 200 || height < 200)
		return;
	width &= ~1;
	height &= ~1;
	if (!session->disp || !session->disp->SendMonitorLayout)
	{
		if (!session->resizeNoteLogged)
		{
			session->resizeNoteLogged = 1;
			log_line(session, "Сервер не меняет размер. Картинка подгоняется в окне.");
		}
		return;
	}

	DISPLAY_CONTROL_MONITOR_LAYOUT layout;
	memset(&layout, 0, sizeof(layout));
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	layout.Width = (UINT32)width;
	layout.Height = (UINT32)height;
	layout.DesktopScaleFactor = 100;
	layout.DeviceScaleFactor = 100;
	UINT result = session->disp->SendMonitorLayout(session->disp, 1, &layout);
	char line[128];
	snprintf(line, sizeof(line), "Запрошен размер %dx%d (%s).", width, height,
	         result == CHANNEL_RC_OK ? "принято" : "ошибка");
	log_line(session, line);
}

static int error_is_auth(UINT32 code)
{
	const char* name = freerdp_get_last_error_name(code);
	const char* category = freerdp_get_last_error_category(code);
	if (name && (strstr(name, "AUTH") || strstr(name, "LOGON") || strstr(name, "NLA")))
		return 1;
	if (category && strstr(category, "AUTH"))
		return 1;
	return 0;
}

/* Runs on the session thread between event waits. */
static void probe_link(RDPSession* session)
{
	rdpContext* context = session->context;
	if (!context || !context->update || !context->update->RefreshRect)
		return;
	uint64_t now = now_ms();
	uint64_t sent = session->probeSentMs;
	if (sent)
	{
		uint64_t waited = now - sent;
		if (waited >= 3000 && now - session->lastLinkReportMs >= 1000)
		{
			session->lastLinkReportMs = now;
			if (session->handlers.link)
				session->handlers.link(session->handlers.ctx, -1, (int)waited, session->probesAnswered > 0);
		}
		return;
	}
	if (now - session->lastActivityMs < 2000 || now - session->lastProbeMs < 2000)
		return;
	if (!freerdp_settings_get_bool(context->settings, FreeRDP_RefreshRect))
		return;
	UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
	UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
	if (width < 16 || height < 16)
		return;
	RECTANGLE_16 area;
	area.left = 0;
	area.top = 0;
	area.right = 15;
	area.bottom = 15;
	session->lastProbeMs = now;
	if (context->update->RefreshRect(context, 1, &area))
		session->probeSentMs = now;
}

static void* session_thread(void* argument)
{
	RDPSession* session = (RDPSession*)argument;
	BOOL connected = freerdp_connect(session->instance);
	if (!connected)
	{
		UINT32 code = freerdp_get_last_error(session->context);
		const char* text = freerdp_get_last_error_string(code);
		log_last_error(session, "freerdp_connect", code);
		int fatal = session->certRejected || session->authFailed || error_is_auth(code);
		if (error_is_config(code))
		{
			log_line(session, "Ошибка настройки клиента. Повтор не поможет, переподключение остановлено.");
			fatal = 1;
		}
		if (!session->certRejected && (session->authFailed || error_is_credentials(code)))
			fatal = RDP_FATAL_CREDENTIALS;
		/* Stopped by the app (network change, tunnel restart): never a reason to give up. */
		if (session->stop)
			fatal = 0;
		if (session->handlers.disconnected)
			session->handlers.disconnected(session->handlers.ctx, fatal, text ? text : "Нет соединения");
		return nullptr;
	}

	session->lastActivityMs = now_ms();
	session->probeSentMs = 0;
	session->lastProbeMs = 0;
	session->probesAnswered = 0;
	HANDLE handles[32];
	while (!session->stop && !freerdp_shall_disconnect_context(session->context))
	{
		probe_link(session);
		DWORD count = 0;
		handles[count++] = session->stopEvent;
		HANDLE inputEvent =
		    freerdp_get_message_queue_event_handle(session->instance, FREERDP_INPUT_MESSAGE_QUEUE);
		if (inputEvent)
			handles[count++] = inputEvent;
		handles[count++] = session->resizeEvent;
		DWORD extra = freerdp_get_event_handles(session->context, &handles[count], 32 - count);
		if (extra == 0)
			break;
		count += extra;

		DWORD waitResult = WaitForMultipleObjects(count, handles, FALSE, 1000);
		if (session->stop || WaitForSingleObject(session->stopEvent, 0) == WAIT_OBJECT_0)
			break;
		if (waitResult == WAIT_FAILED)
			break;
		if (inputEvent && WaitForSingleObject(inputEvent, 0) == WAIT_OBJECT_0)
			process_input_queue(session->instance);
		if (WaitForSingleObject(session->resizeEvent, 0) == WAIT_OBJECT_0)
			send_resize(session);
		if (waitResult == WAIT_TIMEOUT)
			continue;
		if (!freerdp_check_event_handles(session->context))
			break;
	}

	freerdp_disconnect(session->instance);
	const char* reason = session->stop ? "Отключено" : "Соединение закрыто";
	UINT32 code = freerdp_get_last_error(session->context);
	const char* text = freerdp_get_last_error_string(code);
	if (!session->stop && text && text[0] && strcmp(text, "Success") != 0 &&
	    strcmp(text, "ERRINFO_SUCCESS") != 0)
		reason = text;
	if (code != FREERDP_ERROR_SUCCESS && code != FREERDP_ERROR_NONE)
		log_last_error(session, "disconnect", code);
	int fatal = session->certRejected || session->authFailed || error_is_config(code);
	if (!session->certRejected && (session->authFailed || error_is_credentials(code)))
		fatal = RDP_FATAL_CREDENTIALS;
	if (session->stop)
		fatal = 0;
	if (session->handlers.disconnected)
		session->handlers.disconnected(session->handlers.ctx, fatal, reason);
	return nullptr;
}

static void apply_connection_settings(RDPSession* session)
{
	rdpSettings* settings = session->context->settings;
	apply_graphics(settings, &session->params);
	freerdp_settings_set_string(settings, FreeRDP_ServerHostname, session->params.host);
	freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, (UINT32)session->params.port);
	freerdp_settings_set_string(settings, FreeRDP_Username, session->params.username);
	freerdp_settings_set_string(settings, FreeRDP_Password, session->params.password);
	freerdp_settings_set_string(settings, FreeRDP_Domain, "");
}

RDPSession* rdp_session_create(const RDPParams* params, const RDPHandlers* handlers)
{
	if (!params || !handlers)
		return nullptr;
	RDPSession* session = (RDPSession*)calloc(1, sizeof(RDPSession));
	if (!session)
		return nullptr;
	session->params = *params;
	session->handlers = *handlers;
	pthread_mutex_init(&session->lock, nullptr);
	session->stopEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
	session->resizeEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
	pthread_once(&g_wlogOnce, wlog_install);
	set_log_session(session, nullptr);

	RDP_CLIENT_ENTRY_POINTS entry;
	memset(&entry, 0, sizeof(entry));
	client_entry(&entry);
	session->context = freerdp_client_context_new(&entry);
	if (!session->context)
	{
		rdp_session_destroy(session);
		return nullptr;
	}
	session->instance = session->context->instance;
	((DalnyContext*)session->context)->session = session;
	snprintf(g_pluginDir, sizeof(g_pluginDir), "%s", params->pluginsDir);
	g_previousProvider = freerdp_get_current_addin_provider();
	freerdp_register_addin_provider(addin_provider, 0);
	apply_connection_settings(session);
	return session;
}

void rdp_session_start(RDPSession* session)
{
	if (!session || session->threadStarted)
		return;
	session->stop = 0;
	ResetEvent(session->stopEvent);
	if (pthread_create(&session->thread, nullptr, session_thread, session) == 0)
		session->threadStarted = 1;
}

void rdp_session_stop(RDPSession* session)
{
	if (!session)
		return;
	session->stop = 1;
	if (session->stopEvent)
		SetEvent(session->stopEvent);
	if (session->context)
		freerdp_abort_connect_context(session->context);
}

void rdp_session_destroy(RDPSession* session)
{
	if (!session)
		return;
	rdp_session_stop(session);
	if (session->threadStarted)
	{
		pthread_join(session->thread, nullptr);
		session->threadStarted = 0;
	}
	if (session->context)
	{
		freerdp_client_context_free(session->context);
		session->context = nullptr;
		session->instance = nullptr;
	}
	set_log_session(nullptr, session);
	if (session->clipboard)
		ClipboardDestroy(session->clipboard);
	free_server_formats(session);
	free(session->pendingClipboard);
	free(session->pendingDib);
	if (session->stopEvent)
		CloseHandle(session->stopEvent);
	if (session->resizeEvent)
		CloseHandle(session->resizeEvent);
	wipe_bytes(session->params.password, sizeof(session->params.password));
	pthread_mutex_destroy(&session->lock);
	free(session);
}

void rdp_session_send_scancode(RDPSession* session, uint32_t rdpScancode, int down, int repeat)
{
	if (!session || !session->instance || !session->instance->context || session->stop)
		return;
	rdpInput* input = session->instance->context->input;
	if (!input)
		return;
	freerdp_input_send_keyboard_event_ex(input, down ? TRUE : FALSE, repeat ? TRUE : FALSE,
	                                     rdpScancode);
}

void rdp_session_send_mouse(RDPSession* session, int x, int y, int button, int down)
{
	if (!session || !session->instance || !session->instance->context || session->stop)
		return;
	rdpInput* input = session->instance->context->input;
	if (!input)
		return;
	if (x < 0)
		x = 0;
	if (y < 0)
		y = 0;
	UINT16 flags = PTR_FLAGS_MOVE;
	if (button == 1)
		flags = (UINT16)(PTR_FLAGS_BUTTON1 | (down ? PTR_FLAGS_DOWN : 0));
	else if (button == 2)
		flags = (UINT16)(PTR_FLAGS_BUTTON2 | (down ? PTR_FLAGS_DOWN : 0));
	else if (button == 3)
		flags = (UINT16)(PTR_FLAGS_BUTTON3 | (down ? PTR_FLAGS_DOWN : 0));
	freerdp_input_send_mouse_event(input, flags, (UINT16)x, (UINT16)y);
}

void rdp_session_send_wheel(RDPSession* session, int wheelNotches)
{
	if (!session || !session->instance || !session->instance->context || session->stop ||
	    wheelNotches == 0)
		return;
	rdpInput* input = session->instance->context->input;
	if (!input)
		return;
	UINT16 flags = PTR_FLAGS_WHEEL;
	int steps = wheelNotches;
	if (steps < 0)
	{
		flags |= PTR_FLAGS_WHEEL_NEGATIVE;
		steps = -steps;
	}
	steps *= 120;
	if (steps > 0xFF)
		steps = 0xFF;
	if (flags & PTR_FLAGS_WHEEL_NEGATIVE)
		steps = 0x100 - steps;
	freerdp_input_send_mouse_event(input, (UINT16)(flags | (steps & 0xFF)), 0, 0);
}

void rdp_session_request_resize(RDPSession* session, int width, int height)
{
	if (!session)
		return;
	pthread_mutex_lock(&session->lock);
	session->resizeWidth = width;
	session->resizeHeight = height;
	pthread_mutex_unlock(&session->lock);
	if (session->resizeEvent)
		SetEvent(session->resizeEvent);
}

void rdp_session_set_clipboard(RDPSession* session, const char* utf8, const uint8_t* dib,
                               size_t dibLength)
{
	if (!session || !session->params.clipboard)
		return;
	if (!utf8 && (!dib || dibLength == 0))
		return;
	if (dibLength > DALNY_CLIP_MAX_DIB)
	{
		log_line(session, "Картинка больше 64 МБ, на сервер не отправляю.");
		dib = nullptr;
		dibLength = 0;
		if (!utf8)
			return;
	}
	pthread_mutex_lock(&session->lock);
	free(session->pendingClipboard);
	session->pendingClipboard = utf8 ? _strdup(utf8) : nullptr;
	free(session->pendingDib);
	session->pendingDib = nullptr;
	session->pendingDibLength = 0;
	session->sentDibMs = (dib && dibLength > 0 && !utf8) ? now_ms() : 0;
	if (dib && dibLength > 0)
	{
		session->pendingDib = (BYTE*)malloc(dibLength);
		if (session->pendingDib)
		{
			memcpy(session->pendingDib, dib, dibLength);
			session->pendingDibLength = (UINT32)dibLength;
		}
	}
	if (session->clipboard)
	{
		clip_load_text(session);
		if (session->cliprdr)
			clip_send_format_list(session);
	}
	pthread_mutex_unlock(&session->lock);
}

void rdp_session_set_clipboard_utf8(RDPSession* session, const char* utf8)
{
	if (utf8)
		rdp_session_set_clipboard(session, utf8, nullptr, 0);
}

void rdp_session_send_language_toggle(RDPSession* session)
{
	rdp_session_send_scancode(session, RDP_SCANCODE_LMENU, 1, 0);
	rdp_session_send_scancode(session, RDP_SCANCODE_LSHIFT, 1, 0);
	rdp_session_send_scancode(session, RDP_SCANCODE_LSHIFT, 0, 0);
	rdp_session_send_scancode(session, RDP_SCANCODE_LMENU, 0, 0);
}

void rdp_session_remote_size(RDPSession* session, int* width, int* height)
{
	if (!session)
		return;
	if (width)
		*width = session->remoteWidth;
	if (height)
		*height = session->remoteHeight;
}
