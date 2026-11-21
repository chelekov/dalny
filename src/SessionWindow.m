#import "SessionWindow.h"
#import "ClipboardImage.h"
#import "DalnyLog.h"
#import "LanguageSetup.h"
#import "Keychain.h"
#import "RDPView.h"
#import "SSHClient.h"
#import "ServerStore.h"
#import <Carbon/Carbon.h>
#import <Network/Network.h>
#import <string.h>

/* Reconnect backoff in seconds, then 30 s steps until about 5 minutes have passed. */
static const double kReconnectBackoff[] = {1, 2, 4, 8, 15, 30};
static const double kReconnectGiveUpSeconds = 300;
static const int kStallDropMs = 20000;

@implementation SessionWindow
{
	DalnyServer* _server;
	RDPView* _view;
	NSTextField* _status;
	NSTextField* _hint;
	NSScrollView* _logScroll;
	NSTextView* _logView;
	NSButton* _logButton;
	SSHClient* _tunnel;
	RDPSession* _rdp;
	dispatch_queue_t _queue;
	dispatch_queue_t _pathQueue;
	dispatch_semaphore_t _wake;
	nw_path_monitor_t _monitor;
	BOOL _havePath;
	BOOL _networkUp;
	BOOL _cancelled;
	BOOL _immediate;
	NSString* _pathSignature;
	NSInteger _generation;
	NSInteger _pasteboardBaseline;
	NSTimer* _pasteboardTimer;
	int _remoteWidth;
	int _remoteHeight;
	volatile int _rdpFinished;
	BOOL _giveUp;
	BOOL _credentialsRejected;
	BOOL _started;
	NSString* _lastReason;
	BOOL _sawFrame;
	BOOL _languageOfferShown;
	NSLayoutConstraint* _viewToBottom;
	NSLayoutConstraint* _viewToLog;
	NSTimer* _resizeTimer;
	NSSize _fittedRemote;

	/* Lost-link overlay over the picture and the yellow poor-connection notice. */
	NSView* _overlay;
	NSTextField* _overlayTitle;
	NSTextField* _overlayDetail;
	NSButton* _overlayRetry;
	NSView* _poorBar;
	NSTextField* _poorText;
	NSButton* _poorSwitch;
	BOOL _poorDismissed;
	CFAbsoluteTime _goodSince;

	BOOL _loopRunning;
	NSDate* _dropStarted;
	int _lastRemoteWidth;
	int _lastRemoteHeight;
	volatile BOOL _stallDrop;
	volatile BOOL _probeProven;
	double _rttAverage;
	volatile CFAbsoluteTime _lastAnswer;
	volatile CFAbsoluteTime _pathCheckDeadline;
	CFAbsoluteTime _pathCheckBaseline;
}

static void log_thunk(void* ctx, const char* line);
static void frame_thunk(void* ctx, const uint8_t* bgra, int width, int height, int stride, int x, int y, int w,
                        int h);
static void resize_thunk(void* ctx, int width, int height);
static void clipboard_thunk(void* ctx, const char* utf8);
static void clipboard_image_thunk(void* ctx, const uint8_t* dib, size_t length, int isV5);
static int cert_thunk(void* ctx, const char* fingerprint, int changed);
static void disconnect_thunk(void* ctx, int fatal, const char* reason);
static void link_thunk(void* ctx, int rttMs, int stalledMs, int proven);

- (instancetype)initWithServer:(DalnyServer*)server
{
	NSRect frame = NSMakeRect(0, 0, 1100, 720);
	NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
	                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	                                                 backing:NSBackingStoreBuffered
	                                                   defer:NO];
	window.title = server.displayTitle;
	window.minSize = NSMakeSize(640, 420);
	/* Any area the picture does not cover is black, never the default light background. */
	window.backgroundColor = NSColor.blackColor;
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
	self = [super initWithWindow:window];
	if (self)
	{
		_server = server;
		_networkUp = YES;
		_queue = dispatch_queue_create("app.dalny.client.session", DISPATCH_QUEUE_SERIAL);
		_pathQueue = dispatch_queue_create("app.dalny.client.path", DISPATCH_QUEUE_SERIAL);
		_wake = dispatch_semaphore_create(0);
		_tunnel = [SSHClient new];
		[self build];
		[self startPathMonitor];
	}
	return self;
}

- (void)build
{
	_status = [NSTextField wrappingLabelWithString:@"Подключение…"];
	_status.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
	_status.translatesAutoresizingMaskIntoConstraints = NO;
	_hint = [NSTextField wrappingLabelWithString:@"Раскладка Mac: ABC. На сервере язык переключается ⌥ Option + ⇧ Shift или кнопкой RU/EN."];
	_hint.font = [NSFont systemFontOfSize:12];
	_hint.textColor = NSColor.secondaryLabelColor;
	_hint.translatesAutoresizingMaskIntoConstraints = NO;

	NSButton* disconnect = [NSButton buttonWithTitle:@"Отключиться" target:self action:@selector(disconnect:)];
	_logButton = [NSButton buttonWithTitle:@"Журнал" target:self action:@selector(toggleLog:)];
	NSButton* copyLog = [NSButton buttonWithTitle:@"Скопировать журнал" target:self action:@selector(copyLog:)];
	NSStackView* tools = [NSStackView stackViewWithViews:@[ disconnect, _logButton, copyLog ]];
	tools.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	tools.spacing = 8;
	tools.translatesAutoresizingMaskIntoConstraints = NO;

	_view = [RDPView new];
	_view.translatesAutoresizingMaskIntoConstraints = NO;
	_view.mapCommandToControl = _server.mapCommandToControl;
	_view.fitDisplay = ![_server.displayMode isEqualToString:@"fixed"];

	_logScroll = [NSTextView scrollableTextView];
	_logView = (NSTextView*)_logScroll.documentView;
	_logView.editable = NO;
	_logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	_logScroll.translatesAutoresizingMaskIntoConstraints = NO;
	_logScroll.hidden = YES;

	[self buildLanguageAccessory];

	NSView* content = self.window.contentView;
	[content addSubview:_status];
	[content addSubview:_hint];
	[content addSubview:tools];
	[content addSubview:_view];
	[content addSubview:_logScroll];
	[NSLayoutConstraint activateConstraints:@[
		[_status.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
		[_status.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
		[_status.topAnchor constraintEqualToAnchor:content.topAnchor constant:10],
		[_hint.leadingAnchor constraintEqualToAnchor:_status.leadingAnchor],
		[_hint.trailingAnchor constraintEqualToAnchor:_status.trailingAnchor],
		[_hint.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:2],
		[tools.leadingAnchor constraintEqualToAnchor:_status.leadingAnchor],
		[tools.topAnchor constraintEqualToAnchor:_hint.bottomAnchor constant:8],
		[_view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[_view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[_view.topAnchor constraintEqualToAnchor:tools.bottomAnchor constant:8],
		[_logScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
		[_logScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
		[_logScroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
		[_logScroll.heightAnchor constraintEqualToConstant:140]
	]];
	/* The hidden log must not keep its space: the picture goes down to the window edge. */
	_viewToBottom = [_view.bottomAnchor constraintEqualToAnchor:content.bottomAnchor];
	_viewToLog = [_view.bottomAnchor constraintEqualToAnchor:_logScroll.topAnchor constant:-8];
	_viewToBottom.active = YES;
	[self buildOverlays];
}

- (void)buildOverlays
{
	NSView* content = self.window.contentView;

	_overlay = [NSView new];
	_overlay.wantsLayer = YES;
	_overlay.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.8].CGColor;
	_overlay.translatesAutoresizingMaskIntoConstraints = NO;
	_overlay.hidden = YES;
	_overlayTitle = [NSTextField wrappingLabelWithString:@""];
	_overlayTitle.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
	_overlayTitle.textColor = NSColor.whiteColor;
	_overlayTitle.alignment = NSTextAlignmentCenter;
	_overlayDetail = [NSTextField wrappingLabelWithString:@""];
	_overlayDetail.font = [NSFont systemFontOfSize:13];
	_overlayDetail.textColor = [NSColor colorWithWhite:0.85 alpha:1];
	_overlayDetail.alignment = NSTextAlignmentCenter;
	_overlayRetry = [NSButton buttonWithTitle:@"Переподключиться сейчас" target:self action:@selector(reconnectNow:)];
	_overlayRetry.controlSize = NSControlSizeLarge;
	NSButton* stop = [NSButton buttonWithTitle:@"Отключиться" target:self action:@selector(disconnect:)];
	stop.controlSize = NSControlSizeLarge;
	NSStackView* buttons = [NSStackView stackViewWithViews:@[ _overlayRetry, stop ]];
	buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	buttons.spacing = 12;
	NSStackView* stack = [NSStackView stackViewWithViews:@[ _overlayTitle, _overlayDetail, buttons ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeCenterX;
	stack.spacing = 14;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[_overlay addSubview:stack];
	[content addSubview:_overlay positioned:NSWindowAbove relativeTo:_view];

	_poorBar = [NSView new];
	_poorBar.wantsLayer = YES;
	_poorBar.layer.backgroundColor = [NSColor colorWithRed:1.0 green:0.84 blue:0.2 alpha:0.95].CGColor;
	_poorBar.translatesAutoresizingMaskIntoConstraints = NO;
	_poorBar.hidden = YES;
	_poorText = [NSTextField labelWithString:@"Плохое соединение"];
	_poorText.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
	_poorText.textColor = NSColor.blackColor;
	_poorText.lineBreakMode = NSLineBreakByTruncatingTail;
	[_poorText setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
	                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
	_poorSwitch = [NSButton buttonWithTitle:@"Переключиться на экстремальную экономию"
	                                 target:self
	                                 action:@selector(toggleExtremeEconomy:)];
	_poorSwitch.controlSize = NSControlSizeSmall;
	_poorSwitch.refusesFirstResponder = YES;
	NSButton* hide = [NSButton buttonWithTitle:@"Скрыть" target:self action:@selector(hidePoorNotice:)];
	hide.controlSize = NSControlSizeSmall;
	hide.refusesFirstResponder = YES;
	NSStackView* bar = [NSStackView stackViewWithViews:@[ _poorText, _poorSwitch, hide ]];
	bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	bar.spacing = 10;
	bar.translatesAutoresizingMaskIntoConstraints = NO;
	[_poorBar addSubview:bar];
	[content addSubview:_poorBar positioned:NSWindowAbove relativeTo:_view];

	[NSLayoutConstraint activateConstraints:@[
		[_overlay.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
		[_overlay.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
		[_overlay.topAnchor constraintEqualToAnchor:_view.topAnchor],
		[_overlay.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
		[stack.centerXAnchor constraintEqualToAnchor:_overlay.centerXAnchor],
		[stack.centerYAnchor constraintEqualToAnchor:_overlay.centerYAnchor],
		[stack.widthAnchor constraintLessThanOrEqualToAnchor:_overlay.widthAnchor constant:-40],
		[_overlayTitle.widthAnchor constraintLessThanOrEqualToConstant:560],
		[_overlayDetail.widthAnchor constraintLessThanOrEqualToConstant:560],
		[_poorBar.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
		[_poorBar.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
		[_poorBar.topAnchor constraintEqualToAnchor:_view.topAnchor],
		[bar.leadingAnchor constraintEqualToAnchor:_poorBar.leadingAnchor constant:10],
		[bar.trailingAnchor constraintLessThanOrEqualToAnchor:_poorBar.trailingAnchor constant:-10],
		[bar.topAnchor constraintEqualToAnchor:_poorBar.topAnchor constant:4],
		[bar.bottomAnchor constraintEqualToAnchor:_poorBar.bottomAnchor constant:-4]
	]];
}

// Any thread. final: the loop has stopped; the retry button starts it again and is bigger.
- (void)showOverlayTitle:(NSString*)title detail:(NSString*)detail retry:(NSString*)retry final:(BOOL)final
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (self->_cancelled)
			return;
		self->_overlayTitle.stringValue = title ?: @"";
		self->_overlayDetail.stringValue = detail ?: @"";
		self->_overlayDetail.hidden = detail.length == 0;
		self->_overlayRetry.title = retry ?: @"Переподключиться";
		self->_overlayRetry.font = [NSFont systemFontOfSize:final ? 18 : 13
		                                             weight:final ? NSFontWeightSemibold : NSFontWeightRegular];
		self->_overlayTitle.font = [NSFont systemFontOfSize:final ? 24 : 20 weight:NSFontWeightSemibold];
		self->_poorBar.hidden = YES;
		self->_overlay.hidden = NO;
	});
}

- (void)hideOverlay
{
	dispatch_async(dispatch_get_main_queue(), ^{
		self->_overlay.hidden = YES;
	});
}

- (void)reconnectNow:(id)sender
{
	(void)sender;
	if (_cancelled)
		return;
	[self appendLog:@"Переподключаюсь по кнопке."];
	_overlayDetail.stringValue = @"Подключаюсь…";
	if (_loopRunning)
	{
		_immediate = YES;
		dispatch_semaphore_signal(_wake);
	}
	else
		[self startLoop];
}

- (void)hidePoorNotice:(id)sender
{
	(void)sender;
	_poorDismissed = YES;
	_poorBar.hidden = YES;
}

// Session thread. Smoothed probe round trip; silence after proven probes means a stall.
- (void)linkRtt:(int)rttMs stalled:(int)stalledMs proven:(int)proven
{
	if (proven)
		_probeProven = YES;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (rttMs >= 0)
	{
		_lastAnswer = now;
		_rttAverage = _rttAverage > 0 ? _rttAverage * 0.7 + rttMs * 0.3 : rttMs;
		if (_rttAverage > 800)
			[self showPoorNotice:[NSString stringWithFormat:@"Плохое соединение: ответ сервера %.1f с.", _rttAverage / 1000.0]];
		else if (_rttAverage < 500)
		{
			if (_goodSince == 0)
				_goodSince = now;
			if (now - _goodSince >= 10)
				dispatch_async(dispatch_get_main_queue(), ^{
					self->_poorBar.hidden = YES;
				});
		}
		return;
	}
	if (!_probeProven || stalledMs < 3000)
		return;
	[self showPoorNotice:[NSString stringWithFormat:@"Плохое соединение: сервер не отвечает %d с.", stalledMs / 1000]];
	if (stalledMs >= kStallDropMs)
		_stallDrop = YES;
}

- (void)showPoorNotice:(NSString*)text
{
	_goodSince = 0;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (self->_poorDismissed || !self->_overlay.hidden || self->_cancelled)
			return;
		if (self->_poorBar.hidden)
			[self appendLog:text];
		self->_poorText.stringValue = text;
		self->_poorText.toolTip = @"Связь медленная или прерывается. Экстремальная экономия (640x480, 256 цветов) передаёт намного меньше данных.";
		self->_poorSwitch.hidden = self->_server.isExtremeEconomy;
		self->_poorBar.hidden = NO;
	});
}

// Switch to or back from the extreme-economy profile and reconnect. The color depth changes,
// so xrdp opens (or returns) a different session: say so before doing it.
- (void)toggleExtremeEconomy:(id)sender
{
	(void)sender;
	if (_cancelled || self.window.attachedSheet)
		return;
	BOOL toExtreme = !_server.isExtremeEconomy;
	NSAlert* alert = [NSAlert new];
	if (toExtreme)
	{
		alert.messageText = @"Переключиться на экстремальную экономию?";
		alert.informativeText = [NSString stringWithFormat:@"%@\n\nСейчас переподключусь. Несохранённая работа в прежнем сеансе не пропадёт: он останется на сервере.",
		                                                   [DalnyServer profileHint:@"extreme"]];
	}
	else
	{
		alert.messageText = @"Вернуть прежний профиль картинки?";
		alert.informativeText = @"Переподключусь с прежними размером и глубиной цвета. Сервер вернёт сеанс, который был открыт с ними; сеанс в 256 цветах останется на сервере отдельно.";
	}
	[alert addButtonWithTitle:@"Переключить и переподключиться"];
	[alert addButtonWithTitle:@"Отмена"];
	__weak typeof(self) weakSelf = self;
	[alert beginSheetModalForWindow:self.window
	              completionHandler:^(NSModalResponse response) {
		              typeof(self) strongSelf = weakSelf;
		              if (strongSelf && response == NSAlertFirstButtonReturn)
			              [strongSelf applyExtremeEconomy:toExtreme];
	              }];
}

- (void)applyExtremeEconomy:(BOOL)toExtreme
{
	if (toExtreme)
		[_server switchToExtremeEconomy];
	else if (![_server restoreProfileBeforeExtreme])
	{
		_server.graphics = @"economy";
		[_server applyGraphicsProfile];
	}
	[[ServerStore sharedStore] save];
	[self appendLog:toExtreme ? @"Профиль: экстремальная экономия (640x480, 8 бит). Переподключаюсь."
	                          : [NSString stringWithFormat:@"Профиль: «%@», %ld бит. Переподключаюсь.", _server.graphics,
	                                                       (long)_server.colorDepth]];
	/* A new depth means a new session size: do not reuse the old remote size. */
	_lastRemoteWidth = 0;
	_lastRemoteHeight = 0;
	_poorBar.hidden = YES;
	_poorDismissed = NO;
	_view.fitDisplay = ![self isFixedMode];
	if ([self isFixedMode])
	{
		_fittedRemote = NSZeroSize;
		[_view noteRemoteSizeWidth:(int)_server.width height:(int)_server.height];
		[self fitWindowToRemote];
	}
	else
	{
		self.window.contentMaxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
		self.window.contentMinSize = NSMakeSize(640, 420);
	}
	[self showOverlayTitle:@"Меняю профиль картинки — переподключаюсь…" detail:nil retry:@"Переподключиться сейчас" final:NO];
	if (_loopRunning)
		[self abortWork];
	else
		[self startLoop];
}

- (BOOL)isFixedMode
{
	return [_server.displayMode isEqualToString:@"fixed"];
}

- (BOOL)isFullScreen
{
	return (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

// Fixed mode: the window content is the remote desktop (1 pixel = 1 point) plus the controls
// above it. When that does not fit the screen, the window gets smaller with the same aspect
// and the picture is scaled down. The window can never grow past the remote size.
- (void)fitWindowToRemote
{
	/* The status line wraps, so the controls' height depends on the width: settle in two passes. */
	for (int pass = 0; pass < 2; pass++)
		if (![self fitWindowToRemoteOnce])
			break;
}

// Returns YES when the controls' height changed after resizing and another pass is needed.
- (BOOL)fitWindowToRemoteOnce
{
	if (![self isFixedMode] || [self isFullScreen])
		return NO;
	NSSize remote = [_view remoteSize];
	if (remote.width <= 0 || remote.height <= 0)
		return NO;
	NSWindow* window = self.window;
	NSView* content = window.contentView;
	[content layoutSubtreeIfNeeded];
	CGFloat chrome = MAX(0, content.bounds.size.height - _view.frame.size.height);
	NSSize full = NSMakeSize(remote.width, remote.height + chrome);
	window.contentMaxSize = full;
	window.contentMinSize = NSMakeSize(MIN(640, full.width), MIN(420, full.height));
	window.minSize = NSZeroSize;

	NSScreen* screen = window.screen ?: NSScreen.mainScreen;
	NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, full.width, full.height);
	NSRect maxContent = [window contentRectForFrameRect:visible];
	CGFloat scale = MIN(1.0, MIN(maxContent.size.width / remote.width,
	                             (maxContent.size.height - chrome) / remote.height));
	if (scale <= 0)
		scale = 1.0;
	NSSize size = NSMakeSize(floor(remote.width * scale), floor(remote.height * scale) + chrome);
	if (scale < 1.0 && !NSEqualSizes(remote, _fittedRemote))
		[self appendLog:[NSString stringWithFormat:@"Экран сервера %dx%d больше экрана Мака, картинка уменьшена до %d%%.",
		                                           (int)remote.width, (int)remote.height, (int)(scale * 100)]];

	NSRect old = window.frame;
	NSRect frame = [window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
	frame.origin.x = old.origin.x;
	frame.origin.y = NSMaxY(old) - frame.size.height;
	if (NSMaxX(frame) > NSMaxX(visible))
		frame.origin.x = NSMaxX(visible) - frame.size.width;
	if (frame.origin.x < visible.origin.x)
		frame.origin.x = visible.origin.x;
	if (NSMaxY(frame) > NSMaxY(visible))
		frame.origin.y = NSMaxY(visible) - frame.size.height;
	if (frame.origin.y < visible.origin.y)
		frame.origin.y = visible.origin.y;
	[window setFrame:frame display:YES animate:NO];
	_fittedRemote = remote;
	[content layoutSubtreeIfNeeded];
	CGFloat after = MAX(0, content.bounds.size.height - _view.frame.size.height);
	return fabs(after - chrome) > 0.5;
}

- (void)remoteSizeChanged
{
	if (![self isFixedMode])
		return;
	if (NSEqualSizes([_view remoteSize], _fittedRemote))
		return;
	[self fitWindowToRemote];
}

- (void)windowWillEnterFullScreen:(NSNotification*)notification
{
	self.window.contentMaxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
}

- (void)windowDidExitFullScreen:(NSNotification*)notification
{
	if ([self isFixedMode])
		[self fitWindowToRemote];
}

// Top-right corner of the title bar: hint plus the RU/EN button.
- (void)buildLanguageAccessory
{
	NSTextField* label = [NSTextField labelWithString:@"Язык: ⌥ Option + ⇧ Shift"];
	label.font = [NSFont systemFontOfSize:11];
	label.textColor = NSColor.secondaryLabelColor;
	label.toolTip = @"На сервере русский и английский переключаются ⌥ Option + ⇧ Shift. Ещё: кнопка RU/EN или ⌘⇧Пробел.";
	NSButton* button = [NSButton buttonWithTitle:@"RU/EN" target:self action:@selector(switchLanguage:)];
	button.bezelStyle = NSBezelStyleRounded;
	button.controlSize = NSControlSizeSmall;
	button.font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]
	                                weight:NSFontWeightSemibold];
	button.refusesFirstResponder = YES;
	button.toolTip = @"Переключить язык на сервере (отправляет ⌥ Option + ⇧ Shift). Сочетание на Маке: ⌘⇧Пробел.";
	[label sizeToFit];
	[button sizeToFit];
	CGFloat height = 28;
	CGFloat gap = 8;
	CGFloat width = label.frame.size.width + gap + button.frame.size.width + 10;
	NSView* holder = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
	label.frame = NSMakeRect(0, (height - label.frame.size.height) / 2.0, label.frame.size.width, label.frame.size.height);
	button.frame = NSMakeRect(NSMaxX(label.frame) + gap, (height - button.frame.size.height) / 2.0,
	                          button.frame.size.width, button.frame.size.height);
	[holder addSubview:label];
	[holder addSubview:button];
	NSTitlebarAccessoryViewController* accessory = [NSTitlebarAccessoryViewController new];
	accessory.view = holder;
	accessory.layoutAttribute = NSLayoutAttributeRight;
	[self.window addTitlebarAccessoryViewController:accessory];
}

- (void)switchLanguage:(id)sender
{
	(void)sender;
	if (!_rdp || !_view.session)
	{
		NSBeep();
		return;
	}
	[_view sendLanguageToggle];
	[self.window makeFirstResponder:_view];
	[self appendLog:@"Отправил на сервер ⌥ Option + ⇧ Shift (переключение языка)."];
}

- (void)configureServerLanguage:(id)sender
{
	(void)sender;
	__weak typeof(self) weakSelf = self;
	[LanguageSetup runInteractiveForServer:_server
	                                window:self.window
	                                   log:^(NSString* line) {
		                                   [weakSelf appendLog:line];
	                                   }];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if (item.action == @selector(switchLanguage:))
		return _rdp != NULL && _view.session != NULL;
	if (item.action == @selector(toggleExtremeEconomy:))
		item.state = _server.isExtremeEconomy ? NSControlStateValueOn : NSControlStateValueOff;
	if (item.action == @selector(reconnectNow:))
		return !_cancelled;
	return YES;
}

// Once per server, after the first picture of a session arrives: offer the server setup.
- (void)maybeOfferLanguageSetup
{
	if (_languageOfferShown || _server.languageSetup.length > 0 || !_server.sshEnabled || _cancelled)
		return;
	_languageOfferShown = YES;
	NSAlert* alert = [NSAlert new];
	alert.messageText = @"Настроить переключение языка на сервере?";
	alert.informativeText = @"Дальний по SSH, без sudo, включит на сервере раскладки us и ru и переключение ⌥ Option + ⇧ Shift (настройки XFCE и текущий сеанс). Это можно сделать и позже: меню «Подключение» → «Настроить переключение языка на сервере…».";
	[alert addButtonWithTitle:@"Настроить"];
	[alert addButtonWithTitle:@"Не надо"];
	__weak typeof(self) weakSelf = self;
	[alert beginSheetModalForWindow:self.window
	              completionHandler:^(NSModalResponse response) {
		              typeof(self) strongSelf = weakSelf;
		              if (!strongSelf)
			              return;
		              BOOL yes = response == NSAlertFirstButtonReturn;
		              strongSelf->_server.languageSetup = yes ? @"done" : @"declined";
		              [[ServerStore sharedStore] save];
		              [strongSelf.window makeFirstResponder:strongSelf->_view];
		              if (yes)
			              dispatch_async(dispatch_get_main_queue(), ^{
				              [strongSelf configureServerLanguage:nil];
			              });
		              else
			              [strongSelf appendLog:@"Настройку языка на сервере не делаю. Её можно запустить из меню «Подключение»."];
	              }];
}

- (void)startPathMonitor
{
	_monitor = nw_path_monitor_create();
	nw_path_monitor_set_queue(_monitor, _pathQueue);
	__weak typeof(self) weakSelf = self;
	nw_path_monitor_set_update_handler(_monitor, ^(nw_path_t path) {
		[weakSelf handlePath:path];
	});
	nw_path_monitor_start(_monitor);
}

- (void)handlePath:(nw_path_t)path
{
	BOOL up = nw_path_get_status(path) == nw_path_status_satisfied;
	NSMutableArray* names = [NSMutableArray array];
	nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
		const char* name = nw_interface_get_name(interface);
		if (name)
			[names addObject:@(name)];
		return true;
	});
	[names sortUsingSelector:@selector(compare:)];
	NSString* signature = [NSString stringWithFormat:@"%d:%@", up, [names componentsJoinedByString:@","]];
	if (!_havePath)
	{
		_havePath = YES;
		_networkUp = up;
		_pathSignature = signature;
		return;
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), _pathQueue, ^{
		if (self->_cancelled)
			return;
		BOOL changed = self->_pathSignature && ![self->_pathSignature isEqualToString:signature];
		self->_networkUp = up;
		self->_pathSignature = signature;
		if (!up)
		{
			[self setStatus:@"Нет сети. Жду, пока появится маршрут…"];
			[self abortWork];
			return;
		}
		if (changed)
		{
			if (self->_rdp && self->_sawFrame && self->_probeProven && !self->_stallDrop)
			{
				/* The session answers link probes: give it a few seconds to prove it survived
				 * (split-tunnel VPNs often keep it). Otherwise the run loop reconnects. */
				self->_pathCheckBaseline = self->_lastAnswer;
				self->_pathCheckDeadline = CFAbsoluteTimeGetCurrent() + 6;
				[self setStatus:@"Сеть изменилась (VPN или другой интерфейс). Проверяю связь…"];
				[self appendLog:@"Сетевой маршрут изменился, проверяю, отвечает ли сеанс."];
				return;
			}
			[self setStatus:@"Сеть изменилась (VPN или другой интерфейс). Переподключаюсь…"];
			[self appendLog:@"Сетевой маршрут изменился, начинаю чистое переподключение."];
			[self abortWork];
		}
	});
}

- (void)abortWork
{
	self->_immediate = YES;
	self->_generation += 1;
	[self->_tunnel stop];
	rdp_session_stop(self->_rdp);
	dispatch_semaphore_signal(self->_wake);
}

- (void)setStatus:(NSString*)text
{
	dispatch_async(dispatch_get_main_queue(), ^{
		self->_status.stringValue = text ?: @"";
	});
}

- (void)appendLog:(NSString*)line
{
	if (line.length == 0)
		return;
	[DalnyLog append:line];
	dispatch_async(dispatch_get_main_queue(), ^{
		NSDateFormatter* formatter = [NSDateFormatter new];
		formatter.dateFormat = @"HH:mm:ss";
		NSString* row = [NSString stringWithFormat:@"%@  %@\n", [formatter stringFromDate:[NSDate date]], line];
		[self->_logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:row]];
		[self->_logView scrollRangeToVisible:NSMakeRange(self->_logView.string.length, 0)];
	});
}

- (void)checkKeyboardLayout
{
	TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
	if (!source)
		return;
	NSString* identifier = (__bridge NSString*)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
	CFRelease(source);
	BOOL cyrillic = [identifier rangeOfString:@"Russian" options:NSCaseInsensitiveSearch].location != NSNotFound;
	_hint.stringValue = cyrillic
	    ? @"Сейчас на Mac включена русская раскладка. Переключите Mac на ABC, иначе буквы поедут. Язык внутри сервера — это ⌥ Option + ⇧ Shift."
	    : @"Раскладка Mac: ABC. На сервере русский и английский переключаются ⌥ Option + ⇧ Shift или кнопкой RU/EN.";
	_hint.textColor = cyrillic ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
}

- (BOOL)askCertificate:(NSString*)fingerprint changed:(int)changed
{
	__block int accepted = 0;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSAlert* alert = [NSAlert new];
		alert.messageText = changed ? @"Сертификат рабочего стола изменился" : @"Новый сертификат рабочего стола";
		NSString* detail = changed
		    ? @"Отпечаток больше не совпадает с сохранённым. Если вы сами не меняли сертификат на сервере, подключаться не стоит."
		    : @"Сертификат ещё не сохранён. Через туннель имя в нём может быть не 127.0.0.1 — смотрите на отпечаток.";
		alert.informativeText = [NSString stringWithFormat:@"%@\n\nОтпечаток:\n%@", detail, fingerprint ?: @""];
		alert.alertStyle = changed ? NSAlertStyleCritical : NSAlertStyleWarning;
		[alert addButtonWithTitle:@"Доверять"];
		[alert addButtonWithTitle:@"Отмена"];
		accepted = [alert runModal] == NSAlertFirstButtonReturn;
		if (accepted)
		{
			self->_server.certFingerprint = fingerprint ?: @"";
			[[ServerStore sharedStore] save];
		}
	});
	return accepted;
}

- (BOOL)askHost:(NSString*)fingerprint changed:(BOOL)changed
{
	__block BOOL trusted = NO;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSAlert* alert = [NSAlert new];
		alert.messageText = changed ? @"Ключ SSH-сервера изменился" : @"Подтвердите сервер SSH";
		alert.informativeText = changed
		    ? [NSString stringWithFormat:@"Это может быть другой компьютер. Новый отпечаток:\n%@", fingerprint]
		    : [NSString stringWithFormat:@"Первое подключение. Отпечаток:\n%@", fingerprint];
		alert.alertStyle = changed ? NSAlertStyleCritical : NSAlertStyleWarning;
		[alert addButtonWithTitle:@"Доверять"];
		[alert addButtonWithTitle:@"Отмена"];
		trusted = [alert runModal] == NSAlertFirstButtonReturn;
	});
	return trusted;
}

// Wrong login or password: tell the user and let them type it again. Saves to the Keychain.
// Returns YES when new credentials were saved and a new attempt makes sense.
- (BOOL)askCredentialsForSSH:(BOOL)ssh
{
	NSString* title = _server.displayTitle;
	NSString* user = ssh && _server.sshUsername.length ? _server.sshUsername : _server.username;
	NSString* account = ssh ? _server.sshPasswordAccount : _server.rdpPasswordAccount;
	NSString* notice = [NSString stringWithFormat:@"Неверный логин или пароль %@для сервера «%@». Проверьте и введите заново.",
	                                              ssh ? @"SSH " : @"", title];
	[self appendLog:notice];
	[self setStatus:notice];
	__block BOOL saved = NO;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSAlert* alert = [NSAlert new];
		alert.messageText = notice;
		alert.informativeText = @"Пароль будет сохранён в Связке ключей.";
		alert.alertStyle = NSAlertStyleWarning;
		NSTextField* userField = [NSTextField textFieldWithString:user ?: @""];
		userField.placeholderString = @"Пользователь";
		NSSecureTextField* passwordField = [NSSecureTextField new];
		passwordField.placeholderString = @"Пароль";
		userField.translatesAutoresizingMaskIntoConstraints = NO;
		passwordField.translatesAutoresizingMaskIntoConstraints = NO;
		NSStackView* stack = [NSStackView stackViewWithViews:@[ userField, passwordField ]];
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		stack.spacing = 8;
		stack.frame = NSMakeRect(0, 0, 300, 56);
		[NSLayoutConstraint activateConstraints:@[
			[userField.widthAnchor constraintEqualToConstant:300],
			[passwordField.widthAnchor constraintEqualToConstant:300]
		]];
		alert.accessoryView = stack;
		[alert addButtonWithTitle:@"Сохранить и подключиться"];
		[alert addButtonWithTitle:@"Отмена"];
		alert.window.initialFirstResponder = passwordField;
		if ([alert runModal] != NSAlertFirstButtonReturn)
			return;
		NSString* newUser = [userField.stringValue
		    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		NSString* newPassword = passwordField.stringValue ?: @"";
		if (newUser.length == 0 || newPassword.length == 0)
		{
			[self appendLog:@"Логин или пароль не введены."];
			return;
		}
		NSError* keychainError = nil;
		if (![Keychain setSecret:newPassword account:account error:&keychainError])
		{
			[self appendLog:keychainError.localizedDescription ?: @"Пароль не записан в Связку ключей."];
			return;
		}
		if (ssh)
		{
			if (![newUser isEqualToString:user])
				self->_server.sshUsername = newUser;
		}
		else
			self->_server.username = newUser;
		[[ServerStore sharedStore] save];
		[self appendLog:@"Новые логин и пароль сохранены."];
		saved = YES;
	});
	return saved;
}

// Waits up to `seconds`. Returns early on cancel, a manual or network retry, or when the
// network goes away (online) / comes back (offline).
- (void)sleepSeconds:(double)seconds generation:(NSInteger)generation
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
	BOOL offline = !_networkUp;
	while (!_cancelled && !_immediate && _generation == generation && [deadline timeIntervalSinceNow] > 0)
	{
		if (_networkUp == offline)
			return;
		dispatch_semaphore_wait(_wake, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)));
	}
}


- (double)backoffForAttempt:(int)attempt
{
	int index = attempt - 1;
	int last = (int)(sizeof(kReconnectBackoff) / sizeof(kReconnectBackoff[0])) - 1;
	if (index < 0)
		index = 0;
	if (index > last)
		index = last;
	return kReconnectBackoff[index];
}

- (void)startLoop
{
	if (_loopRunning || _cancelled)
		return;
	_loopRunning = YES;
	dispatch_async(_queue, ^{
		[self runLoop];
	});
}

- (void)runLoop
{
	int attempt = 0;
	NSString* lastReason = @"";
	NSString* stopMessage = nil;
	_giveUp = NO;
	_credentialsRejected = NO;
	_immediate = NO;
	_dropStarted = nil;
	while (!_cancelled)
	{
		if (!_networkUp)
		{
			[self setStatus:@"Нет сети. Жду, пока появится маршрут…"];
			[self showOverlayTitle:@"Связь потеряна — нет сети"
			                detail:@"Жду, пока появится сеть (Wi‑Fi, кабель или VPN). Переподключусь сразу, как только она появится."
			                 retry:@"Переподключиться сейчас"
			                 final:NO];
			/* Time without any network does not count towards giving up. */
			_dropStarted = nil;
			[self sleepSeconds:3600 generation:_generation];
			continue;
		}
		if (attempt > 0)
		{
			if (!_dropStarted)
				_dropStarted = [NSDate date];
			if (!_immediate)
			{
				if (-[_dropStarted timeIntervalSinceNow] > kReconnectGiveUpSeconds)
				{
					stopMessage = [NSString stringWithFormat:@"Не удалось переподключиться за 5 минут. %@", lastReason ?: @""];
					break;
				}
				double delay = [self backoffForAttempt:attempt];
				[self setStatus:[NSString stringWithFormat:@"Связь потеряна — переподключаюсь… (попытка %d, через %.0f с). %@",
				                                           attempt, delay, lastReason ?: @""]];
				[self showOverlayTitle:[NSString stringWithFormat:@"Связь потеряна — переподключаюсь… (попытка %d)", attempt]
				                detail:[NSString stringWithFormat:@"Следующая попытка через %.0f с. %@", delay, lastReason ?: @""]
				                 retry:@"Переподключиться сейчас"
				                 final:NO];
				[self sleepSeconds:delay generation:_generation];
				if (_cancelled)
					break;
				if (!_networkUp)
					continue;
			}
			[self showOverlayTitle:[NSString stringWithFormat:@"Связь потеряна — переподключаюсь… (попытка %d)", attempt]
			                detail:@"Подключаюсь заново к тому же сеансу на сервере…"
			                 retry:@"Переподключиться сейчас"
			                 final:NO];
		}
		_immediate = NO;
		_stallDrop = NO;
		_pathCheckDeadline = 0;
		NSInteger generation = _generation;

		NSError* passwordError = nil;
		NSString* password = [Keychain secretForAccount:_server.rdpPasswordAccount error:&passwordError] ?: @"";
		NSMutableArray<NSString*>* missing = [NSMutableArray array];
		if (_server.host.length == 0)
			[missing addObject:@"адрес"];
		if (_server.username.length == 0)
			[missing addObject:@"пользователь"];
		if (password.length == 0)
		{
			if (passwordError.localizedDescription.length > 0)
				[missing addObject:[NSString stringWithFormat:@"пароль рабочего стола — %@", passwordError.localizedDescription]];
			else
				[missing addObject:@"пароль рабочего стола"];
		}
		if (missing.count > 0)
		{
			stopMessage = [NSString stringWithFormat:@"Подключение остановлено: не заполнено — %@.",
			                                         [missing componentsJoinedByString:@"; "]];
			break;
		}

		NSString* targetHost = _server.host;
		int targetPort = (int)_server.port;
		if (_server.sshEnabled)
		{
			[self setStatus:@"Поднимаю SSH-туннель…"];
			NSString* key = nil;
			NSString* sshPassword = nil;
			NSError* sshSecretError = nil;
			BOOL sshPasswordAuth = [_server.sshAuth isEqualToString:@"password"];
			if (sshPasswordAuth)
				sshPassword = [Keychain secretForAccount:_server.sshPasswordAccount error:&sshSecretError];
			else
				key = [Keychain secretForAccount:_server.sshKeyAccount error:&sshSecretError];
			if (key.length == 0 && sshPassword.length == 0)
			{
				NSString* field = sshPasswordAuth ? @"пароль SSH" : @"секретный ключ SSH";
				stopMessage = sshSecretError.localizedDescription.length > 0
				    ? [NSString stringWithFormat:@"Подключение остановлено: нет поля «%@». %@", field,
				                                 sshSecretError.localizedDescription]
				    : [NSString stringWithFormat:@"Подключение остановлено: не заполнено — %@.", field];
				break;
			}
			NSString* sshHost = _server.effectiveSSHHost;
			NSString* sshUser = _server.sshUsername.length ? _server.sshUsername : _server.username;
			NSError* error = nil;
			__weak typeof(self) weakSelf = self;
			/* A new local port every time (startHost reserves a fresh one). */
			BOOL up = [_tunnel startHost:sshHost
			                        port:(int)_server.sshPort
			                    username:sshUser
			                  remotePort:(int)_server.port
			                      keyPEM:key
			                    password:sshPassword
			                     askHost:^BOOL(NSString* fingerprint, BOOL changed) {
				                     return [weakSelf askHost:fingerprint changed:changed];
			                     }
			                         log:^(NSString* line) {
				                         [weakSelf appendLog:line];
			                         }
			                       error:&error];
			if (!up)
			{
				lastReason = error.localizedDescription ?: @"Туннель не открылся.";
				[self appendLog:lastReason];
				if (_cancelled)
					break;
				if (error.code == 4)
				{
					if (sshPasswordAuth && [self askCredentialsForSSH:YES])
					{
						attempt = 0;
						_immediate = YES;
						continue;
					}
					stopMessage = sshPasswordAuth
					    ? [NSString stringWithFormat:@"Сервер SSH «%@» не принял логин или пароль.", _server.displayTitle]
					    : [NSString stringWithFormat:@"Сервер SSH «%@» не принял ключ. Проверьте пользователя и ключ в настройках сервера.",
					                                 _server.displayTitle];
					break;
				}
				if (error.code == 1 || error.code == 2)
				{
					stopMessage = [NSString stringWithFormat:@"Не удалось: %@", lastReason];
					break;
				}
				if (!_server.autoReconnect && generation == _generation)
				{
					stopMessage = [NSString stringWithFormat:@"Не удалось: %@ Само переподключение выключено в настройках сервера.", lastReason];
					break;
				}
				attempt = MAX(attempt + (generation == _generation ? 1 : 0), 1);
				continue;
			}
			if (_cancelled || generation != _generation)
			{
				attempt = MAX(attempt, 1);
				continue;
			}
			targetHost = @"127.0.0.1";
			targetPort = _tunnel.localPort;
			[self setStatus:@"Туннель готов. Вхожу на рабочий стол…"];
		}
		else
		{
			[self setStatus:@"Подключаюсь к рабочему столу…"];
		}

		RDPParams params;
		memset(&params, 0, sizeof(params));
		snprintf(params.host, sizeof(params.host), "%s", targetHost.UTF8String);
		params.port = targetPort;
		snprintf(params.username, sizeof(params.username), "%s", _server.username.UTF8String);
		snprintf(params.password, sizeof(params.password), "%s", password.UTF8String);
		__block int liveWidth = (int)_server.width;
		__block int liveHeight = (int)_server.height;
		if (![self isFixedMode])
		{
			if (_lastRemoteWidth >= 200 && _lastRemoteHeight >= 200)
			{
				/* Reconnect: same size as the session we lost, so xrdp hands back the same desktop. */
				liveWidth = _lastRemoteWidth;
				liveHeight = _lastRemoteHeight;
			}
			else
			{
				dispatch_sync(dispatch_get_main_queue(), ^{
					NSSize size = self->_view.bounds.size;
					CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1;
					if ([self->_server.displayMode isEqualToString:@"fullscreen"])
						size = self.window.screen ? self.window.screen.frame.size : size;
					liveWidth = MAX(640, (int)(size.width * scale));
					liveHeight = MAX(480, (int)(size.height * scale));
				});
			}
		}
		params.width = liveWidth;
		params.height = liveHeight;
		params.colorDepth = (int)_server.colorDepth;
		params.profile = [DalnyServer profileIndex:_server.graphics];
		params.clipboard = _server.shareClipboard;
		snprintf(params.trustedFingerprint, sizeof(params.trustedFingerprint), "%s",
		         _server.certFingerprint.UTF8String ?: "");
		NSString* plugins = [[NSBundle mainBundle] privateFrameworksPath];
		snprintf(params.pluginsDir, sizeof(params.pluginsDir), "%s", plugins.UTF8String ?: "");
		[self appendLog:[NSString stringWithFormat:@"Рабочий стол %dx%d, %d бит, профиль «%@».", liveWidth, liveHeight,
		                                           params.colorDepth, _server.graphics ?: @"economy"]];

		RDPHandlers handlers = {0};
		handlers.ctx = (__bridge void*)self;
		handlers.logmsg = log_thunk;
		handlers.frame = frame_thunk;
		handlers.resized = resize_thunk;
		handlers.clipboard_text = clipboard_thunk;
		handlers.clipboard_image = clipboard_image_thunk;
		handlers.ask_certificate = cert_thunk;
		handlers.disconnected = disconnect_thunk;
		handlers.link = link_thunk;

		_rdp = rdp_session_create(&params, &handlers);
		memset(params.password, 0, sizeof(params.password));
		if (!_rdp)
		{
			stopMessage = @"Не удалось подготовить FreeRDP.";
			break;
		}
		self->_sawFrame = NO;
		self->_probeProven = NO;
		self->_rttAverage = 0;
		self->_lastAnswer = 0;
		dispatch_async(dispatch_get_main_queue(), ^{
			/* Offer what is on the Mac clipboard now to the new session. */
			self->_pasteboardBaseline = -1;
			self->_view.session = self->_rdp;
			[self.window makeFirstResponder:self->_view];
			[self checkKeyboardLayout];
			BOOL fullscreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
			if ([self->_server.displayMode isEqualToString:@"fullscreen"] && !fullscreen)
				[self.window toggleFullScreen:nil];
		});
		self->_rdpFinished = NO;
		rdp_session_start(_rdp);
		NSString* dropReason = nil;
		int tick = 0;
		while (!self->_rdpFinished)
		{
			if (self->_cancelled || generation != self->_generation)
				rdp_session_stop(self->_rdp);
			else if (!dropReason && ++tick % 5 == 0)
			{
				/* Twice a second: tunnel process, link stall, path-change check. */
				if (_server.sshEnabled && ![_tunnel checkAlive])
					dropReason = @"SSH-туннель оборвался (процесс ssh завершился).";
				else if (_stallDrop)
					dropReason = [NSString stringWithFormat:@"Сервер не отвечает %d с.", kStallDropMs / 1000];
				else if (_pathCheckDeadline > 0)
				{
					if (_lastAnswer > _pathCheckBaseline)
					{
						_pathCheckDeadline = 0;
						[self appendLog:@"Сеть изменилась, но сеанс отвечает — переподключение не нужно."];
						[self setStatus:@"Подключено."];
					}
					else if (CFAbsoluteTimeGetCurrent() > _pathCheckDeadline)
					{
						_pathCheckDeadline = 0;
						dropReason = @"После смены сети сервер не отвечает.";
						_immediate = YES;
					}
				}
				if (dropReason)
				{
					[self appendLog:dropReason];
					rdp_session_stop(self->_rdp);
				}
			}
			usleep(100000);
		}
		RDPSession* finished = _rdp;
		_rdp = NULL;
		/* Synchronous: the view, the pasteboard timer and the menu must stop using the session
		 * before it is freed. */
		dispatch_sync(dispatch_get_main_queue(), ^{
			[self->_view releaseAllKeys];
			self->_view.session = nil;
			self->_poorBar.hidden = YES;
		});
		rdp_session_destroy(finished);
		[_tunnel stop];
		if (_cancelled)
			break;
		BOOL hadFrame = _sawFrame;
		if (hadFrame)
		{
			attempt = 0;
			_dropStarted = nil;
			_lastRemoteWidth = _remoteWidth;
			_lastRemoteHeight = _remoteHeight;
		}
		/* A stop the app asked for (network change, dead tunnel, stall) is never fatal. */
		if (dropReason || generation != _generation)
		{
			_giveUp = NO;
			_credentialsRejected = NO;
		}
		if (_giveUp && _credentialsRejected)
		{
			_giveUp = NO;
			_credentialsRejected = NO;
			if ([self askCredentialsForSSH:NO])
			{
				attempt = 0;
				_immediate = YES;
				continue;
			}
			stopMessage = [NSString stringWithFormat:@"Неверный логин или пароль для сервера «%@». Подключение остановлено.",
			                                         _server.displayTitle];
			break;
		}
		if (_giveUp)
		{
			_giveUp = NO;
			stopMessage = [NSString stringWithFormat:@"Подключение остановлено: %@", _lastReason ?: @"ошибка настройки."];
			break;
		}
		lastReason = dropReason ?: (_lastReason ?: lastReason);
		if (_immediate || generation != _generation)
		{
			attempt = MAX(attempt + 1, 1);
			continue;
		}
		if (!_server.autoReconnect)
		{
			stopMessage = [NSString stringWithFormat:@"Связь потеряна. %@ Само переподключение выключено в настройках сервера.",
			                                         lastReason ?: @""];
			break;
		}
		attempt += 1;
	}
	if (_cancelled)
	{
		[self setStatus:@"Отключено."];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_loopRunning = NO;
		});
		return;
	}
	/* The window stays open with a big reconnect button. It only closes when the user closes it. */
	NSString* message = stopMessage ?: @"Подключение остановлено.";
	[self appendLog:message];
	[self setStatus:message];
	[self showOverlayTitle:@"Нет подключения" detail:message retry:@"Переподключиться" final:YES];
	dispatch_async(dispatch_get_main_queue(), ^{
		self->_loopRunning = NO;
	});
}

- (void)deliverFrame:(const uint8_t*)bytes width:(int)width height:(int)height stride:(int)stride
{
	[_view updateFrameWithBytes:bytes width:width height:height stride:stride];
	if (width != _remoteWidth || height != _remoteHeight)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			[self->_view noteRemoteSizeWidth:width height:height];
			[self remoteSizeChanged];
		});
	}
	_remoteWidth = width;
	_remoteHeight = height;
	if (!_sawFrame)
	{
		_sawFrame = YES;
		BOOL reconnected = _lastRemoteWidth > 0 || _dropStarted != nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			BOOL wasLost = !self->_overlay.hidden;
			self->_overlay.hidden = YES;
			self->_poorDismissed = NO;
			self->_status.stringValue = @"Подключено.";
			if (wasLost || reconnected)
			{
				[self appendLog:@"Связь восстановлена."];
				/* Same session at the old size; now match the window again if it changed. */
				if (![self isFixedMode])
					dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
					               dispatch_get_main_queue(), ^{
						               NSSize size = self->_view.bounds.size;
						               CGFloat scale = self.window.backingScaleFactor ?: 1;
						               int width = MAX(640, (int)(size.width * scale)) & ~1;
						               int height = MAX(480, (int)(size.height * scale)) & ~1;
						               if (abs(width - self->_remoteWidth) > 2 || abs(height - self->_remoteHeight) > 2)
							               [self requestFitSize];
					               });
			}
		});
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (self->_rdp && !self.window.attachedSheet)
				[self maybeOfferLanguageSetup];
		});
	}
}

- (void)noteResizeWidth:(int)width height:(int)height
{
	_remoteWidth = width;
	_remoteHeight = height;
	dispatch_async(dispatch_get_main_queue(), ^{
		[self->_view noteRemoteSizeWidth:width height:height];
		[self remoteSizeChanged];
	});
}

- (void)deliverClipboard:(NSString*)text
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
		[pasteboard clearContents];
		[pasteboard setString:text forType:NSPasteboardTypeString];
		self->_pasteboardBaseline = pasteboard.changeCount;
	});
}

- (void)deliverClipboardImage:(NSData*)dib isV5:(BOOL)isV5
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
		if ([ClipboardImage writeDIB:dib toPasteboard:pasteboard])
		{
			self->_pasteboardBaseline = pasteboard.changeCount;
			[self appendLog:[NSString stringWithFormat:@"Картинка с сервера в буфере Мака (%@, %lu КБ).",
			                                           isV5 ? @"CF_DIBV5" : @"CF_DIB",
			                                           (unsigned long)(dib.length / 1024)]];
		}
		else
			[self appendLog:@"Сервер прислал картинку, но её не удалось прочитать."];
	});
}

- (void)sessionEndedFatal:(int)fatal reason:(NSString*)reason
{
	_lastReason = reason;
	if (fatal)
		_giveUp = YES;
	if (fatal == RDP_FATAL_CREDENTIALS)
		_credentialsRejected = YES;
	[self appendLog:reason];
	if (fatal)
		[self setStatus:[NSString stringWithFormat:@"Не удалось: %@", reason]];
	_rdpFinished = 1;
}

- (void)showWindow:(id)sender
{
	self.window.delegate = (id<NSWindowDelegate>)self;
	if (!_started && [self isFixedMode] && _server.width >= 200 && _server.height >= 200)
	{
		/* Size the window for the requested desktop before the first frame arrives. */
		[_view noteRemoteSizeWidth:(int)_server.width height:(int)_server.height];
		[self fitWindowToRemote];
	}
	[super showWindow:sender];
	if (!_started)
		[self.window center];
	if (!_started)
	{
		_started = YES;
		dispatch_async(dispatch_get_main_queue(), ^{
			[self startLoop];
		});
	}
	[_pasteboardTimer invalidate];
	_pasteboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
	                                                    target:self
	                                                  selector:@selector(pollPasteboard)
	                                                  userInfo:nil
	                                                   repeats:YES];
	_pasteboardBaseline = [NSPasteboard generalPasteboard].changeCount;
}

- (void)pollPasteboard
{
	if (!_server.shareClipboard || !_rdp)
		return;
	NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
	if (pasteboard.changeCount == _pasteboardBaseline)
		return;
	_pasteboardBaseline = pasteboard.changeCount;
	NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
	NSString* reason = nil;
	/* 20 megapixels is about 60 MB as 24-bit DIB, under the 64 MB channel limit. */
	NSData* dib = [ClipboardImage dibFromPasteboard:pasteboard maxPixels:20000000 reason:&reason];
	if (reason)
		[self appendLog:reason];
	if (!text && !dib)
		return;
	rdp_session_set_clipboard(_rdp, text.UTF8String, dib.bytes, dib.length);
	if (dib)
		[self appendLog:[NSString stringWithFormat:@"Картинка из буфера Мака передана серверу (%lu КБ).",
		                                           (unsigned long)(dib.length / 1024)]];
}

- (void)windowDidBecomeKey:(NSNotification*)notification
{
	[self checkKeyboardLayout];
}

// Cmd+Tab and similar leave the window with modifiers down on the server (Ctrl from Command,
// Alt, Shift). A stuck modifier breaks Option+Shift later, so release everything here.
- (void)windowDidResignKey:(NSNotification*)notification
{
	[_view releaseAllKeys];
}

- (void)windowDidEndLiveResize:(NSNotification*)notification
{
	[_resizeTimer invalidate];
	_resizeTimer = nil;
	[self requestFitSize];
}

// Zoom, tiling and screen changes resize without a live resize. Ask the server once things settle.
- (void)windowDidResize:(NSNotification*)notification
{
	if ([self isFixedMode] || self.window.inLiveResize)
		return;
	[_resizeTimer invalidate];
	_resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
	                                                target:self
	                                              selector:@selector(resizeTimerFired:)
	                                              userInfo:nil
	                                               repeats:NO];
}

- (void)resizeTimerFired:(NSTimer*)timer
{
	_resizeTimer = nil;
	[self requestFitSize];
}

- (void)windowDidChangeScreen:(NSNotification*)notification
{
	if ([self isFixedMode])
		[self fitWindowToRemote];
}

- (void)requestFitSize
{
	if (_cancelled || !_rdp)
		return;
	if ([_server.displayMode isEqualToString:@"fixed"])
		return;
	NSSize size = _view.bounds.size;
	CGFloat scale = self.window.backingScaleFactor ?: 1;
	int width = (int)(size.width * scale);
	int height = (int)(size.height * scale);
	if (width < 640)
		width = 640;
	if (height < 480)
		height = 480;
	rdp_session_request_resize(_rdp, width, height);
}

- (void)toggleLog:(id)sender
{
	_logScroll.hidden = !_logScroll.hidden;
	_logButton.title = _logScroll.hidden ? @"Журнал" : @"Скрыть журнал";
	if (_logScroll.hidden)
	{
		_viewToLog.active = NO;
		_viewToBottom.active = YES;
	}
	else
	{
		_viewToBottom.active = NO;
		_viewToLog.active = YES;
	}
	if ([self isFixedMode])
		[self fitWindowToRemote];
}

- (void)copyLog:(id)sender
{
	NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString:_logView.string ?: @"" forType:NSPasteboardTypeString];
}

- (void)disconnect:(id)sender
{
	_cancelled = YES;
	_server.autoReconnect = _server.autoReconnect;
	[self appendLog:@"Отключаюсь по кнопке."];
	[self abortWork];
	[self.window close];
}

- (void)windowWillClose:(NSNotification*)notification
{
	_cancelled = YES;
	[self abortWork];
	if (_monitor)
		nw_path_monitor_cancel(_monitor);
	[_pasteboardTimer invalidate];
	[_resizeTimer invalidate];
	_resizeTimer = nil;
	/* Only closing the window ends a session window. Network loss never does. */
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:@"DalnySessionFinished" object:self];
	});
}

@end

static SessionWindow* window_from(void* ctx)
{
	return (__bridge SessionWindow*)ctx;
}

static void log_thunk(void* ctx, const char* line)
{
	[window_from(ctx) appendLog:line ? @(line) : @""];
}

static void frame_thunk(void* ctx, const uint8_t* bgra, int width, int height, int stride, int x, int y, int w, int h)
{
	(void)x;
	(void)y;
	(void)w;
	(void)h;
	[window_from(ctx) deliverFrame:bgra width:width height:height stride:stride];
}

static void resize_thunk(void* ctx, int width, int height)
{
	[window_from(ctx) noteResizeWidth:width height:height];
}

static void clipboard_thunk(void* ctx, const char* utf8)
{
	[window_from(ctx) deliverClipboard:utf8 ? @(utf8) : @""];
}

static void clipboard_image_thunk(void* ctx, const uint8_t* dib, size_t length, int isV5)
{
	if (!dib || length == 0)
		return;
	[window_from(ctx) deliverClipboardImage:[NSData dataWithBytes:dib length:length] isV5:isV5 != 0];
}

static int cert_thunk(void* ctx, const char* fingerprint, int changed)
{
	return [window_from(ctx) askCertificate:fingerprint ? @(fingerprint) : @"" changed:changed];
}

static void link_thunk(void* ctx, int rttMs, int stalledMs, int proven)
{
	[window_from(ctx) linkRtt:rttMs stalled:stalledMs proven:proven];
}

static void disconnect_thunk(void* ctx, int fatal, const char* reason)
{
	[window_from(ctx) sessionEndedFatal:fatal reason:reason ? @(reason) : @"Соединение закрыто"];
}
