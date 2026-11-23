#import "LanguageSetup.h"
#import "DalnyLog.h"
#import "Keychain.h"
#import "SSHClient.h"

static NSString* const kManualCommand =
    @"xfconf-query -c keyboard-layout -p /Default/XkbDisable -n -t bool -s false\n"
    @"xfconf-query -c keyboard-layout -p /Default/XkbLayout -n -t string -s us,ru\n"
    @"xfconf-query -c keyboard-layout -p /Default/XkbVariant -n -t string -s ,\n"
    @"xfconf-query -c keyboard-layout -p /Default/XkbOptions/Group -n -t string -s grp:alt_shift_toggle\n"
    @"setxkbmap -layout us,ru -variant , -option grp:alt_shift_toggle";

@implementation LanguageSetup

+ (nullable NSString*)resource:(NSString*)name
{
	NSString* path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
	                                                           [@"server" stringByAppendingPathComponent:name]];
	NSData* data = [NSData dataWithContentsOfFile:path];
	return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

+ (nullable NSString*)remoteScript
{
	NSString* setup = [self resource:@"setup.sh"];
	NSString* keyboard = [self resource:@"dalny-keyboard"];
	NSString* clipboard = [self resource:@"dalny-clipboard"];
	if (!setup || !keyboard || !clipboard)
		return nil;
	/* base64 has no quotes, so single quotes are safe. */
	NSString* kb = [[keyboard dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
	NSString* cb = [[clipboard dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
	return [NSString stringWithFormat:@"DALNY_KB_B64='%@'\nDALNY_CB_B64='%@'\n%@", kb, cb, setup];
}

+ (NSString*)valueFor:(NSString*)key inOutput:(NSString*)output
{
	NSString* prefix = [key stringByAppendingString:@"="];
	for (NSString* line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
	{
		NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([trimmed hasPrefix:prefix])
			return [trimmed substringFromIndex:prefix.length];
	}
	return @"";
}

+ (BOOL)askHost:(NSString*)fingerprint changed:(BOOL)changed
{
	__block BOOL trusted = NO;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSAlert* alert = [NSAlert new];
		alert.messageText = changed ? @"Ключ SSH-сервера изменился" : @"Подтвердите сервер SSH";
		alert.informativeText = changed
		    ? [NSString stringWithFormat:@"Это может быть другой компьютер. Новый отпечаток:\n%@", fingerprint]
		    : [NSString stringWithFormat:@"Первое подключение. Отпечаток:\n%@", fingerprint];
		alert.alertStyle = changed ? NSAlertStyleCritical : NSAlertStyleWarning;
		if (changed)
		{
			/* Enter must not accept a changed key: Cancel is the default, replacing is a deliberate click. */
			[alert addButtonWithTitle:@"Отмена"];
			[alert addButtonWithTitle:@"Заменить ключ"].keyEquivalent = @"";
			trusted = [alert runModal] == NSAlertSecondButtonReturn;
		}
		else
		{
			[alert addButtonWithTitle:@"Доверять"];
			[alert addButtonWithTitle:@"Отмена"];
			trusted = [alert runModal] == NSAlertFirstButtonReturn;
		}
	});
	return trusted;
}

+ (void)runForServer:(DalnyServer*)server
               quiet:(BOOL)quiet
                 log:(void (^)(NSString* line))log
                done:(void (^)(BOOL ok, NSString* title, NSString* detail))done
{
	void (^finish)(BOOL, NSString*, NSString*) = ^(BOOL ok, NSString* title, NSString* detail) {
		dispatch_async(dispatch_get_main_queue(), ^{
			done(ok, title, detail);
		});
	};
	if (!server.sshEnabled)
	{
		finish(NO, @"Нужен SSH",
		       [NSString stringWithFormat:@"Для этого сервера SSH выключен. Включите SSH в настройках сервера или выполните на сервере в терминале сеанса:\n\n%@",
		                                  kManualCommand]);
		return;
	}
	NSString* script = [self remoteScript];
	if (!script)
	{
		finish(NO, @"Не удалось настроить сервер", @"В программе нет файлов настройки сервера (Contents/Resources/server). Переустановите Дальний.");
		return;
	}
	NSString* host = server.effectiveSSHHost;
	int port = (int)server.sshPort;
	NSString* user = server.sshUsername.length ? server.sshUsername : server.username;
	BOOL passwordAuth = [server.sshAuth isEqualToString:@"password"];
	NSString* passwordAccount = server.sshPasswordAccount;
	NSString* keyAccount = server.sshKeyAccount;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError* secretError = nil;
		NSString* key = passwordAuth ? nil : [Keychain secretForAccount:keyAccount error:&secretError];
		NSString* password = passwordAuth ? [Keychain secretForAccount:passwordAccount error:&secretError] : nil;
		if (key.length == 0 && password.length == 0)
		{
			finish(NO, @"Нет данных для входа по SSH",
			       secretError.localizedDescription ?: @"В Связке ключей нет пароля или ключа SSH для этого сервера.");
			return;
		}
		log(quiet ? @"Проверяю настройку сервера (язык, буфер обмена)…"
		          : @"Настраиваю сервер: язык и картинки в буфере обмена (от имени пользователя, без прав root)…");
		NSError* error = nil;
		NSString* output = [SSHClient runScript:script
		                                   host:host
		                                   port:port
		                               username:user
		                                 keyPEM:key
		                               password:password
		                                askHost:^BOOL(NSString* fingerprint, BOOL changed) {
			                                return quiet ? NO : [self askHost:fingerprint changed:changed];
		                                }
		                                    log:log
		                                  error:&error];
		if (!output)
		{
			NSString* why = error.localizedDescription ?: @"Команда SSH не выполнилась.";
			log(why);
			finish(NO, @"Не удалось настроить сервер", why);
			return;
		}
		for (NSString* line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
		{
			NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			if (trimmed.length)
				log([@"сервер: " stringByAppendingString:trimmed]);
		}
		NSString* xf = [self valueFor:@"DALNY_XFCONF" inOutput:output];
		NSString* sx = [self valueFor:@"DALNY_SETXKBMAP" inOutput:output];
		NSString* ib = [self valueFor:@"DALNY_IBUS" inOutput:output];
		NSString* pn = [self valueFor:@"DALNY_PANEL" inOutput:output];
		NSString* cb = [self valueFor:@"DALNY_CLIPBOARD" inOutput:output];
		BOOL saved = [xf isEqualToString:@"ok"] || [xf isEqualToString:@"file"];
		BOOL live = [sx isEqualToString:@"ok"];
		NSMutableArray<NSString*>* notes = [NSMutableArray array];
		if ([ib isEqualToString:@"ok"])
			[notes addObject:@"ibus больше не меняет раскладку сам."];
		else if ([ib isEqualToString:@"fail"])
			[notes addObject:@"Настройки ibus не записались — он может снова сбивать раскладку."];
		if ([pn isEqualToString:@"added"])
			[notes addObject:@"На панель XFCE рядом с треем добавлен индикатор раскладки (us/ru); значок ibus скрыт."];
		else if ([pn isEqualToString:@"nopanel"])
			[notes addObject:@"Индикатор раскладки добавлен, но панель XFCE не перезапустилась — он появится после нового входа."];
		if ([cb isEqualToString:@"ok"])
			[notes addObject:@"Картинки из буфера Мака теперь вставляются и в приложения на Chromium/Electron."];
		else if ([cb isEqualToString:@"nogtk"])
			[notes addObject:@"Помощник для картинок не установлен: на сервере нет python3 с GTK 3 (пакет python3-gi). Картинки вставятся в приложения, понимающие image/bmp."];
		else if ([cb isEqualToString:@"fail"])
			[notes addObject:@"Помощник для картинок не установился, подробности в журнале."];
		NSString* extra = notes.count ? [@"\n\n" stringByAppendingString:[notes componentsJoinedByString:@"\n"]] : @"";
		NSString* keys = @"Язык переключается ⌥ Option + ⇧ Shift или кнопкой RU/EN в окне сеанса. После переподключения раскладка восстанавливается сама за 2 секунды, язык — английский.";
		if (saved && live)
			finish(YES, @"Сервер настроен",
			       [NSString stringWithFormat:@"Раскладки us и ru включены в XFCE, в текущем сеансе и после каждого переподключения. %@%@", keys, extra]);
		else if (saved)
			finish(YES, @"Настройка сохранена",
			       [NSString stringWithFormat:@"Настройка записана. Открытого сеанса не нашлось, поэтому она заработает после входа. %@%@", keys, extra]);
		else if (live && [xf isEqualToString:@"skip"])
			finish(YES, @"Язык включён",
			       [NSString stringWithFormat:@"На сервере не XFCE (нет xfconf-query); раскладку держит помощник из автозапуска. %@%@", keys, extra]);
		else if (live)
			finish(NO, @"Язык включён только в текущем сеансе",
			       [NSString stringWithFormat:@"setxkbmap сработал, а настройки XFCE не записались. Подробности — в журнале. %@%@", keys, extra]);
		else
		{
			NSString* why = [sx isEqualToString:@"missing"] ? @"на сервере нет setxkbmap"
			              : ([sx isEqualToString:@"nodisplay"] ? @"не найден открытый сеанс xrdp" : @"команда не сработала");
			finish(NO, @"Не удалось настроить язык",
			       [NSString stringWithFormat:@"Причина: %@. Подробности — в журнале. Вручную в терминале сеанса:\n\n%@%@", why,
			                                  kManualCommand, extra]);
		}
	});
}

+ (void)ensureForServer:(DalnyServer*)server log:(void (^)(NSString* line))log
{
	[self runForServer:server
	             quiet:YES
	               log:log
	              done:^(BOOL ok, NSString* title, NSString* detail) {
		              (void)detail;
		              log(ok ? @"Настройка сервера на месте (раскладка us,ru и Alt+Shift, картинки в буфере)."
		                     : [NSString stringWithFormat:@"Проверка настройки сервера: %@.", title]);
	              }];
}

+ (void)runInteractiveForServer:(DalnyServer*)server window:(NSWindow*)window log:(void (^)(NSString* line))log
{
	__weak NSWindow* weakWindow = window;
	[self runForServer:server
	             quiet:NO
	               log:log
	              done:^(BOOL ok, NSString* title, NSString* detail) {
		              log([NSString stringWithFormat:@"%@. %@", title, detail]);
		              NSAlert* alert = [NSAlert new];
		              alert.messageText = title;
		              alert.informativeText = detail;
		              alert.alertStyle = ok ? NSAlertStyleInformational : NSAlertStyleWarning;
		              [alert addButtonWithTitle:@"Хорошо"];
		              NSWindow* target = weakWindow;
		              if (target && target.visible && !target.attachedSheet)
			              [alert beginSheetModalForWindow:target completionHandler:nil];
		              else
			              [alert runModal];
	              }];
}

@end
