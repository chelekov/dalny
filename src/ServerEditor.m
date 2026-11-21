#import "ServerEditor.h"
#import "DalnyLog.h"
#import "Keychain.h"
#import "SSHClient.h"

@implementation ServerEditor
{
	DalnyServer* _server;
	NSInteger _openedDepth;
	NSTextField* _name;
	NSTextField* _host;
	NSTextField* _port;
	NSTextField* _username;
	NSSecureTextField* _password;
	NSPopUpButton* _graphics;
	NSPopUpButton* _display;
	NSTextField* _width;
	NSTextField* _height;
	NSTextField* _bppWarning;
	NSButton* _mapCommand;
	NSButton* _reconnect;
	NSButton* _clipboard;
	NSButton* _sshEnabled;
	NSButton* _advancedToggle;
	NSStackView* _advanced;
	NSButton* _separateSSH;
	NSStackView* _sshPasswordRow;
	NSTextField* _sshHost;
	NSTextField* _sshPort;
	NSTextField* _sshUser;
	NSPopUpButton* _sshAuth;
	NSSecureTextField* _sshPassword;
	NSTextField* _publicKey;
	NSTextView* _installLog;
	NSWindow* _installWindow;
}

- (instancetype)initWithServer:(DalnyServer*)server
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 420)
	                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                                         NSWindowStyleMaskResizable
	                                                 backing:NSBackingStoreBuffered
	                                                   defer:NO];
	window.title = @"Сервер";
	self = [super initWithWindow:window];
	if (self)
	{
		_server = server;
		_openedDepth = server.colorDepth;
		[self build];
		[self loadFields];
		self.window.minSize = NSMakeSize(480, 280);
	}
	return self;
}

- (NSTextField*)label:(NSString*)text
{
	NSTextField* field = [NSTextField labelWithString:text];
	field.font = [NSFont systemFontOfSize:13];
	return field;
}

- (NSTextField*)input
{
	NSTextField* field = [NSTextField textFieldWithString:@""];
	field.font = [NSFont systemFontOfSize:13];
	field.translatesAutoresizingMaskIntoConstraints = NO;
	[field.widthAnchor constraintGreaterThanOrEqualToConstant:280].active = YES;
	return field;
}

- (NSSecureTextField*)secret
{
	NSSecureTextField* field = [NSSecureTextField new];
	field.font = [NSFont systemFontOfSize:13];
	field.translatesAutoresizingMaskIntoConstraints = NO;
	[field.widthAnchor constraintGreaterThanOrEqualToConstant:280].active = YES;
	return field;
}

- (NSStackView*)row:(NSString*)title control:(NSView*)control
{
	NSTextField* label = [self label:title];
	label.alignment = NSTextAlignmentRight;
	[label.widthAnchor constraintEqualToConstant:170].active = YES;
	NSStackView* row = [NSStackView stackViewWithViews:@[ label, control ]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.alignment = NSLayoutAttributeFirstBaseline;
	row.spacing = 8;
	return row;
}

- (void)build
{
	_name = [self input];
	_host = [self input];
	_port = [self input];
	_username = [self input];
	_password = [self secret];
	_graphics = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 24) pullsDown:NO];
	[_graphics addItemsWithTitles:@[ @"Эконом", @"Сбалансированный", @"Качество" ]];
	_graphics.target = self;
	_graphics.action = @selector(profileChanged:);
	_display = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 24) pullsDown:NO];
	[_display addItemsWithTitles:@[ @"По размеру окна", @"Фиксированное", @"На весь экран" ]];
	_width = [self input];
	_height = [self input];
	_bppWarning = [self label:@""];
	_bppWarning.textColor = [NSColor systemOrangeColor];
	_bppWarning.maximumNumberOfLines = 3;
	_bppWarning.preferredMaxLayoutWidth = 460;
	_mapCommand = [NSButton checkboxWithTitle:@"Клавиша ⌘ работает как Ctrl" target:nil action:NULL];
	_reconnect = [NSButton checkboxWithTitle:@"Переподключаться само, если связь пропала" target:nil action:NULL];
	_clipboard = [NSButton checkboxWithTitle:@"Общий буфер обмена (текст)" target:nil action:NULL];
	_sshEnabled = [NSButton checkboxWithTitle:@"Входить через SSH-туннель (так безопаснее)" target:self
	                                   action:@selector(sshToggled:)];
	_sshHost = [self input];
	_sshHost.placeholderString = @"тот же адрес, если пусто";
	_sshPort = [self input];
	_sshUser = [self input];
	_sshUser.placeholderString = @"тот же пользователь, если пусто";
	_sshAuth = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 24) pullsDown:NO];
	[_sshAuth addItemsWithTitles:@[ @"Ключ", @"Пароль" ]];
	_sshAuth.target = self;
	_sshAuth.action = @selector(sshAuthChanged:);
	_sshPassword = [self secret];
	_publicKey = [self input];
	_publicKey.editable = NO;
	_publicKey.selectable = YES;
	_name.placeholderString = @"если пусто — берётся адрес";
	_password.placeholderString = @"рабочий стол и SSH";
	_separateSSH = [NSButton checkboxWithTitle:@"Свой пароль для SSH" target:self action:@selector(separateToggled:)];
	_advancedToggle = [NSButton checkboxWithTitle:@"Дополнительно" target:self action:@selector(toggleAdvanced:)];
	_sshPasswordRow = [self row:@"Пароль SSH" control:_sshPassword];

	NSButton* create = [NSButton buttonWithTitle:@"Создать ключ" target:self action:@selector(createKey:)];
	NSButton* copy = [NSButton buttonWithTitle:@"Скопировать открытый ключ" target:self action:@selector(copyKey:)];
	NSButton* install = [NSButton buttonWithTitle:@"Установить ключ на сервер…" target:self action:@selector(installKey:)];
	NSStackView* keyButtons = [NSStackView stackViewWithViews:@[ create, copy, install ]];
	keyButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	keyButtons.spacing = 8;

	NSTextField* hint = [self label:@"Печатайте при раскладке Mac ABC. Русский и английский переключаются уже на сервере, сочетанием Option+Shift."];
	hint.maximumNumberOfLines = 3;
	hint.preferredMaxLayoutWidth = 560;
	hint.textColor = NSColor.secondaryLabelColor;

	NSButton* save = [NSButton buttonWithTitle:@"Сохранить" target:self action:@selector(save:)];
	save.keyEquivalent = @"\r";
	NSButton* cancel = [NSButton buttonWithTitle:@"Отмена" target:self action:@selector(cancel:)];
	cancel.keyEquivalent = @"\033";
	NSStackView* buttons = [NSStackView stackViewWithViews:@[ cancel, save ]];
	buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	buttons.spacing = 8;

	_advanced = [NSStackView stackViewWithViews:@[
		[self row:@"Порт рабочего стола" control:_port],
		[self row:@"Экран" control:_display],
		[self row:@"Ширина" control:_width],
		[self row:@"Высота" control:_height],
		_bppWarning,
		_mapCommand,
		_reconnect,
		_clipboard,
		hint,
		_sshEnabled,
		[self row:@"Адрес SSH" control:_sshHost],
		[self row:@"Порт SSH" control:_sshPort],
		[self row:@"Пользователь SSH" control:_sshUser],
		[self row:@"Вход SSH" control:_sshAuth],
		_separateSSH,
		_sshPasswordRow,
		[self row:@"Открытый ключ" control:_publicKey],
		keyButtons
	]];
	_advanced.orientation = NSUserInterfaceLayoutOrientationVertical;
	_advanced.alignment = NSLayoutAttributeLeading;
	_advanced.spacing = 8;
	_advanced.detachesHiddenViews = YES;
	_advanced.hidden = YES;

	NSStackView* stack = [NSStackView stackViewWithViews:@[
		[self row:@"Название" control:_name],
		[self row:@"Адрес" control:_host],
		[self row:@"Пользователь" control:_username],
		[self row:@"Пароль" control:_password],
		[self row:@"Картинка" control:_graphics],
		_advancedToggle,
		_advanced,
		buttons
	]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.spacing = 8;
	stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
	stack.detachesHiddenViews = YES;
	stack.translatesAutoresizingMaskIntoConstraints = NO;

	NSScrollView* scroll = [NSScrollView new];
	scroll.hasVerticalScroller = YES;
	scroll.drawsBackground = NO;
	scroll.documentView = stack;
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	[self.window.contentView addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[scroll.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor],
		[stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor]
	]];
}

- (NSString*)profileKey
{
	switch (_graphics.indexOfSelectedItem)
	{
	case 1:
		return @"balanced";
	case 2:
		return @"quality";
	default:
		return @"economy";
	}
}

- (void)loadFields
{
	_name.stringValue = _server.name ?: @"";
	_host.stringValue = _server.host ?: @"";
	_port.stringValue = [NSString stringWithFormat:@"%ld", (long)_server.port];
	_username.stringValue = _server.username ?: @"";
	NSError* passwordError = nil;
	_password.stringValue = [Keychain secretForAccount:_server.rdpPasswordAccount error:&passwordError] ?: @"";
	if (passwordError)
		[DalnyLog append:passwordError.localizedDescription];
	if ([_server.graphics isEqualToString:@"balanced"])
		[_graphics selectItemAtIndex:1];
	else if ([_server.graphics isEqualToString:@"quality"])
		[_graphics selectItemAtIndex:2];
	else
		[_graphics selectItemAtIndex:0];
	if ([_server.displayMode isEqualToString:@"fixed"])
		[_display selectItemAtIndex:1];
	else if ([_server.displayMode isEqualToString:@"fullscreen"])
		[_display selectItemAtIndex:2];
	else
		[_display selectItemAtIndex:0];
	_width.stringValue = [NSString stringWithFormat:@"%ld", (long)_server.width];
	_height.stringValue = [NSString stringWithFormat:@"%ld", (long)_server.height];
	_mapCommand.state = _server.mapCommandToControl ? NSControlStateValueOn : NSControlStateValueOff;
	_reconnect.state = _server.autoReconnect ? NSControlStateValueOn : NSControlStateValueOff;
	_clipboard.state = _server.shareClipboard ? NSControlStateValueOn : NSControlStateValueOff;
	_sshEnabled.state = _server.sshEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	_sshHost.stringValue = _server.sshHost ?: @"";
	_sshPort.stringValue = [NSString stringWithFormat:@"%ld", (long)(_server.sshPort ?: 22)];
	_sshUser.stringValue = _server.sshUsername ?: @"";
	[_sshAuth selectItemAtIndex:[_server.sshAuth isEqualToString:@"password"] ? 1 : 0];
	NSError* sshPasswordError = nil;
	_sshPassword.stringValue = [Keychain secretForAccount:_server.sshPasswordAccount error:&sshPasswordError] ?: @"";
	if (sshPasswordError)
		[DalnyLog append:sshPasswordError.localizedDescription];
	_publicKey.stringValue = _server.sshPublicKey ?: @"";
	BOOL samePassword = _sshPassword.stringValue.length == 0 ||
	                    [_sshPassword.stringValue isEqualToString:_password.stringValue];
	_separateSSH.state = samePassword ? NSControlStateValueOff : NSControlStateValueOn;
	_advancedToggle.state = NSControlStateValueOff;
	[self separateToggled:nil];
	[self toggleAdvanced:nil];
	[self refreshBppWarning];
}

- (void)toggleAdvanced:(id)sender
{
	_advanced.hidden = _advancedToggle.state != NSControlStateValueOn;
}

- (void)separateToggled:(id)sender
{
	BOOL separate = _separateSSH.state == NSControlStateValueOn;
	_sshPasswordRow.hidden = !separate;
	_password.placeholderString = separate ? @"только рабочий стол" : @"рабочий стол и SSH";
}

- (void)refreshBppWarning
{
	NSInteger depth = [[self profileKey] isEqualToString:@"economy"] ? 16 : 32;
	if (_openedDepth != 0 && depth != _openedDepth)
	{
		_bppWarning.stringValue = @"Смена глубины цвета откроет другой рабочий стол на сервере, а не вернёт текущий. Сервер запоминает сеанс отдельно для 16 и 32 бит.";
		_bppWarning.hidden = NO;
	}
	else
	{
		_bppWarning.stringValue = @"";
		_bppWarning.hidden = YES;
	}
}

- (void)profileChanged:(id)sender
{
	_server.graphics = [self profileKey];
	[_server applyGraphicsProfile];
	_width.stringValue = [NSString stringWithFormat:@"%ld", (long)_server.width];
	_height.stringValue = [NSString stringWithFormat:@"%ld", (long)_server.height];
	[self refreshBppWarning];
}

- (void)sshToggled:(id)sender
{
}

- (void)sshAuthChanged:(id)sender
{
}

- (NSString*)committedString:(NSTextField*)field
{
	NSWindow* window = field.window ?: self.window;
	if (window)
		[window endEditingFor:field];
	[field validateEditing];
	NSText* editor = field.currentEditor;
	if (editor)
		return editor.string ?: @"";
	return field.stringValue ?: @"";
}

- (void)createKey:(id)sender
{
	if (_server.sshPublicKey.length > 0)
	{
		NSAlert* alert = [NSAlert new];
		alert.messageText = @"Заменить ключ?";
		alert.informativeText = @"Старый ключ останется на сервере, пока вы сами его не уберёте. В программе будет храниться новый.";
		[alert addButtonWithTitle:@"Создать новый"];
		[alert addButtonWithTitle:@"Отмена"];
		if ([alert runModal] != NSAlertFirstButtonReturn)
			return;
	}
	NSError* error = nil;
	NSString* publicKey = nil;
	NSString* privateKey = nil;
	if (![SSHClient generateEd25519PublicKey:&publicKey privateKey:&privateKey error:&error])
	{
		[self showError:error.localizedDescription ?: @"Не удалось создать ключ."];
		return;
	}
	NSError* keychainError = nil;
	if (![Keychain setSecret:privateKey account:_server.sshKeyAccount error:&keychainError])
	{
		NSString* message = keychainError.localizedDescription ?: @"Связка ключей не приняла ключ.";
		[DalnyLog append:message];
		[self showError:message];
		return;
	}
	_server.sshPublicKey = publicKey;
	_publicKey.stringValue = publicKey;
	[_sshAuth selectItemAtIndex:1];
	[self showError:@"Ключ создан и спрятан в Связке ключей. Нажмите «Установить ключ на сервер». Пока ключ не установлен, SSH входит тем же паролем."];
}

- (void)copyKey:(id)sender
{
	if (_publicKey.stringValue.length == 0)
	{
		[self showError:@"Сначала создайте ключ."];
		return;
	}
	NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString:_publicKey.stringValue forType:NSPasteboardTypeString];
}

- (BOOL)askHostFingerprint:(NSString*)fingerprint changed:(BOOL)changed
{
	__block BOOL trusted = NO;
	void (^show)(void) = ^{
		NSAlert* alert = [NSAlert new];
		alert.messageText = changed ? @"Ключ SSH-сервера изменился" : @"Подтвердите сервер SSH";
		alert.informativeText = changed
		    ? [NSString stringWithFormat:@"Ключ сервера стал другим. Если вы сами не меняли сервер, нажимать «Доверять» не стоит.\n\nНовый отпечаток:\n%@", fingerprint]
		    : [NSString stringWithFormat:@"Это первое подключение к этому SSH-серверу. Сверьте отпечаток, если вам его называли.\n\nОтпечаток:\n%@", fingerprint];
		[alert addButtonWithTitle:@"Доверять"];
		[alert addButtonWithTitle:@"Отмена"];
		alert.alertStyle = changed ? NSAlertStyleCritical : NSAlertStyleWarning;
		trusted = [alert runModal] == NSAlertFirstButtonReturn;
	};
	if (NSThread.isMainThread)
		show();
	else
		dispatch_sync(dispatch_get_main_queue(), show);
	return trusted;
}

- (void)appendInstall:(NSString*)line
{
	NSString* text = [NSString stringWithFormat:@"%@%@\n", _installLog.string ?: @"", line ?: @""];
	_installLog.string = text;
	[_installLog scrollRangeToVisible:NSMakeRange(text.length, 0)];
}

- (void)installKey:(id)sender
{
	[self.window endEditingFor:nil];
	NSString* publicKey = [[self committedString:_publicKey]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (publicKey.length == 0)
	{
		[self showError:@"Не заполнено: открытый ключ. Сначала нажмите «Создать ключ»."];
		return;
	}
	NSString* host = [self committedString:_sshHost];
	if (host.length == 0)
		host = [self committedString:_host];
	host = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString* user = [self committedString:_sshUser];
	if (user.length == 0)
		user = [self committedString:_username];
	user = [user stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	int port = [self committedString:_sshPort].intValue;
	if (port <= 0)
		port = 22;
	NSMutableArray<NSString*>* missing = [NSMutableArray array];
	if (host.length == 0)
		[missing addObject:@"адрес SSH (или адрес сервера)"];
	if (user.length == 0)
		[missing addObject:@"пользователь SSH (или пользователь рабочего стола)"];
	if (missing.count > 0)
	{
		[self showError:[NSString stringWithFormat:@"Не заполнено: %@.", [missing componentsJoinedByString:@", "]]];
		return;
	}
	NSAlert* alert = [NSAlert new];
	alert.messageText = @"Пароль SSH на один раз";
	alert.informativeText = @"Если пароль SSH тот же, он уже подставлен из карточки. Он нужен один раз, чтобы положить ключ. После этого вход по SSH идёт ключом, а пароль в карточке остаётся для рабочего стола.";
	NSSecureTextField* field = [NSSecureTextField new];
	field.frame = NSMakeRect(0, 0, 260, 24);
	[self.window endEditingFor:nil];
	NSString* prefill = _separateSSH.state == NSControlStateValueOn ? [self committedString:_sshPassword]
	                                                                 : [self committedString:_password];
	field.stringValue = prefill ?: @"";
	alert.accessoryView = field;
	[alert addButtonWithTitle:@"Установить"];
	[alert addButtonWithTitle:@"Отмена"];
	__block NSString* typed = @"";
	id changeToken = [[NSNotificationCenter defaultCenter]
	    addObserverForName:NSControlTextDidChangeNotification
	                object:field
	                 queue:[NSOperationQueue mainQueue]
	            usingBlock:^(NSNotification* note) {
		            NSText* editor = note.userInfo[@"NSFieldEditor"];
		            if (editor.string)
			            typed = [editor.string copy];
	            }];
	NSWindow* alertWindow = alert.window;
	NSModalResponse response = [alert runModal];
	[alertWindow makeFirstResponder:nil];
	[field validateEditing];
	[[NSNotificationCenter defaultCenter] removeObserver:changeToken];
	if (response != NSAlertFirstButtonReturn)
		return;
	NSString* password = field.stringValue.length > 0 ? field.stringValue : (typed ?: @"");
	if (password.length == 0)
	{
		[self showError:@"Не заполнено: пароль SSH. Введите его в поле и нажмите «Установить»."];
		return;
	}

	if (!_installWindow)
	{
		_installWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 280)
		                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
		                                               backing:NSBackingStoreBuffered
		                                                 defer:NO];
		_installWindow.title = @"Установка ключа";
		NSScrollView* scroll = [NSTextView scrollableTextView];
		scroll.frame = NSMakeRect(12, 12, 496, 256);
		_installLog = scroll.documentView;
		_installLog.editable = NO;
		_installLog.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
		[_installWindow.contentView addSubview:scroll];
	}
	_installLog.string = @"";
	[_installWindow center];
	[_installWindow makeKeyAndOrderFront:nil];
	[DalnyLog append:[NSString stringWithFormat:@"Устанавливаю ключ на %@@%@:%d", user, host, port]];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError* error = nil;
		BOOL ok = [SSHClient installPublicKey:publicKey
		                                 host:host
		                                 port:port
		                             username:user
		                             password:password
		                              askHost:^BOOL(NSString* fingerprint, BOOL changed) {
			                              return [weakSelf askHostFingerprint:fingerprint changed:changed];
		                              }
		                                  log:^(NSString* line) {
			                                  [DalnyLog append:line];
			                                  dispatch_async(dispatch_get_main_queue(), ^{
				                                  [weakSelf appendInstall:line];
			                                  });
		                              }
		                                error:&error];
		NSString* message = ok ? @"Ключ записан на сервер. Дальше SSH входит этим ключом. Сохраните карточку."
		                       : (error.localizedDescription ?: @"Не получилось установить ключ.");
		dispatch_async(dispatch_get_main_queue(), ^{
			[DalnyLog append:message];
			[weakSelf appendInstall:message];
			ServerEditor* editor = weakSelf;
			if (ok && editor)
				[editor->_sshAuth selectItemAtIndex:0];
			[editor showError:message];
		});
	});
}

- (void)showError:(NSString*)message
{
	NSAlert* alert = [NSAlert new];
	alert.messageText = @"Дальний";
	alert.informativeText = message;
	[alert addButtonWithTitle:@"Хорошо"];
	[alert runModal];
}

- (void)save:(id)sender
{
	[self.window endEditingFor:nil];
	NSString* host = [[self committedString:_host]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString* username = [[self committedString:_username]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString* password = [self committedString:_password];
	NSString* sshPassword = [self committedString:_sshPassword];
	NSString* publicKey = [[self committedString:_publicKey]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	BOOL separateSSH = _separateSSH.state == NSControlStateValueOn;
	BOOL useKey = publicKey.length > 0 && _sshAuth.indexOfSelectedItem == 0;
	BOOL sshOn = _sshEnabled.state == NSControlStateValueOn;
	if (!separateSSH)
		sshPassword = password;
	NSMutableArray<NSString*>* missing = [NSMutableArray array];
	if (host.length == 0)
		[missing addObject:@"адрес"];
	if (username.length == 0)
		[missing addObject:@"пользователь"];
	if (password.length == 0)
		[missing addObject:@"пароль"];
	if (sshOn && !useKey && separateSSH && sshPassword.length == 0)
		[missing addObject:@"пароль SSH"];
	if (missing.count > 0)
	{
		NSString* message = [NSString stringWithFormat:@"Не заполнено: %@.", [missing componentsJoinedByString:@", "]];
		[DalnyLog append:message];
		[self showError:message];
		return;
	}
	NSError* keychainError = nil;
	if (![Keychain setSecret:password account:_server.rdpPasswordAccount error:&keychainError])
	{
		NSString* message = keychainError.localizedDescription ?: @"Пароль не записан в Связку ключей.";
		[DalnyLog append:message];
		[self showError:message];
		return;
	}
	if (sshOn && (!useKey || !separateSSH) &&
	    ![Keychain setSecret:sshPassword account:_server.sshPasswordAccount error:&keychainError])
	{
		NSString* message = keychainError.localizedDescription ?: @"Пароль SSH не записан в Связку ключей.";
		[DalnyLog append:message];
		[self showError:message];
		return;
	}
	NSString* name = [[self committedString:_name]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	_server.name = name.length > 0 ? name : host;
	_server.host = host;
	NSInteger port = [self committedString:_port].integerValue;
	_server.port = port > 0 ? port : 3389;
	_server.username = username;
	_server.graphics = [self profileKey];
	_server.colorDepth = [_server.graphics isEqualToString:@"economy"] ? 16 : 32;
	NSInteger width = [self committedString:_width].integerValue;
	NSInteger height = [self committedString:_height].integerValue;
	_server.width = width >= 200 ? width : 1280;
	_server.height = height >= 200 ? height : 800;
	switch (_display.indexOfSelectedItem)
	{
	case 1:
		_server.displayMode = @"fixed";
		break;
	case 2:
		_server.displayMode = @"fullscreen";
		break;
	default:
		_server.displayMode = @"fit";
		break;
	}
	_server.mapCommandToControl = _mapCommand.state == NSControlStateValueOn;
	_server.autoReconnect = _reconnect.state == NSControlStateValueOn;
	_server.shareClipboard = _clipboard.state == NSControlStateValueOn;
	_server.sshEnabled = _sshEnabled.state == NSControlStateValueOn;
	NSString* sshHost = [[self committedString:_sshHost]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (sshHost.length == 0 || [sshHost isEqualToString:host])
		sshHost = @"";
	_server.sshHost = sshHost;
	NSInteger sshPort = [self committedString:_sshPort].integerValue;
	_server.sshPort = sshPort > 0 ? sshPort : 22;
	NSString* sshUser = [[self committedString:_sshUser]
	    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (sshUser.length == 0 || [sshUser isEqualToString:username])
		sshUser = @"";
	_server.sshUsername = sshUser;
	_server.sshAuth = useKey ? @"key" : @"password";
	_server.sshPublicKey = publicKey;
	[DalnyLog append:[NSString stringWithFormat:@"Сервер «%@» сохранён. Пароль записан в Связку ключей.", host]];
	if (self.onSave)
		self.onSave(_server);
	[self.window close];
}

- (void)cancel:(id)sender
{
	[self.window close];
}

@end
