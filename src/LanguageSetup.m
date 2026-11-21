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

+ (NSString*)remoteScript
{
	return @"export LC_ALL=C\n"
	        @"uid=$(id -u)\n"
	        @"DISP=''; BUS=''; XA=''; best=-1\n"
	        @"# Find the user's X display: xrdp sessions use :10 and up. Prefer a process that also\n"
	        @"# knows the session D-Bus (xfconf needs it).\n"
	        @"for p in $(pgrep -u \"$uid\" 2>/dev/null); do\n"
	        @"  [ -r \"/proc/$p/environ\" ] || continue\n"
	        @"  env=$( { tr '\\000' '\\n' < \"/proc/$p/environ\"; } 2>/dev/null) || continue\n"
	        @"  d=$(printf '%s\\n' \"$env\" | sed -n 's/^DISPLAY=//p' | head -n 1)\n"
	        @"  case \"$d\" in :*) ;; *) continue ;; esac\n"
	        @"  n=${d#:}; n=${n%%.*}\n"
	        @"  case \"$n\" in ''|*[!0-9]*) continue ;; esac\n"
	        @"  b=$(printf '%s\\n' \"$env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n 1)\n"
	        @"  score=$n\n"
	        @"  [ -n \"$b\" ] && score=$((score + 1000))\n"
	        @"  [ \"$n\" -ge 10 ] && score=$((score + 100000))\n"
	        @"  if [ \"$score\" -gt \"$best\" ]; then\n"
	        @"    best=$score; DISP=$d; BUS=$b\n"
	        @"    XA=$(printf '%s\\n' \"$env\" | sed -n 's/^XAUTHORITY=//p' | head -n 1)\n"
	        @"  fi\n"
	        @"done\n"
	        @"echo \"DALNY_DISPLAY=${DISP:-none}\"\n"
	        @"xf=skip\n"
	        @"if command -v xfconf-query >/dev/null 2>&1; then\n"
	        @"  xq() { if [ -n \"$BUS\" ]; then DBUS_SESSION_BUS_ADDRESS=\"$BUS\" xfconf-query \"$@\"; else xfconf-query \"$@\"; fi; }\n"
	        @"  setp() { xq -c keyboard-layout -p \"$1\" -n -t \"$2\" -s \"$3\" 2>/dev/null || xq -c keyboard-layout -p \"$1\" -s \"$3\"; }\n"
	        @"  if [ -n \"$BUS\" ] || pgrep -u \"$uid\" -x xfconfd >/dev/null 2>&1; then\n"
	        @"    if setp /Default/XkbDisable bool false && setp /Default/XkbLayout string us,ru &&\n"
	        @"       setp /Default/XkbVariant string , && setp /Default/XkbOptions/Group string grp:alt_shift_toggle; then\n"
	        @"      xf=ok\n"
	        @"    else\n"
	        @"      xf=fail\n"
	        @"    fi\n"
	        @"  else\n"
	        @"    # No running XFCE session: write the channel file, xfconfd reads it at the next login.\n"
	        @"    f=\"$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/keyboard-layout.xml\"\n"
	        @"    mkdir -p \"${f%/*}\"\n"
	        @"    [ -f \"$f\" ] && cp -p \"$f\" \"$f.dalny-backup\"\n"
	        @"    cat > \"$f\" <<'XML'\n"
	        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	        @"<channel name=\"keyboard-layout\" version=\"1.0\">\n"
	        @"  <property name=\"Default\" type=\"empty\">\n"
	        @"    <property name=\"XkbDisable\" type=\"bool\" value=\"false\"/>\n"
	        @"    <property name=\"XkbLayout\" type=\"string\" value=\"us,ru\"/>\n"
	        @"    <property name=\"XkbVariant\" type=\"string\" value=\",\"/>\n"
	        @"    <property name=\"XkbOptions\" type=\"empty\">\n"
	        @"      <property name=\"Group\" type=\"string\" value=\"grp:alt_shift_toggle\"/>\n"
	        @"    </property>\n"
	        @"  </property>\n"
	        @"</channel>\n"
	        @"XML\n"
	        @"    xf=file\n"
	        @"  fi\n"
	        @"fi\n"
	        @"sx=missing\n"
	        @"if command -v setxkbmap >/dev/null 2>&1; then\n"
	        @"  if [ -z \"$DISP\" ]; then\n"
	        @"    sx=nodisplay\n"
	        @"  elif DISPLAY=\"$DISP\" XAUTHORITY=\"${XA:-$HOME/.Xauthority}\" setxkbmap -layout us,ru -variant , -option grp:alt_shift_toggle; then\n"
	        @"    sx=ok\n"
	        @"  else\n"
	        @"    sx=fail\n"
	        @"  fi\n"
	        @"fi\n"
	        @"echo \"DALNY_XFCONF=$xf\"\n"
	        @"echo \"DALNY_SETXKBMAP=$sx\"\n";
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
		[alert addButtonWithTitle:@"Доверять"];
		[alert addButtonWithTitle:@"Отмена"];
		trusted = [alert runModal] == NSAlertFirstButtonReturn;
	});
	return trusted;
}

+ (void)runForServer:(DalnyServer*)server
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
		log(@"Настраиваю переключение языка на сервере (от имени пользователя, без прав root)…");
		NSError* error = nil;
		NSString* output = [SSHClient runScript:[self remoteScript]
		                                   host:host
		                                   port:port
		                               username:user
		                                 keyPEM:key
		                               password:password
		                                askHost:^BOOL(NSString* fingerprint, BOOL changed) {
			                                return [self askHost:fingerprint changed:changed];
		                                }
		                                    log:log
		                                  error:&error];
		if (!output)
		{
			NSString* why = error.localizedDescription ?: @"Команда SSH не выполнилась.";
			log(why);
			finish(NO, @"Не удалось настроить язык", why);
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
		BOOL saved = [xf isEqualToString:@"ok"] || [xf isEqualToString:@"file"];
		BOOL live = [sx isEqualToString:@"ok"];
		NSString* keys = @"Язык переключается ⌥ Option + ⇧ Shift или кнопкой RU/EN в окне сеанса.";
		if (saved && live)
			finish(YES, @"Переключение языка настроено",
			       [NSString stringWithFormat:@"Раскладки us и ru включены в настройках XFCE и в текущем сеансе. %@", keys]);
		else if (saved)
			finish(YES, @"Переключение языка сохранено",
			       [NSString stringWithFormat:@"Настройка записана в XFCE. Открытого сеанса не нашлось, поэтому она заработает после переподключения. %@", keys]);
		else if (live && [xf isEqualToString:@"skip"])
			finish(YES, @"Язык включён в текущем сеансе",
			       [NSString stringWithFormat:@"На сервере не XFCE (нет xfconf-query), поэтому после нового входа настройка может пропасть. Как сохранить её навсегда — в README, раздел «Клавиатура». %@", keys]);
		else if (live)
			finish(NO, @"Язык включён только в текущем сеансе",
			       [NSString stringWithFormat:@"setxkbmap сработал, а настройки XFCE не записались. Подробности — в журнале. %@", keys]);
		else
		{
			NSString* why = [sx isEqualToString:@"missing"] ? @"на сервере нет setxkbmap"
			              : ([sx isEqualToString:@"nodisplay"] ? @"не найден открытый сеанс xrdp" : @"команда не сработала");
			finish(NO, @"Не удалось настроить язык",
			       [NSString stringWithFormat:@"Причина: %@. Подробности — в журнале. Вручную в терминале сеанса:\n\n%@", why,
			                                  kManualCommand]);
		}
	});
}

+ (void)runInteractiveForServer:(DalnyServer*)server window:(NSWindow*)window log:(void (^)(NSString* line))log
{
	__weak NSWindow* weakWindow = window;
	[self runForServer:server
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
