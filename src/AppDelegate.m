#import "AppDelegate.h"
#import "DalnyLog.h"
#import "Keychain.h"
#import "Updater.h"
#import "ServerEditor.h"
#import "ServerStore.h"
#import "SessionWindow.h"

@implementation AppDelegate
{
	NSWindow* _window;
	NSTableView* _table;
	NSTextField* _empty;
	NSMutableArray<SessionWindow*>* _sessions;
	ServerEditor* _editor;
	NSWindow* _settingsWindow;
	NSSecureTextField* _tokenField;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
	_sessions = [NSMutableArray array];
	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(sessionFinished:)
	                                             name:@"DalnySessionFinished"
	                                           object:nil];
	[self buildMenu];
	[self buildWindow];
	[self reload];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[Updater checkSilently];
	});
}

- (void)buildMenu
{
	NSMenu* main = [NSMenu new];
	NSMenuItem* appItem = [NSMenuItem new];
	NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Дальний"];
	[appMenu addItemWithTitle:@"О программе «Дальний»" action:@selector(showAbout:) keyEquivalent:@""];
	[appMenu addItemWithTitle:@"Настройки…" action:@selector(showSettings:) keyEquivalent:@","];
	[appMenu addItemWithTitle:@"Проверить обновления" action:@selector(checkForUpdates:) keyEquivalent:@""];
	[appMenu addItem:[NSMenuItem separatorItem]];
	[appMenu addItemWithTitle:@"Скрыть Дальний" action:@selector(hide:) keyEquivalent:@"h"];
	[appMenu addItemWithTitle:@"Выйти" action:@selector(terminate:) keyEquivalent:@"q"];
	appItem.submenu = appMenu;
	[main addItem:appItem];

	NSMenuItem* fileItem = [NSMenuItem new];
	NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"Файл"];
	[fileMenu addItemWithTitle:@"Новый сервер" action:@selector(addServer:) keyEquivalent:@"n"];
	[fileMenu addItemWithTitle:@"Импорт сервера…" action:@selector(importServer:) keyEquivalent:@""];
	[fileMenu addItemWithTitle:@"Экспорт сервера…" action:@selector(exportServer:) keyEquivalent:@""];
	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItemWithTitle:@"Подключиться" action:@selector(connect:) keyEquivalent:@"\r"];
	fileItem.submenu = fileMenu;
	[main addItem:fileItem];

	NSMenuItem* editItem = [NSMenuItem new];
	NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Правка"];
	[editMenu addItemWithTitle:@"Копировать" action:@selector(copy:) keyEquivalent:@"c"];
	[editMenu addItemWithTitle:@"Вставить" action:@selector(paste:) keyEquivalent:@"v"];
	[editMenu addItemWithTitle:@"Выбрать всё" action:@selector(selectAll:) keyEquivalent:@"a"];
	editItem.submenu = editMenu;
	[main addItem:editItem];

	NSMenuItem* windowItem = [NSMenuItem new];
	NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Окно"];
	[windowMenu addItemWithTitle:@"Журнал" action:@selector(showJournal:) keyEquivalent:@"l"];
	[windowMenu addItemWithTitle:@"Скопировать журнал" action:@selector(copyJournal:) keyEquivalent:@""];
	[windowMenu addItemWithTitle:@"Минимизировать" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[windowMenu addItemWithTitle:@"Масштаб" action:@selector(performZoom:) keyEquivalent:@""];
	windowItem.submenu = windowMenu;
	[main addItem:windowItem];
	[NSApp setMainMenu:main];
	[NSApp setWindowsMenu:windowMenu];
}

- (void)buildWindow
{
	_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 480)
	                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	                                       backing:NSBackingStoreBuffered
	                                         defer:NO];
	_window.title = @"Дальний";
	_window.minSize = NSMakeSize(560, 320);
	[_window center];

	_table = [NSTableView new];
	_table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
	_table.doubleAction = @selector(connect:);
	_table.target = self;
	NSArray* titles = @[ @"Название", @"Адрес", @"Пользователь", @"Туннель" ];
	NSArray* ids = @[ @"name", @"host", @"user", @"ssh" ];
	for (NSUInteger i = 0; i < titles.count; i++)
	{
		NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:ids[i]];
		column.title = titles[i];
		column.width = i == 0 ? 180 : 150;
		[_table addTableColumn:column];
	}
	_table.dataSource = (id<NSTableViewDataSource>)self;
	_table.delegate = (id<NSTableViewDelegate>)self;
	NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.documentView = _table;
	scroll.hasVerticalScroller = YES;
	scroll.translatesAutoresizingMaskIntoConstraints = NO;

	_empty = [NSTextField wrappingLabelWithString:@"Пока нет серверов. Нажмите «Добавить», впишите адрес и пароль. Список пустой специально: здесь ничего не записано заранее."];
	_empty.translatesAutoresizingMaskIntoConstraints = NO;
	_empty.alignment = NSTextAlignmentCenter;

	NSButton* add = [NSButton buttonWithTitle:@"Добавить" target:self action:@selector(addServer:)];
	NSButton* edit = [NSButton buttonWithTitle:@"Изменить" target:self action:@selector(editServer:)];
	NSButton* remove = [NSButton buttonWithTitle:@"Удалить" target:self action:@selector(deleteServer:)];
	NSButton* connect = [NSButton buttonWithTitle:@"Подключиться" target:self action:@selector(connect:)];
	NSButton* import = [NSButton buttonWithTitle:@"Импорт" target:self action:@selector(importServer:)];
	NSButton* export = [NSButton buttonWithTitle:@"Экспорт" target:self action:@selector(exportServer:)];
	NSStackView* buttons = [NSStackView stackViewWithViews:@[ add, edit, remove, connect, import, export ]];
	buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	buttons.spacing = 8;
	buttons.translatesAutoresizingMaskIntoConstraints = NO;

	NSView* content = _window.contentView;
	[content addSubview:scroll];
	[content addSubview:_empty];
	[content addSubview:buttons];
	[NSLayoutConstraint activateConstraints:@[
		[buttons.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
		[buttons.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
		[scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
		[scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
		[scroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
		[scroll.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-12],
		[_empty.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
		[_empty.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
		[_empty.widthAnchor constraintLessThanOrEqualToAnchor:scroll.widthAnchor constant:-40]
	]];
	[_window makeKeyAndOrderFront:nil];
}

- (void)reload
{
	[_table reloadData];
	_empty.hidden = [ServerStore sharedStore].servers.count > 0;
}

- (DalnyServer*)selectedServer
{
	NSInteger row = _table.selectedRow;
	if (row < 0 || row >= (NSInteger)[ServerStore sharedStore].servers.count)
		return nil;
	return [ServerStore sharedStore].servers[(NSUInteger)row];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
	(void)tableView;
	return (NSInteger)[ServerStore sharedStore].servers.count;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
	(void)tableView;
	DalnyServer* server = [ServerStore sharedStore].servers[(NSUInteger)row];
	if ([column.identifier isEqualToString:@"name"])
		return server.displayTitle;
	if ([column.identifier isEqualToString:@"host"])
		return [NSString stringWithFormat:@"%@:%ld", server.host, (long)server.port];
	if ([column.identifier isEqualToString:@"user"])
		return server.username;
	return server.sshEnabled ? @"SSH" : @"напрямую";
}

- (void)openEditor:(DalnyServer*)server
{
	_editor = [[ServerEditor alloc] initWithServer:server];
	__weak typeof(self) weakSelf = self;
	BOOL exists = [[ServerStore sharedStore] serverWithIdentifier:server.identifier] != nil;
	_editor.onSave = ^(DalnyServer* saved) {
		if (!exists)
			[[ServerStore sharedStore] addServer:saved];
		else
			[[ServerStore sharedStore] save];
		[weakSelf reload];
	};
	[_editor showWindow:nil];
	[_editor.window center];
}

- (void)addServer:(id)sender
{
	[self openEditor:[DalnyServer newServer]];
}

- (void)editServer:(id)sender
{
	DalnyServer* server = [self selectedServer];
	if (!server)
		return;
	[self openEditor:server];
}

- (void)deleteServer:(id)sender
{
	DalnyServer* server = [self selectedServer];
	if (!server)
		return;
	NSAlert* alert = [NSAlert new];
	alert.messageText = @"Удалить сервер?";
	alert.informativeText = @"Пароль и ключ тоже будут стёрты из Связки ключей на этом Маке.";
	[alert addButtonWithTitle:@"Удалить"];
	[alert addButtonWithTitle:@"Отмена"];
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	NSError* keychainError = nil;
	for (NSString* account in @[ server.rdpPasswordAccount, server.sshPasswordAccount, server.sshKeyAccount ])
	{
		if (![Keychain deleteAccount:account error:&keychainError] && keychainError)
			[DalnyLog append:keychainError.localizedDescription];
	}
	[[ServerStore sharedStore] removeServer:server];
	[self reload];
}

- (void)connect:(id)sender
{
	DalnyServer* server = [self selectedServer];
	if (!server)
		return;
	SessionWindow* session = [[SessionWindow alloc] initWithServer:server];
	[_sessions addObject:session];
	[session showWindow:nil];
}

- (void)sessionFinished:(NSNotification*)notification
{
	[_sessions removeObject:notification.object];
}

- (void)exportServer:(id)sender
{
	DalnyServer* server = [self selectedServer];
	if (!server)
		return;
	NSSavePanel* panel = [NSSavePanel savePanel];
	panel.allowedFileTypes = @[ @"json" ];
	panel.nameFieldStringValue = [NSString stringWithFormat:@"%@.dalny.json", server.displayTitle];
	panel.title = @"Экспорт сервера";
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSData* data = [NSJSONSerialization dataWithJSONObject:[server exportDictionary]
	                                               options:NSJSONWritingPrettyPrinted
	                                                 error:NULL];
	[data writeToURL:panel.URL atomically:YES];
}

- (void)importServer:(id)sender
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.allowedFileTypes = @[ @"json" ];
	panel.title = @"Импорт сервера";
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSData* data = [NSData dataWithContentsOfURL:panel.URL];
	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
	NSDictionary* serverJSON = [json isKindOfClass:[NSDictionary class]] ? json[@"server"] : nil;
	if (![json isKindOfClass:[NSDictionary class]] || ![json[@"kind"] isEqualToString:@"dalny-server"] ||
	    ![serverJSON isKindOfClass:[NSDictionary class]])
	{
		NSAlert* alert = [NSAlert new];
		alert.messageText = @"Это не файл сервера Дальний";
		[alert runModal];
		return;
	}
	DalnyServer* server = [DalnyServer serverFromDictionary:serverJSON newIdentity:YES];
	if (!server)
		return;
	[[ServerStore sharedStore] addServer:server];
	[self reload];
	NSAlert* alert = [NSAlert new];
	alert.messageText = @"Сервер добавлен";
	alert.informativeText = @"Пароль и секретный ключ в файле не было. Откройте сервер, введите пароль рабочего стола и, если нужен туннель, создайте свой ключ.";
	[alert runModal];
}

- (void)showAbout:(id)sender
{
	NSDictionary* info = [NSBundle mainBundle].infoDictionary;
	NSAlert* alert = [NSAlert new];
	alert.messageText = @"Дальний";
	alert.informativeText = [NSString stringWithFormat:@"Версия %@ (сборка %@).\n\nКлиент удалённого стола для xrdp. Пароли, ключи и токен GitHub лежат в Связке ключей этого Мака и не записываются в список серверов.",
	                                                   info[@"CFBundleShortVersionString"] ?: @"",
	                                                   info[@"CFBundleVersion"] ?: @""];
	[alert runModal];
}

- (void)showJournal:(id)sender
{
	[DalnyLog showWindow];
}

- (void)copyJournal:(id)sender
{
	NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString:[DalnyLog text] forType:NSPasteboardTypeString];
}

- (void)checkForUpdates:(id)sender
{
	[Updater checkInteractively];
}

- (void)showSettings:(id)sender
{
	if (!_settingsWindow)
	{
		_settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 220)
		                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
		                                               backing:NSBackingStoreBuffered
		                                                 defer:NO];
		_settingsWindow.title = @"Настройки";
		NSTextField* title = [NSTextField labelWithString:@"Токен GitHub, необязательно"];
		_tokenField = [NSSecureTextField new];
		_tokenField.translatesAutoresizingMaskIntoConstraints = NO;
		_tokenField.placeholderString = @"не нужен для публичного репозитория";
		NSTextField* hint = [NSTextField wrappingLabelWithString:@"Обновления chelekov/dalny качаются без токена. Поле нужно только для приватной копии репозитория, если GitHub ограничил число запросов. Токен не пишется в журнал. Пустое поле стирает сохранённый токен."];
		hint.preferredMaxLayoutWidth = 460;
		NSButton* save = [NSButton buttonWithTitle:@"Сохранить" target:self action:@selector(saveToken:)];
		save.keyEquivalent = @"\r";
		NSButton* check = [NSButton buttonWithTitle:@"Проверить обновления" target:self action:@selector(checkForUpdates:)];
		NSStackView* buttons = [NSStackView stackViewWithViews:@[ check, save ]];
		buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
		buttons.spacing = 8;
		NSStackView* stack = [NSStackView stackViewWithViews:@[ title, _tokenField, hint, buttons ]];
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		stack.alignment = NSLayoutAttributeLeading;
		stack.spacing = 8;
		stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		[_tokenField.widthAnchor constraintEqualToConstant:460].active = YES;
		[_settingsWindow.contentView addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.leadingAnchor constraintEqualToAnchor:_settingsWindow.contentView.leadingAnchor],
			[stack.trailingAnchor constraintEqualToAnchor:_settingsWindow.contentView.trailingAnchor],
			[stack.topAnchor constraintEqualToAnchor:_settingsWindow.contentView.topAnchor]
		]];
	}
	NSError* error = nil;
	_tokenField.stringValue = [Keychain secretForAccount:[Updater tokenAccount] error:&error] ?: @"";
	if (error)
		[DalnyLog append:error.localizedDescription];
	[_settingsWindow center];
	[_settingsWindow makeKeyAndOrderFront:nil];
}

- (void)saveToken:(id)sender
{
	[_settingsWindow endEditingFor:nil];
	[_tokenField validateEditing];
	NSString* token = [_tokenField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSError* error = nil;
	BOOL ok = token.length == 0 ? [Keychain deleteAccount:[Updater tokenAccount] error:&error]
	                            : [Keychain setSecret:token account:[Updater tokenAccount] error:&error];
	NSString* message = ok ? (token.length == 0 ? @"Токен удалён из Связки ключей." : @"Токен записан в Связку ключей.")
	                       : (error.localizedDescription ?: @"Связка ключей не приняла токен.");
	[DalnyLog append:message];
	NSAlert* alert = [NSAlert new];
	alert.messageText = ok ? @"Настройки" : @"Не удалось сохранить токен";
	alert.informativeText = message;
	[alert addButtonWithTitle:@"Хорошо"];
	[alert runModal];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag
{
	if (!flag)
		[_window makeKeyAndOrderFront:nil];
	return YES;
}

@end
