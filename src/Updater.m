#import "Updater.h"
#import "DalnyLog.h"
#import "Keychain.h"
#import <Cocoa/Cocoa.h>
#import <spawn.h>
#import <sys/stat.h>
#import <unistd.h>

extern char** environ;

static NSString* const kTokenAccount = @"github-token";
static NSString* const kRepo = @"chelekov/dalny";
static NSString* const kBundleID = @"app.dalny.client";
static NSString* const kAssetName = @"Dalny-macos.zip";
static NSInteger const kMaxZipBytes = 250 * 1024 * 1024;

static NSString* Redact(NSString* text, NSString* token)
{
	if (text.length == 0)
		return @"";
	if (token.length == 0)
		return text;
	return [text stringByReplacingOccurrencesOfString:token withString:@"[token]"];
}

static NSString* Trim(NSString* text)
{
	return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSComparisonResult CompareVersions(NSString* left, NSString* right)
{
	NSArray<NSString*>* a = [left componentsSeparatedByString:@"."];
	NSArray<NSString*>* b = [right componentsSeparatedByString:@"."];
	NSUInteger count = MAX(a.count, b.count);
	for (NSUInteger i = 0; i < count; i++)
	{
		NSInteger av = i < a.count ? a[i].integerValue : 0;
		NSInteger bv = i < b.count ? b[i].integerValue : 0;
		if (av < bv)
			return NSOrderedAscending;
		if (av > bv)
			return NSOrderedDescending;
	}
	return NSOrderedSame;
}

@interface DalnyAssetDownload : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) NSURL* destination;
@property(nonatomic) NSInteger status;
@property(nonatomic, strong) NSError* error;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation DalnyAssetDownload

- (void)URLSession:(NSURLSession*)session
              task:(NSURLSessionTask*)task
willPerformHTTPRedirection:(NSHTTPURLResponse*)response
        newRequest:(NSURLRequest*)request
 completionHandler:(void (^)(NSURLRequest* _Nullable))completionHandler
{
	NSMutableURLRequest* next = [request mutableCopy];
	[next setValue:nil forHTTPHeaderField:@"Authorization"];
	completionHandler(next);
}

- (void)URLSession:(NSURLSession*)session
                 downloadTask:(NSURLSessionDownloadTask*)downloadTask
    didFinishDownloadingToURL:(NSURL*)location
{
	NSHTTPURLResponse* http = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
	                              ? (NSHTTPURLResponse*)downloadTask.response
	                              : nil;
	self.status = http.statusCode;
	if (http.statusCode != 200)
	{
		NSString* payload = [NSString stringWithContentsOfURL:location encoding:NSUTF8StringEncoding error:NULL] ?: @"";
		BOOL rateLimited = [payload rangeOfString:@"rate limit" options:NSCaseInsensitiveSearch].location != NSNotFound;
		NSString* message = rateLimited
		                        ? @"GitHub временно ограничил число запросов. Повторите обновление позже."
		                        : [NSString stringWithFormat:@"GitHub ответил HTTP %ld при скачивании.", (long)http.statusCode];
		self.error = [NSError errorWithDomain:@"app.dalny.client.update"
		                                 code:http.statusCode
		                             userInfo:@{NSLocalizedDescriptionKey : message}];
		return;
	}
	[[NSFileManager defaultManager] removeItemAtURL:self.destination error:NULL];
	NSError* moveError = nil;
	if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:self.destination error:&moveError])
		self.error = moveError;
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error
{
	if (error && !self.error)
		self.error = error;
	dispatch_semaphore_signal(self.done);
}

@end

@implementation Updater

+ (NSString*)tokenAccount
{
	return kTokenAccount;
}

+ (NSDictionary*)bundleInfo
{
	return [NSBundle mainBundle].infoDictionary ?: @{};
}

+ (NSString*)localShortVersion
{
	return [self bundleInfo][@"CFBundleShortVersionString"] ?: @"0";
}

+ (NSInteger)localBuild
{
	return [[self bundleInfo][@"CFBundleVersion"] integerValue];
}

+ (void)checkSilently
{
	[self checkInteractive:NO];
}

+ (void)checkInteractively
{
	[self checkInteractive:YES];
}

+ (void)checkInteractive:(BOOL)interactive
{
	static BOOL busy = NO;
	if (busy)
		return;
	busy = YES;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError* keychainError = nil;
		NSString* token = Trim([Keychain secretForAccount:kTokenAccount error:&keychainError]);
		if (keychainError)
			[DalnyLog append:Redact(keychainError.localizedDescription, token)];
		NSError* error = nil;
		NSDictionary* release = [self latestReleaseWithToken:token error:&error];
		if (!release)
		{
			BOOL show = interactive || error.code == 401;
			[self finishInteractive:show message:Redact(error.localizedDescription, token)];
			busy = NO;
			return;
		}
		NSInteger remoteBuild = [release[@"build"] integerValue];
		NSString* remoteShort = release[@"short"] ?: @"";
		BOOL newer = NO;
		if (remoteBuild > 0 && [self localBuild] > 0)
			newer = remoteBuild > [self localBuild];
		else
			newer = CompareVersions([self localShortVersion], remoteShort) == NSOrderedAscending;
		if (!newer)
		{
			NSString* message = [NSString stringWithFormat:@"Обновлений нет. Сейчас сборка %@ (%ld).",
			                                               [self localShortVersion], (long)[self localBuild]];
			[DalnyLog append:message];
			if (interactive)
				[self finishInteractive:YES message:message];
			busy = NO;
			return;
		}
		NSString* offer = remoteBuild > 0
		    ? [NSString stringWithFormat:@"Доступна версия %@ (сборка %ld). Сейчас установлена %@ (сборка %ld).",
		                                 remoteShort, (long)remoteBuild, [self localShortVersion], (long)[self localBuild]]
		    : [NSString stringWithFormat:@"Доступна версия %@. Сейчас установлена %@ (сборка %ld).", remoteShort,
		                                 [self localShortVersion], (long)[self localBuild]];
		[DalnyLog append:offer];
		dispatch_async(dispatch_get_main_queue(), ^{
			NSAlert* alert = [NSAlert new];
			alert.messageText = @"Есть обновление";
			alert.informativeText = offer;
			[alert addButtonWithTitle:@"Обновить"];
			[alert addButtonWithTitle:@"Позже"];
			BOOL accepted = [alert runModal] == NSAlertFirstButtonReturn;
			if (!accepted)
			{
				busy = NO;
				return;
			}
			[DalnyLog append:@"Скачиваю обновление…"];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				NSError* installError = nil;
				BOOL ok = [self downloadAndInstallRelease:release token:token error:&installError];
				NSString* text = ok ? nil : Redact(installError.localizedDescription ?: @"Не удалось обновиться.", token);
				dispatch_async(dispatch_get_main_queue(), ^{
					if (!ok)
					{
						[DalnyLog append:text];
						NSAlert* failed = [NSAlert new];
						failed.messageText = @"Не удалось обновиться";
						failed.informativeText = text;
						[failed runModal];
					}
					busy = NO;
				});
			});
		});
	});
}

+ (void)finishInteractive:(BOOL)interactive message:(NSString*)message
{
	if (message.length == 0)
		return;
	[DalnyLog append:message];
	if (!interactive)
		return;
	dispatch_async(dispatch_get_main_queue(), ^{
		NSAlert* alert = [NSAlert new];
		alert.messageText = @"Обновление";
		alert.informativeText = message;
		[alert addButtonWithTitle:@"Хорошо"];
		[alert runModal];
	});
}

+ (NSDictionary*)latestReleaseWithToken:(NSString*)token error:(NSError**)error
{
	NSString* address = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kRepo];
	NSURL* url = [NSURL URLWithString:address];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.timeoutInterval = 30;
	if (token.length > 0)
		[request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
	[request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
	[request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
	[request setValue:@"Dalny" forHTTPHeaderField:@"User-Agent"];
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSData* body = nil;
	__block NSURLResponse* response = nil;
	__block NSError* taskError = nil;
	NSURLSessionDataTask* task = [[NSURLSession sharedSession]
	    dataTaskWithRequest:request
	      completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
		      body = data;
		      response = resp;
		      taskError = err;
		      dispatch_semaphore_signal(done);
	      }];
	[task resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	NSInteger status = [(NSHTTPURLResponse*)response statusCode];
	if (taskError)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:taskError.code
			                         userInfo:@{NSLocalizedDescriptionKey : Redact(taskError.localizedDescription, token)}];
		return nil;
	}
	NSString* payload = [[NSString alloc] initWithData:body ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
	BOOL rateLimited = [payload rangeOfString:@"rate limit" options:NSCaseInsensitiveSearch].location != NSNotFound;
	if ((status == 403 || status == 429) && rateLimited && token.length == 0)
	{
		/* Anonymous API calls share 60/hour per IP; behind a VPN others use that up.
		 * The public web pages have no such limit. */
		[DalnyLog append:@"API GitHub упёрся в предел запросов, проверяю через страницу релизов."];
		return [self latestReleaseFromWebWithError:error];
	}
	if ((status == 403 || status == 429) && rateLimited)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:status
			                         userInfo:@{
				                         NSLocalizedDescriptionKey :
				                             @"GitHub временно ограничил число запросов. Повторите проверку позже."
			                         }];
		return nil;
	}
	if (status == 401)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:status
			                         userInfo:@{
				                         NSLocalizedDescriptionKey :
				                             @"GitHub не принял необязательный токен. Для публичного репозитория сотрите его в Настройках."
			                         }];
		return nil;
	}
	if (status != 200)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:status
			                         userInfo:@{
				                         NSLocalizedDescriptionKey :
				                             [NSString stringWithFormat:@"GitHub ответил HTTP %ld. Релиза пока нет.", (long)status]
			                         }];
		return nil;
	}
	id json = [NSJSONSerialization JSONObjectWithData:body ?: [NSData data] options:0 error:error];
	if (![json isKindOfClass:[NSDictionary class]])
		return nil;
	NSDictionary* release = json;
	NSString* notes = [release[@"body"] isKindOfClass:[NSString class]] ? release[@"body"] : @"";
	NSString* shortVersion = nil;
	NSInteger build = 0;
	for (NSString* raw in [notes componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
	{
		NSString* line = Trim(raw);
		if ([line hasPrefix:@"CFBundleShortVersionString:"])
			shortVersion = Trim([line substringFromIndex:[@"CFBundleShortVersionString:" length]]);
		if ([line hasPrefix:@"CFBundleVersion:"])
			build = Trim([line substringFromIndex:[@"CFBundleVersion:" length]]).integerValue;
	}
	NSString* tag = [release[@"tag_name"] isKindOfClass:[NSString class]] ? release[@"tag_name"] : @"";
	if (build == 0 && [tag hasPrefix:@"build-"])
		build = [tag substringFromIndex:6].integerValue;
	if (shortVersion.length == 0 && [tag hasPrefix:@"v"])
		shortVersion = [tag substringFromIndex:1];
	NSString* assetURL = nil;
	for (id item in release[@"assets"])
	{
		if (![item isKindOfClass:[NSDictionary class]])
			continue;
		if ([item[@"name"] isEqualToString:kAssetName] && [item[@"url"] isKindOfClass:[NSString class]])
			assetURL = item[@"url"];
	}
	if (assetURL.length == 0)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:404
			                         userInfo:@{NSLocalizedDescriptionKey : @"В релизе нет файла Dalny-macos.zip."}];
		return nil;
	}
	return @{@"short" : shortVersion ?: tag, @"build" : @(build), @"asset" : assetURL};
}

/* No API: /releases/latest redirects to /releases/tag/<tag>; the asset has a fixed download URL. */
+ (NSDictionary*)latestReleaseFromWebWithError:(NSError**)error
{
	NSString* address = [NSString stringWithFormat:@"https://github.com/%@/releases/latest", kRepo];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
	request.HTTPMethod = @"HEAD";
	request.timeoutInterval = 30;
	[request setValue:@"Dalny" forHTTPHeaderField:@"User-Agent"];
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSURLResponse* response = nil;
	__block NSError* taskError = nil;
	NSURLSessionDataTask* task = [[NSURLSession sharedSession]
	    dataTaskWithRequest:request
	      completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
		      (void)data;
		      response = resp;
		      taskError = err;
		      dispatch_semaphore_signal(done);
	      }];
	[task resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	NSURL* final = response.URL;
	NSArray<NSString*>* parts = final.pathComponents;
	NSString* tag = parts.count >= 2 && [parts[parts.count - 2] isEqualToString:@"tag"] ? parts.lastObject : nil;
	NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"v0123456789."];
	if (taskError || [(NSHTTPURLResponse*)response statusCode] != 200 || ![tag hasPrefix:@"v"] ||
	    [tag rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:taskError ? taskError.code : 1
			                         userInfo:@{
				                         NSLocalizedDescriptionKey :
				                             @"GitHub временно ограничил число запросов, и страницу релизов прочитать не удалось. Повторите проверку позже."
			                         }];
		return nil;
	}
	NSString* asset =
	    [NSString stringWithFormat:@"https://github.com/%@/releases/download/%@/%@", kRepo, tag, kAssetName];
	/* build 0: the caller compares the short versions. */
	return @{@"short" : [tag substringFromIndex:1], @"build" : @0, @"asset" : asset};
}

+ (BOOL)downloadAndInstallRelease:(NSDictionary*)release token:(NSString*)token error:(NSError**)error
{
	NSString* bundlePath = [NSBundle mainBundle].bundlePath;
	if ([bundlePath containsString:@"AppTranslocation"])
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:1
			                         userInfo:@{
				                         NSLocalizedDescriptionKey :
				                             @"Программа открыта из временной копии. Перетащите «Дальний» в папку "
				                             @"«Программы», откройте её оттуда и проверьте обновление ещё раз."
			                         }];
		return NO;
	}
	NSString* parent = [bundlePath stringByDeletingLastPathComponent];
	if (![[NSFileManager defaultManager] isWritableFileAtPath:parent])
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:1
			                         userInfo:@{
				                         NSLocalizedDescriptionKey : @"Нет права заменить программу в этой папке."
			                         }];
		return NO;
	}
	NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	NSURL* zipURL = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:kAssetName]];
	if (![self downloadAsset:release[@"asset"] token:token toURL:zipURL error:error])
		return NO;
	NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:zipURL.path error:NULL];
	if ([attrs fileSize] == 0 || [attrs fileSize] > kMaxZipBytes)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:1
			                         userInfo:@{NSLocalizedDescriptionKey : @"Скачанный архив пустой или слишком большой."}];
		return NO;
	}
	NSString* unzip = [self runTool:@"/usr/bin/unzip" arguments:@[ @"-tqq", zipURL.path ] error:error];
	if (!unzip)
		return NO;
	NSString* extract = [folder stringByAppendingPathComponent:@"extract"];
	[[NSFileManager defaultManager] createDirectoryAtPath:extract withIntermediateDirectories:YES attributes:nil error:NULL];
	if (![self runTool:@"/usr/bin/ditto" arguments:@[ @"-x", @"-k", zipURL.path, extract ] error:error])
		return NO;
	NSString* staged = [extract stringByAppendingPathComponent:@"Dalny.app"];
	if (![self runTool:@"/usr/bin/xattr" arguments:@[ @"-dr", @"com.apple.quarantine", staged ] error:NULL])
	{
		if (error && !*error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:1
			                         userInfo:@{NSLocalizedDescriptionKey : @"Не удалось снять карантин со скачанной копии."}];
		return NO;
	}
	NSString* plistPath = [staged stringByAppendingPathComponent:@"Contents/Info.plist"];
	NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
	if (![info[@"CFBundleIdentifier"] isEqualToString:kBundleID])
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:1
			                         userInfo:@{NSLocalizedDescriptionKey : @"В архиве не программа Дальний."}];
		return NO;
	}
	if (![self runTool:@"/usr/bin/codesign" arguments:@[ @"--verify", @"--verbose=2", staged ] error:error])
		return NO;
	return [self swapStagedApp:staged over:bundlePath error:error];
}

+ (BOOL)downloadAsset:(NSString*)assetURL token:(NSString*)token toURL:(NSURL*)destination error:(NSError**)error
{
	DalnyAssetDownload* fetcher = [DalnyAssetDownload new];
	fetcher.destination = destination;
	fetcher.done = dispatch_semaphore_create(0);
	NSOperationQueue* queue = [NSOperationQueue new];
	queue.maxConcurrentOperationCount = 1;
	NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	config.timeoutIntervalForResource = 180;
	NSURLSession* session = [NSURLSession sessionWithConfiguration:config delegate:fetcher delegateQueue:queue];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:assetURL]];
	if (token.length > 0)
		[request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
	[request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
	[request setValue:@"Dalny" forHTTPHeaderField:@"User-Agent"];
	NSURLSessionDownloadTask* task = [session downloadTaskWithRequest:request];
	[task resume];
	dispatch_semaphore_wait(fetcher.done, DISPATCH_TIME_FOREVER);
	[session finishTasksAndInvalidate];
	if (fetcher.error)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:fetcher.error.code
			                         userInfo:@{
				                         NSLocalizedDescriptionKey : Redact(fetcher.error.localizedDescription, token)
			                         }];
		return NO;
	}
	return YES;
}

+ (NSString*)runTool:(NSString*)path arguments:(NSArray<NSString*>*)arguments error:(NSError**)error
{
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:path];
	task.arguments = arguments;
	NSPipe* output = [NSPipe pipe];
	NSPipe* errors = [NSPipe pipe];
	task.standardOutput = output;
	task.standardError = errors;
	NSError* launchError = nil;
	if (![task launchAndReturnError:&launchError])
	{
		if (error)
			*error = launchError;
		return nil;
	}
	[task waitUntilExit];
	NSData* errData = [[errors fileHandleForReading] readDataToEndOfFile];
	NSString* errText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
	if (task.terminationStatus != 0)
	{
		if (error)
		{
			NSString* message = Trim(errText);
			if (message.length == 0)
				message = [NSString stringWithFormat:@"%@ завершилась с кодом %d.", path.lastPathComponent, task.terminationStatus];
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:task.terminationStatus
			                         userInfo:@{NSLocalizedDescriptionKey : message}];
		}
		return nil;
	}
	return errText.length ? errText : @"ok";
}

+ (BOOL)swapStagedApp:(NSString*)staged over:(NSString*)destination error:(NSError**)error
{
	NSString* scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
	                                            [NSString stringWithFormat:@"dalny-update-%@.sh", [NSUUID UUID].UUIDString]];
	NSString* script = @"#!/bin/bash\n"
	                   "set -eu\n"
	                   "pid=\"$1\"\n"
	                   "src=\"$2\"\n"
	                   "dest=\"$3\"\n"
	                   "while /bin/kill -0 \"$pid\" 2>/dev/null; do /bin/sleep 0.2; done\n"
	                   "next=\"${dest}.new\"\n"
	                   "parent=\"${src%/*}\"\n"
	                   "/bin/rm -rf \"$next\"\n"
	                   "/usr/bin/ditto \"$src\" \"$next\"\n"
	                   "/usr/bin/xattr -dr com.apple.quarantine \"$next\" || true\n"
	                   "/bin/rm -rf \"$dest\"\n"
	                   "/bin/mv \"$next\" \"$dest\"\n"
	                   "/usr/bin/xattr -dr com.apple.quarantine \"$dest\" || true\n"
	                   "/bin/rm -rf \"$parent\"\n"
	                   "/usr/bin/open \"$dest\"\n";
	NSError* writeError = nil;
	if (![script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError])
	{
		if (error)
			*error = writeError;
		return NO;
	}
	chmod(scriptPath.fileSystemRepresentation, 0700);
	NSString* pidText = [NSString stringWithFormat:@"%d", getpid()];
	char* argv[] = {(char*)"/bin/bash", (char*)scriptPath.fileSystemRepresentation, (char*)pidText.UTF8String,
	                (char*)staged.fileSystemRepresentation, (char*)destination.fileSystemRepresentation, NULL};
	posix_spawnattr_t attr;
	posix_spawnattr_init(&attr);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
	pid_t child = 0;
	int spawned = posix_spawn(&child, "/bin/bash", NULL, &attr, argv, environ);
	posix_spawnattr_destroy(&attr);
	if (spawned != 0)
	{
		if (error)
			*error = [NSError errorWithDomain:@"app.dalny.client.update"
			                             code:spawned
			                         userInfo:@{NSLocalizedDescriptionKey : @"Не удалось запустить замену программы."}];
		return NO;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSApp terminate:nil];
	});
	return YES;
}

@end
