#import "SSHClient.h"
#import "Server.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <signal.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString* const kSSHErrorDomain = @"app.dalny.client.ssh";

static NSError* SSHError(NSInteger code, NSString* message)
{
	return [NSError errorWithDomain:kSSHErrorDomain
	                           code:code
	                       userInfo:@{NSLocalizedDescriptionKey : message ?: @"Ошибка SSH"}];
}

/* Last line of defence: nothing that ssh could read as an option reaches its argv. */
static BOOL SSHCheckTarget(NSString* host, int port, NSString* username, NSError** error)
{
	if ([DalnyServer isSafeHost:host] && [DalnyServer isValidPort:port] &&
	    (username == nil || [DalnyServer isSafeUsername:username]))
		return YES;
	if (error)
		*error = SSHError(5, @"Недопустимый адрес, пользователь или порт SSH. Откройте сервер и исправьте поля.");
	return NO;
}

static NSString* SSHQuotedOption(NSString* name, NSString* path)
{
	NSString* escaped = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
	escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
	return [NSString stringWithFormat:@"%@=\"%@\"", name, escaped];
}

static NSString* SSHFailureMessage(NSString* stderrText, int exitCode, NSString* fallback)
{
	NSString* text = [stderrText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
	if (text.length > 700)
		text = [text substringFromIndex:text.length - 700];
	BOOL hostKey = [text rangeOfString:@"host key" options:NSCaseInsensitiveSearch].location != NSNotFound ||
	               [text rangeOfString:@"strict checking" options:NSCaseInsensitiveSearch].location != NSNotFound ||
	               [text rangeOfString:@"known_hosts" options:NSCaseInsensitiveSearch].location != NSNotFound;
	BOOL denied = [text rangeOfString:@"Permission denied" options:NSCaseInsensitiveSearch].location != NSNotFound;
	NSString* lead = fallback ?: @"Команда SSH завершилась с ошибкой.";
	if (hostKey)
		lead = @"Проверка ключа сервера SSH не прошла. Это не отказ в пароле.";
	else if (denied)
		lead = @"Сервер SSH не принял пароль.";
	if (exitCode >= 0 && text.length > 0)
		return [NSString stringWithFormat:@"%@ (код %d)\n%@", lead, exitCode, text];
	if (exitCode >= 0)
		return [NSString stringWithFormat:@"%@ (код %d)", lead, exitCode];
	if (text.length > 0)
		return [NSString stringWithFormat:@"%@\n%@", lead, text];
	return lead;
}

@implementation SSHClient
{
	pid_t _pid;
	NSString* _secretPath;
	NSString* _keyPath;
	NSMutableString* _stderrText;
	BOOL _captureStdout;
	/* Tunnel stderr stays open after the tunnel is up: ssh must not hit a closed pipe, and its
	 * "Timeout, server not responding" lines go to the log. */
	int _tunnelStderr;
	void (^_tunnelLog)(NSString*);
}

+ (NSURL*)supportFolder
{
	NSFileManager* files = [NSFileManager defaultManager];
	NSURL* base = [[files URLsForDirectory:NSApplicationSupportDirectory
	                             inDomains:NSUserDomainMask] firstObject];
	NSURL* folder = [base URLByAppendingPathComponent:@"Dalny" isDirectory:YES];
	[files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	return folder;
}

+ (NSURL*)knownHostsURL
{
	return [[self supportFolder] URLByAppendingPathComponent:@"known_hosts"];
}

+ (NSString*)runTool:(NSString*)path
            arguments:(NSArray<NSString*>*)arguments
                stdin:(nullable NSString*)stdinText
             timedOut:(BOOL*)timedOut
                error:(NSError**)error
{
	if (timedOut)
		*timedOut = NO;
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:path];
	task.arguments = arguments;
	NSPipe* output = [NSPipe pipe];
	NSPipe* errors = [NSPipe pipe];
	task.standardOutput = output;
	task.standardError = errors;
	if (stdinText)
	{
		NSPipe* input = [NSPipe pipe];
		task.standardInput = input;
		NSError* launchError = nil;
		if (![task launchAndReturnError:&launchError])
		{
			if (error)
				*error = launchError;
			return nil;
		}
		NSData* data = [stdinText dataUsingEncoding:NSUTF8StringEncoding];
		[[input fileHandleForWriting] writeData:data];
		[[input fileHandleForWriting] closeFile];
	}
	else if (![task launchAndReturnError:error])
	{
		return nil;
	}

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[task waitUntilExit];
		dispatch_semaphore_signal(done);
	});
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0)
	{
		[task terminate];
		if (timedOut)
			*timedOut = YES;
		if (error)
			*error = SSHError(3, @"Сервер SSH не ответил за 20 секунд.");
		return nil;
	}
	NSData* outData = [[output fileHandleForReading] readDataToEndOfFile];
	NSData* errData = [[errors fileHandleForReading] readDataToEndOfFile];
	NSString* text = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
	NSString* errText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
	if (task.terminationStatus != 0 && text.length == 0)
	{
		if (error)
			*error = SSHError(3, errText.length ? errText : @"Команда SSH завершилась с ошибкой.");
		return nil;
	}
	if (errText.length && text.length == 0)
		return errText;
	return text;
}

+ (NSArray<NSString*>*)hostKeyLinesFromScan:(NSString*)scan host:(NSString*)host port:(int)port
{
	NSString* token = [self hostToken:host port:port];
	NSMutableArray<NSString*>* lines = [NSMutableArray array];
	NSMutableSet<NSString*>* seen = [NSMutableSet set];
	for (NSString* raw in [scan componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
	{
		NSString* line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (line.length == 0 || [line hasPrefix:@"#"])
			continue;
		NSMutableArray<NSString*>* fields = [NSMutableArray array];
		for (NSString* part in [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])
		{
			if (part.length > 0)
				[fields addObject:part];
		}
		if (fields.count < 3)
			continue;
		NSString* type = fields[1];
		if (![type isEqualToString:@"ssh-ed25519"] && ![type isEqualToString:@"ssh-rsa"] &&
		    ![type hasPrefix:@"ecdsa-sha2-"])
			continue;
		NSString* stored = [NSString stringWithFormat:@"%@ %@ %@", token, type, fields[2]];
		if ([seen containsObject:stored])
			continue;
		[seen addObject:stored];
		[lines addObject:stored];
	}
	[lines sortUsingComparator:^NSComparisonResult(NSString* left, NSString* right) {
		BOOL leftEd = [left containsString:@" ssh-ed25519 "];
		BOOL rightEd = [right containsString:@" ssh-ed25519 "];
		if (leftEd == rightEd)
			return NSOrderedSame;
		return leftEd ? NSOrderedAscending : NSOrderedDescending;
	}];
	return lines;
}

/* Fingerprint of the key we already trust for this host, preferring the same key type as `line`. */
+ (nullable NSString*)storedFingerprintForHost:(NSString*)host port:(int)port likeLine:(NSString*)line
{
	NSString* token = [[self hostToken:host port:port] stringByAppendingString:@" "];
	NSString* bare = [host stringByAppendingString:@" "];
	NSArray<NSString*>* parts = [line componentsSeparatedByString:@" "];
	NSString* type = parts.count > 1 ? parts[1] : @"";
	NSString* pick = nil;
	for (NSString* known in [self knownLines])
	{
		if (![known hasPrefix:token] && ![known hasPrefix:bare])
			continue;
		if (!pick)
			pick = known;
		if (type.length && [known containsString:[NSString stringWithFormat:@" %@ ", type]])
		{
			pick = known;
			break;
		}
	}
	return pick ? [self fingerprintForLine:pick error:NULL] : nil;
}

+ (NSString*)fingerprintForLine:(NSString*)line error:(NSError**)error
{
	BOOL timedOut = NO;
	NSString* output = [self runTool:@"/usr/bin/ssh-keygen"
	                       arguments:@[ @"-lf", @"-" ]
	                           stdin:[line stringByAppendingString:@"\n"]
	                        timedOut:&timedOut
	                           error:error];
	if (output.length == 0)
		return nil;
	NSRange range = [output rangeOfString:@"SHA256:"];
	if (range.location == NSNotFound)
	{
		if (error)
			*error = SSHError(3, @"Не удалось прочитать отпечаток ключа сервера.");
		return nil;
	}
	NSString* tail = [output substringFromIndex:range.location];
	NSRange space = [tail rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (space.location != NSNotFound)
		tail = [tail substringToIndex:space.location];
	return tail;
}

+ (NSString*)hostToken:(NSString*)host port:(int)port
{
	if (port == 22)
		return host;
	return [NSString stringWithFormat:@"[%@]:%d", host, port];
}

+ (NSArray<NSString*>*)knownLines
{
	NSString* text = [NSString stringWithContentsOfURL:[self knownHostsURL] encoding:NSUTF8StringEncoding error:NULL];
	if (text.length == 0)
		return @[];
	return [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

+ (BOOL)knownHostsContainsHost:(NSString*)host port:(int)port
{
	NSString* path = [self knownHostsURL].path;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path])
		return NO;
	BOOL timedOut = NO;
	NSString* found = [self runTool:@"/usr/bin/ssh-keygen"
	                     arguments:@[ @"-F", [self hostToken:host port:port], @"-f", path ]
	                         stdin:nil
	                      timedOut:&timedOut
	                         error:NULL];
	if (found.length == 0)
		return NO;
	return [found rangeOfString:@" ssh-ed25519 "].location != NSNotFound ||
	       [found rangeOfString:@" ssh-rsa "].location != NSNotFound ||
	       [found rangeOfString:@" ecdsa-sha2-"].location != NSNotFound;
}

+ (BOOL)rememberHostKeyLines:(NSArray<NSString*>*)newLines host:(NSString*)host port:(int)port error:(NSError**)error
{
	if (newLines.count == 0)
		return NO;
	NSString* token = [self hostToken:host port:port];
	NSString* bare = [host stringByAppendingString:@" "];
	NSMutableArray* kept = [NSMutableArray array];
	for (NSString* existing in [self knownLines])
	{
		if (existing.length == 0)
			continue;
		if ([existing hasPrefix:[token stringByAppendingString:@" "]] || [existing hasPrefix:bare])
			continue;
		[kept addObject:existing];
	}
	[kept addObjectsFromArray:newLines];
	NSString* text = [[kept componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
	NSError* writeError = nil;
	BOOL ok = [text writeToURL:[self knownHostsURL] atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
	if (!ok && error)
		*error = writeError ?: SSHError(3, @"Не удалось записать файл ключей SSH.");
	if (ok)
		chmod([self knownHostsURL].path.fileSystemRepresentation, 0600);
	return ok;
}

+ (void)forgetHost:(NSString*)host port:(int)port
{
	NSString* token = [self hostToken:host port:port];
	NSMutableArray* kept = [NSMutableArray array];
	for (NSString* line in [self knownLines])
	{
		if (line.length == 0)
			continue;
		if ([line hasPrefix:[token stringByAppendingString:@" "]] ||
		    [line hasPrefix:[host stringByAppendingString:@" "]])
			continue;
		[kept addObject:line];
	}
	NSString* text = kept.count ? [[kept componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
	[text writeToURL:[self knownHostsURL] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

+ (BOOL)confirmHost:(NSString*)host
               port:(int)port
            changed:(BOOL)changed
            askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
                log:(void (^)(NSString* line))log
              error:(NSError**)error
{
	if (!SSHCheckTarget(host, port, nil, error))
		return NO;
	if (!changed && [self knownHostsContainsHost:host port:port])
		return YES;
	if (log)
		log(@"Проверяю ключ сервера SSH…");
	BOOL timedOut = NO;
	NSString* portString = [NSString stringWithFormat:@"%d", port];
	NSString* scan = [self runTool:@"/usr/bin/ssh-keyscan"
	                     arguments:@[ @"-T", @"12", @"-p", portString, @"-t", @"ed25519,ecdsa,rsa", @"--", host ]
	                         stdin:nil
	                      timedOut:&timedOut
	                         error:error];
	NSArray<NSString*>* lines = [self hostKeyLinesFromScan:scan ?: @"" host:host port:port];
	if (lines.count == 0)
	{
		if (error && !*error)
		{
			NSString* why = timedOut ? @"Сервер SSH не ответил." : @"Не удалось получить ключ сервера SSH.";
			NSString* detail = [scan stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (detail.length > 400)
				detail = [detail substringFromIndex:detail.length - 400];
			if (detail.length > 0)
				why = [NSString stringWithFormat:@"%@\n%@", why, detail];
			*error = SSHError(3, why);
		}
		return NO;
	}
	NSString* fingerprint = [self fingerprintForLine:lines.firstObject error:error];
	if (!fingerprint)
		return NO;
	NSString* shown = fingerprint;
	if (changed)
	{
		NSString* old = [self storedFingerprintForHost:host port:port likeLine:lines.firstObject];
		if (old.length > 0)
			shown = [NSString stringWithFormat:@"%@\n\nБыл раньше:\n%@", fingerprint, old];
		if (log)
			log([NSString stringWithFormat:@"Новый отпечаток SSH: %@; прежний: %@", fingerprint,
			                               old.length ? old : @"не найден"]);
	}
	BOOL trust = askHost ? askHost(shown, changed) : NO;
	if (!trust)
	{
		if (error)
			*error = SSHError(2, @"Ключ сервера SSH не подтверждён.");
		return NO;
	}
	if (![self rememberHostKeyLines:lines host:host port:port error:error])
		return NO;
	if (![self knownHostsContainsHost:host port:port])
	{
		if (error)
			*error = SSHError(3, [NSString stringWithFormat:@"Ключ сервера записан, но ssh-keygen его не видит: %@",
			                                                [self knownHostsURL].path]);
		return NO;
	}
	if (log)
		log([NSString stringWithFormat:@"Ключ сервера записан в %@", [self knownHostsURL].path]);
	return YES;
}

+ (BOOL)generateEd25519PublicKey:(NSString**)publicKey
                      privateKey:(NSString**)privateKey
                           error:(NSError**)error
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory
	                          withIntermediateDirectories:YES
	                                           attributes:@{NSFilePosixPermissions : @0700}
	                                                error:NULL];
	NSString* keyPath = [directory stringByAppendingPathComponent:@"id_ed25519"];
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh-keygen"];
	task.arguments = @[ @"-q", @"-t", @"ed25519", @"-f", keyPath, @"-N", @"", @"-C", @"dalny" ];
	NSError* launchError = nil;
	if (![task launchAndReturnError:&launchError])
	{
		if (error)
			*error = launchError;
		return NO;
	}
	[task waitUntilExit];
	if (task.terminationStatus != 0)
	{
		if (error)
			*error = SSHError(1, @"Не удалось создать ключ SSH.");
		return NO;
	}
	NSString* priv = [NSString stringWithContentsOfFile:keyPath encoding:NSUTF8StringEncoding error:error];
	NSString* pub = [NSString stringWithContentsOfFile:[keyPath stringByAppendingString:@".pub"]
	                                          encoding:NSUTF8StringEncoding
	                                             error:error];
	[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
	if (priv.length == 0 || pub.length == 0)
		return NO;
	if (publicKey)
		*publicKey = [pub stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (privateKey)
		*privateKey = priv;
	return YES;
}

+ (BOOL)validPublicKey:(NSString*)publicKey
{
	if (publicKey.length == 0 || [publicKey containsString:@"'"] || [publicKey containsString:@"\n"])
		return NO;
	return [publicKey hasPrefix:@"ssh-ed25519 "] || [publicKey hasPrefix:@"ssh-rsa "] ||
	       [publicKey hasPrefix:@"ecdsa-sha2-"];
}

+ (NSString*)askpassPath
{
	return [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"DalnyAskpass"];
}

- (void)cleanupFiles
{
	if (_secretPath)
	{
		[[NSFileManager defaultManager] removeItemAtPath:_secretPath error:NULL];
		_secretPath = nil;
	}
	if (_keyPath)
	{
		[[NSFileManager defaultManager] removeItemAtPath:[_keyPath stringByDeletingLastPathComponent] error:NULL];
		_keyPath = nil;
	}
}

- (BOOL)checkAlive
{
	@synchronized(self)
	{
		if (_tunnelStderr > 0)
			[self consumeStderr:_tunnelStderr log:_tunnelLog];
		if (_pid <= 0)
			return NO;
		int status = 0;
		pid_t result = waitpid(_pid, &status, WNOHANG);
		if (result == _pid || (result < 0 && errno == ECHILD))
		{
			if (_tunnelStderr > 0)
				[self consumeStderr:_tunnelStderr log:_tunnelLog];
			_pid = 0;
			_running = NO;
			return NO;
		}
		return YES;
	}
}

- (void)stop
{
	@synchronized(self)
	{
		[self stopLocked];
	}
}

- (void)stopLocked
{
	if (_tunnelStderr > 0)
	{
		close(_tunnelStderr);
		_tunnelStderr = 0;
	}
	_tunnelLog = nil;
	if (_pid > 0)
	{
		kill(-_pid, SIGTERM);
		usleep(200000);
		kill(-_pid, SIGKILL);
		int status = 0;
		waitpid(_pid, &status, WNOHANG);
		_pid = 0;
	}
	_running = NO;
	[self cleanupFiles];
}

- (BOOL)writeSecret:(NSString*)secret error:(NSError**)error
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory
	                          withIntermediateDirectories:YES
	                                           attributes:@{NSFilePosixPermissions : @0700}
	                                                error:NULL];
	_secretPath = [directory stringByAppendingPathComponent:@"askpass"];
	NSError* writeError = nil;
	BOOL ok = [secret writeToFile:_secretPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
	if (ok)
		chmod(_secretPath.fileSystemRepresentation, 0600);
	else if (error)
		*error = writeError;
	return ok;
}

- (BOOL)writeKey:(NSString*)pem error:(NSError**)error
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory
	                          withIntermediateDirectories:YES
	                                           attributes:@{NSFilePosixPermissions : @0700}
	                                                error:NULL];
	_keyPath = [directory stringByAppendingPathComponent:@"id_ed25519"];
	NSError* writeError = nil;
	BOOL ok = [pem writeToFile:_keyPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
	if (ok)
		chmod(_keyPath.fileSystemRepresentation, 0600);
	else if (error)
		*error = writeError;
	return ok;
}

+ (int)reserveLocalPort:(NSError**)error
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
	{
		if (error)
			*error = SSHError(3, @"Не удалось выбрать локальный порт.");
		return -1;
	}
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	address.sin_port = 0;
	if (bind(fd, (struct sockaddr*)&address, sizeof(address)) != 0)
	{
		close(fd);
		if (error)
			*error = SSHError(3, @"Не удалось занять локальный порт.");
		return -1;
	}
	socklen_t length = sizeof(address);
	getsockname(fd, (struct sockaddr*)&address, &length);
	int port = ntohs(address.sin_port);
	close(fd);
	return port;
}

- (BOOL)waitForLocalPort:(int)port stderrFd:(int)stderrFd log:(void (^)(NSString*))log
{
	for (int i = 0; i < 80; i++)
	{
		if (stderrFd >= 0)
			[self consumeStderr:stderrFd log:log];
		int status = 0;
		pid_t result = waitpid(_pid, &status, WNOHANG);
		if (result == _pid)
		{
			if (stderrFd >= 0)
				[self consumeStderr:stderrFd log:log];
			_pid = 0;
			_running = NO;
			if (log)
				log(@"SSH завершился до того, как туннель открылся.");
			return NO;
		}
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in address;
		memset(&address, 0, sizeof(address));
		address.sin_family = AF_INET;
		address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		address.sin_port = htons((uint16_t)port);
		int connected = connect(fd, (struct sockaddr*)&address, sizeof(address));
		close(fd);
		if (connected == 0)
			return YES;
		usleep(250000);
	}
	if (log)
		log(@"Туннель не открылся за 20 секунд.");
	return NO;
}

- (BOOL)stderrShowsChangedHostKey
{
	return [_stderrText containsString:@"REMOTE HOST IDENTIFICATION HAS CHANGED"];
}

- (NSArray<NSString*>*)commonOptionsForHost:(NSString*)host port:(int)port
{
	NSString* knownHosts = [SSHClient knownHostsURL].path;
	return @[
		@"-F", @"/dev/null", @"-p", [NSString stringWithFormat:@"%d", port], @"-o", @"StrictHostKeyChecking=yes",
		@"-o", SSHQuotedOption(@"UserKnownHostsFile", knownHosts), @"-o", @"GlobalKnownHostsFile=/dev/null", @"-o",
		@"UpdateHostKeys=no", @"-o", @"ConnectTimeout=12", @"-o", @"ServerAliveInterval=5", @"-o",
		@"ServerAliveCountMax=2", @"-o", @"TCPKeepAlive=yes", @"-o", @"NumberOfPasswordPrompts=1", @"-o",
		@"IdentitiesOnly=yes", @"-o", @"IdentityAgent=none"
	];
}

- (void)consumeStderr:(int)fd log:(void (^)(NSString*))log
{
	char buffer[512];
	ssize_t count = read(fd, buffer, sizeof(buffer));
	if (count <= 0)
		return;
	NSString* text = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)count encoding:NSUTF8StringEncoding];
	if (!text)
		return;
	if (!_stderrText)
		_stderrText = [NSMutableString string];
	[_stderrText appendString:text];
	NSArray* lines = [text componentsSeparatedByString:@"\n"];
	for (NSString* line in lines)
	{
		NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (trimmed.length && log)
			log(trimmed);
	}
}

- (BOOL)launchSSHWithArguments:(NSArray<NSString*>*)arguments
                      password:(NSString*)password
                     stderrOut:(int*)stderrOut
                         error:(NSError**)error
{
	if (password.length && ![self writeSecret:password error:error])
		return NO;
	NSString* askpass = [SSHClient askpassPath];
	if (password.length && askpass.length == 0)
	{
		if (error)
			*error = SSHError(1, @"В программе нет помощника для пароля SSH.");
		return NO;
	}
	int pipefd[2];
	if (pipe(pipefd) != 0)
	{
		if (error)
			*error = SSHError(3, @"Не удалось прочитать ответ SSH.");
		return NO;
	}
	pid_t pid = fork();
	if (pid < 0)
	{
		close(pipefd[0]);
		close(pipefd[1]);
		if (error)
			*error = SSHError(3, @"Не удалось запустить SSH.");
		return NO;
	}
	if (pid == 0)
	{
		setsid();
		dup2(pipefd[1], STDERR_FILENO);
		int devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0)
		{
			dup2(devnull, STDIN_FILENO);
			dup2(devnull, STDOUT_FILENO);
			if (devnull > 2)
				close(devnull);
		}
		if (_captureStdout)
			dup2(pipefd[1], STDOUT_FILENO);
		close(pipefd[0]);
		close(pipefd[1]);
		if (password.length)
		{
			setenv("SSH_ASKPASS", askpass.UTF8String, 1);
			setenv("SSH_ASKPASS_REQUIRE", "force", 1);
			setenv("DALNY_ASKPASS_FILE", _secretPath.UTF8String, 1);
			setenv("DISPLAY", "dalny", 1);
		}
		NSMutableArray* argv = [@[ @"/usr/bin/ssh" ] mutableCopy];
		[argv addObjectsFromArray:arguments];
		char** cargv = calloc(argv.count + 1, sizeof(char*));
		for (NSUInteger i = 0; i < argv.count; i++)
			cargv[i] = strdup([argv[i] UTF8String]);
		execv("/usr/bin/ssh", cargv);
		_exit(127);
	}
	close(pipefd[1]);
	fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
	_pid = pid;
	_running = YES;
	_stderrText = [NSMutableString string];
	if (stderrOut)
		*stderrOut = pipefd[0];
	else
		close(pipefd[0]);
	return YES;
}

- (BOOL)startHost:(NSString*)host
             port:(int)port
         username:(NSString*)username
       remotePort:(int)remotePort
           keyPEM:(NSString*)keyPEM
         password:(NSString*)password
          askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
              log:(void (^)(NSString* line))log
            error:(NSError**)error
{
	[self stop];
	if (![SSHClient confirmHost:host port:port changed:NO askHost:askHost log:log error:error])
		return NO;
	return [self openTunnelHost:host
	                       port:port
	                   username:username
	                 remotePort:remotePort
	                     keyPEM:keyPEM
	                   password:password
	                    askHost:askHost
	                        log:log
	           allowHostReplace:YES
	                      error:error];
}

- (BOOL)openTunnelHost:(NSString*)host
                  port:(int)port
              username:(NSString*)username
            remotePort:(int)remotePort
                keyPEM:(NSString*)keyPEM
              password:(NSString*)password
               askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
                   log:(void (^)(NSString* line))log
      allowHostReplace:(BOOL)allowHostReplace
                 error:(NSError**)error
{
	[self stop];
	if (!SSHCheckTarget(host, port, username, error))
		return NO;
	int local = [SSHClient reserveLocalPort:error];
	if (local <= 0)
		return NO;
	_localPort = local;
	NSMutableArray* args = [[self commonOptionsForHost:host port:port] mutableCopy];
	[args addObjectsFromArray:@[ @"-N", @"-o", @"ExitOnForwardFailure=yes" ]];
	NSString* forward = [NSString stringWithFormat:@"127.0.0.1:%d:127.0.0.1:%d", local, remotePort];
	[args addObjectsFromArray:@[ @"-L", forward ]];
	if (keyPEM.length)
	{
		if (![self writeKey:keyPEM error:error])
			return NO;
		[args addObjectsFromArray:@[ @"-i", _keyPath, @"-o", @"PreferredAuthentications=publickey" ]];
	}
	else
	{
		[args addObjectsFromArray:@[ @"-o", @"PreferredAuthentications=password", @"-o",
			                          @"PubkeyAuthentication=no" ]];
	}
	[args addObjectsFromArray:@[ @"--", [NSString stringWithFormat:@"%@@%@", username, host] ]];
	if (log)
		log([NSString stringWithFormat:@"Поднимаю туннель 127.0.0.1:%d → сервер:%d.", local, remotePort]);
	int stderrFd = -1;
	if (![self launchSSHWithArguments:args password:keyPEM.length ? nil : password stderrOut:&stderrFd error:error])
		return NO;
	BOOL opened = [self waitForLocalPort:local stderrFd:stderrFd log:log];
	if (opened && stderrFd > 0)
	{
		@synchronized(self)
		{
			_tunnelStderr = stderrFd;
			_tunnelLog = [log copy];
		}
	}
	else if (stderrFd >= 0)
		close(stderrFd);
	if (!opened)
	{
		BOOL changed = allowHostReplace && [self stderrShowsChangedHostKey];
		NSString* stderrCopy = [_stderrText copy];
		[self stop];
		if (changed)
		{
			if (log)
				log(@"Ключ сервера SSH изменился.");
			/* The old key stays in known_hosts until the user accepts the new one. */
			if (![SSHClient confirmHost:host port:port changed:YES askHost:askHost log:log error:error])
			{
				if (error && !*error)
					*error = SSHError(2, @"Ключ сервера SSH изменился и не был принят.");
				return NO;
			}
			return [self openTunnelHost:host
			                     port:port
			                 username:username
			               remotePort:remotePort
			                   keyPEM:keyPEM
			                 password:password
			                  askHost:askHost
			                      log:log
			         allowHostReplace:NO
			                    error:error];
		}
		if (error && !*error)
		{
			BOOL hostKey = [stderrCopy rangeOfString:@"host key" options:NSCaseInsensitiveSearch].location != NSNotFound;
			NSInteger code = hostKey ? 2 : 3;
			/* 4: the server rejected the SSH password or key. The UI asks again. */
			if (!hostKey &&
			    [stderrCopy rangeOfString:@"Permission denied" options:NSCaseInsensitiveSearch].location != NSNotFound)
				code = 4;
			*error = SSHError(code, SSHFailureMessage(stderrCopy, -1, @"Туннель SSH не открылся."));
		}
		return NO;
	}
	if (log)
		log(@"Туннель готов.");
	return YES;
}

+ (BOOL)installPublicKey:(NSString*)publicKey
                    host:(NSString*)host
                    port:(int)port
                username:(NSString*)username
                password:(NSString*)password
                 askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
                     log:(void (^)(NSString* line))log
                   error:(NSError**)error
{
	if (![self validPublicKey:publicKey])
	{
		if (error)
			*error = SSHError(1, @"Открытый ключ выглядит неправильно. Создайте его ещё раз.");
		return NO;
	}
	if (!SSHCheckTarget(host, port, username, error))
		return NO;
	if (![self confirmHost:host port:port changed:NO askHost:askHost log:log error:error])
		return NO;
	NSString* command = [NSString
	    stringWithFormat:@"umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
	                     @"chmod 600 ~/.ssh/authorized_keys && grep -qxF '%@' ~/.ssh/authorized_keys || echo '%@' "
	                     @">> ~/.ssh/authorized_keys",
	                     publicKey, publicKey];
	SSHClient* client = [SSHClient new];
	NSMutableArray* args = [[client commonOptionsForHost:host port:port] mutableCopy];
	[args addObjectsFromArray:@[ @"-o", @"PreferredAuthentications=password", @"-o", @"PubkeyAuthentication=no", @"--",
		                          [NSString stringWithFormat:@"%@@%@", username, host], command ]];
	if (log)
	{
		log([NSString stringWithFormat:@"Файл известных ключей: %@", [self knownHostsURL].path]);
		log(@"Вхожу по паролю, чтобы добавить ключ…");
	}
	int stderrFd = -1;
	if (![client launchSSHWithArguments:args password:password stderrOut:&stderrFd error:error])
		return NO;
	int status = 0;
	BOOL finished = NO;
	for (int i = 0; i < 300; i++)
	{
		pid_t waited = waitpid(client->_pid, &status, WNOHANG);
		[client consumeStderr:stderrFd log:log];
		if (waited == client->_pid)
		{
			finished = YES;
			break;
		}
		usleep(100000);
	}
	if (!finished)
	{
		[client stop];
		if (stderrFd >= 0)
			close(stderrFd);
		if (error)
			*error = SSHError(3, @"Сервер SSH слишком долго ставил ключ.");
		return NO;
	}
	[client consumeStderr:stderrFd log:log];
	if (stderrFd >= 0)
		close(stderrFd);
	client->_pid = 0;
	[client stop];
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
	{
		BOOL changed = [client stderrShowsChangedHostKey];
		BOOL alreadyRetried = [[NSThread currentThread].threadDictionary[@"dalny-ssh-retry"] boolValue];
		if (changed && !alreadyRetried)
		{
			[NSThread currentThread].threadDictionary[@"dalny-ssh-retry"] = @YES;
			BOOL trusted = [self confirmHost:host port:port changed:YES askHost:askHost log:log error:error];
			BOOL installed = NO;
			if (trusted)
				installed = [self installPublicKey:publicKey
				                             host:host
				                             port:port
				                         username:username
				                         password:password
				                          askHost:askHost
				                              log:log
				                            error:error];
			[NSThread currentThread].threadDictionary[@"dalny-ssh-retry"] = @NO;
			return installed;
		}
		if (error)
		{
			int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : status;
			BOOL hostKey = [client->_stderrText rangeOfString:@"host key" options:NSCaseInsensitiveSearch].location != NSNotFound ||
			               [client->_stderrText rangeOfString:@"strict checking" options:NSCaseInsensitiveSearch].location != NSNotFound;
			BOOL denied = [client->_stderrText rangeOfString:@"Permission denied" options:NSCaseInsensitiveSearch].location != NSNotFound;
			NSInteger code = hostKey ? 2 : (denied ? 1 : 3);
			*error = SSHError(code, SSHFailureMessage(client->_stderrText, exitCode,
			                                          @"Сервер не записал ключ."));
		}
		return NO;
	}
	if (log)
		log(@"Ключ записан в ~/.ssh/authorized_keys на сервере.");
	return YES;
}

+ (NSString*)runScript:(NSString*)script
                  host:(NSString*)host
                  port:(int)port
              username:(NSString*)username
                keyPEM:(NSString*)keyPEM
              password:(NSString*)password
               askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
                   log:(void (^)(NSString* line))log
                 error:(NSError**)error
{
	if (!SSHCheckTarget(host, port, username, error))
		return nil;
	if (![self confirmHost:host port:port changed:NO askHost:askHost log:log error:error])
		return nil;
	/* The script travels as base64 so no shell quoting is involved on either side. */
	NSString* encoded = [[script dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
	NSString* command = [NSString stringWithFormat:@"echo %@ | base64 -d | sh", encoded];
	SSHClient* client = [SSHClient new];
	client->_captureStdout = YES;
	NSMutableArray* args = [[client commonOptionsForHost:host port:port] mutableCopy];
	if (keyPEM.length)
	{
		if (![client writeKey:keyPEM error:error])
			return nil;
		[args addObjectsFromArray:@[ @"-i", client->_keyPath, @"-o", @"PreferredAuthentications=publickey" ]];
	}
	else
	{
		[args addObjectsFromArray:@[ @"-o", @"PreferredAuthentications=password", @"-o", @"PubkeyAuthentication=no" ]];
	}
	[args addObjectsFromArray:@[ @"--", [NSString stringWithFormat:@"%@@%@", username, host], command ]];
	int fd = -1;
	if (![client launchSSHWithArguments:args password:keyPEM.length ? nil : password stderrOut:&fd error:error])
	{
		[client stop];
		return nil;
	}
	NSMutableData* output = [NSMutableData data];
	int status = 0;
	BOOL finished = NO;
	char buffer[4096];
	for (int i = 0; i < 600; i++)
	{
		ssize_t count;
		while ((count = read(fd, buffer, sizeof(buffer))) > 0)
			[output appendBytes:buffer length:(NSUInteger)count];
		pid_t waited = waitpid(client->_pid, &status, WNOHANG);
		if (waited == client->_pid)
		{
			finished = YES;
			break;
		}
		usleep(100000);
	}
	if (finished)
	{
		ssize_t count;
		while ((count = read(fd, buffer, sizeof(buffer))) > 0)
			[output appendBytes:buffer length:(NSUInteger)count];
		client->_pid = 0;
	}
	close(fd);
	[client stop];
	NSString* text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding]
	    ?: [[NSString alloc] initWithData:output encoding:NSISOLatin1StringEncoding] ?: @"";
	if (!finished)
	{
		if (error)
			*error = SSHError(3, @"Сервер SSH не закончил команду за 60 секунд.");
		return nil;
	}
	int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
	if (exitCode == 255 || exitCode < 0)
	{
		if (error)
		{
			BOOL denied = [text rangeOfString:@"Permission denied" options:NSCaseInsensitiveSearch].location != NSNotFound;
			BOOL hostKey = [text rangeOfString:@"host key" options:NSCaseInsensitiveSearch].location != NSNotFound;
			*error = SSHError(hostKey ? 2 : (denied ? 4 : 3), SSHFailureMessage(text, exitCode, @"Команда SSH не выполнилась."));
		}
		return nil;
	}
	return text;
}

- (void)dealloc
{
	[self stop];
}

@end
