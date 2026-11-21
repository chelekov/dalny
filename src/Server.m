#import "Server.h"

@implementation DalnyServer

+ (instancetype)newServer
{
	DalnyServer* server = [DalnyServer new];
	server.identifier = [NSUUID UUID].UUIDString;
	server.name = @"";
	server.host = @"";
	server.port = 3389;
	server.username = @"";
	server.graphics = @"economy";
	server.displayMode = @"fit";
	server.width = 1280;
	server.height = 800;
	server.colorDepth = 16;
	server.mapCommandToControl = YES;
	server.autoReconnect = YES;
	server.shareClipboard = YES;
	server.sshEnabled = YES;
	server.sshHost = @"";
	server.sshPort = 22;
	server.sshUsername = @"";
	server.sshAuth = @"password";
	server.sshPublicKey = @"";
	server.certFingerprint = @"";
	server.languageSetup = @"";
	server.profileBeforeExtreme = @{};
	return server;
}

- (NSString*)string:(id)value fallback:(NSString*)fallback
{
	return [value isKindOfClass:[NSString class]] ? value : fallback;
}

+ (instancetype)serverFromDictionary:(NSDictionary*)dictionary newIdentity:(BOOL)newIdentity
{
	if (![dictionary isKindOfClass:[NSDictionary class]])
		return nil;
	DalnyServer* server = [DalnyServer newServer];
	if (!newIdentity)
	{
		NSString* identifier = dictionary[@"id"];
		if ([identifier isKindOfClass:[NSString class]] && identifier.length > 0)
			server.identifier = identifier;
	}
	server.name = [server string:dictionary[@"name"] fallback:@""];
	server.host = [server string:dictionary[@"host"] fallback:@""];
	server.port = [dictionary[@"port"] respondsToSelector:@selector(integerValue)]
	                   ? [dictionary[@"port"] integerValue]
	                   : 3389;
	if (server.port <= 0 || server.port > 65535)
		server.port = 3389;
	server.username = [server string:dictionary[@"username"] fallback:@""];
	server.graphics = [server string:dictionary[@"graphics"] fallback:@"economy"];
	server.displayMode = [server string:dictionary[@"displayMode"] fallback:@"fixed"];
	server.width = [dictionary[@"width"] integerValue] ?: 1280;
	server.height = [dictionary[@"height"] integerValue] ?: 800;
	NSInteger depth = [dictionary[@"colorDepth"] integerValue];
	server.colorDepth = depth == 32 ? 32 : (depth == 8 ? 8 : 16);
	if (dictionary[@"mapCommandToControl"])
		server.mapCommandToControl = [dictionary[@"mapCommandToControl"] boolValue];
	if (dictionary[@"autoReconnect"])
		server.autoReconnect = [dictionary[@"autoReconnect"] boolValue];
	if (dictionary[@"shareClipboard"])
		server.shareClipboard = [dictionary[@"shareClipboard"] boolValue];
	if (dictionary[@"sshEnabled"])
		server.sshEnabled = [dictionary[@"sshEnabled"] boolValue];
	server.sshHost = [server string:dictionary[@"sshHost"] fallback:@""];
	server.sshPort = [dictionary[@"sshPort"] integerValue] ?: 22;
	server.sshUsername = [server string:dictionary[@"sshUsername"] fallback:@""];
	server.sshAuth = [server string:dictionary[@"sshAuth"] fallback:@"key"];
	server.sshPublicKey = [server string:dictionary[@"sshPublicKey"] fallback:@""];
	server.certFingerprint = [server string:dictionary[@"certFingerprint"] fallback:@""];
	server.languageSetup = [server string:dictionary[@"languageSetup"] fallback:@""];
	if ([dictionary[@"profileBeforeExtreme"] isKindOfClass:[NSDictionary class]])
		server.profileBeforeExtreme = dictionary[@"profileBeforeExtreme"];
	if (server.host.length == 0)
		return nil;
	return server;
}

- (NSDictionary*)dictionaryRepresentation
{
	return @{
		@"id" : self.identifier ?: @"",
		@"name" : self.name ?: @"",
		@"host" : self.host ?: @"",
		@"port" : @(self.port),
		@"username" : self.username ?: @"",
		@"graphics" : self.graphics ?: @"economy",
		@"displayMode" : self.displayMode ?: @"fixed",
		@"width" : @(self.width),
		@"height" : @(self.height),
		@"colorDepth" : @(self.colorDepth),
		@"mapCommandToControl" : @(self.mapCommandToControl),
		@"autoReconnect" : @(self.autoReconnect),
		@"shareClipboard" : @(self.shareClipboard),
		@"sshEnabled" : @(self.sshEnabled),
		@"sshHost" : self.sshHost ?: @"",
		@"sshPort" : @(self.sshPort),
		@"sshUsername" : self.sshUsername ?: @"",
		@"sshAuth" : self.sshAuth ?: @"key",
		@"sshPublicKey" : self.sshPublicKey ?: @"",
		@"certFingerprint" : self.certFingerprint ?: @"",
		@"languageSetup" : self.languageSetup ?: @"",
		@"profileBeforeExtreme" : self.profileBeforeExtreme ?: @{}
	};
}

- (NSDictionary*)exportDictionary
{
	NSMutableDictionary* copy = [[self dictionaryRepresentation] mutableCopy];
	[copy removeObjectForKey:@"id"];
	[copy removeObjectForKey:@"sshPublicKey"];
	[copy removeObjectForKey:@"languageSetup"];
	[copy removeObjectForKey:@"profileBeforeExtreme"];
	return @{@"kind" : @"dalny-server", @"version" : @1, @"server" : copy};
}

+ (NSString*)profileHint:(NSString*)graphics
{
	if ([graphics isEqualToString:@"extreme"])
		return @"Экстремальная экономия: 640x480, 256 цветов (8 бит), без RemoteFX, обоев, тем, анимаций и сглаживания шрифтов; сжатие и кэш картинок включены. Для очень плохой связи. Чёрно-белого режима в RDP к xrdp нет, 256 цветов — самый лёгкий. Смена глубины цвета: сервер (xrdp) откроет отдельный сеанс, прежний останется на сервере, к нему можно вернуться прежним профилем.";
	if ([graphics isEqualToString:@"quality"])
		return @"Качество: 1920x1080, 32 бита, обои и сглаживание шрифтов.";
	if ([graphics isEqualToString:@"balanced"])
		return @"Сбалансированный: 1600x900, 32 бита, без обоев.";
	return @"Эконом: 1280x800, 16 бит, без обоев и тем.";
}

+ (int)profileIndex:(NSString*)graphics
{
	if ([graphics isEqualToString:@"extreme"])
		return 3;
	if ([graphics isEqualToString:@"quality"])
		return 2;
	if ([graphics isEqualToString:@"balanced"])
		return 1;
	return 0;
}

- (BOOL)isExtremeEconomy
{
	return [self.graphics isEqualToString:@"extreme"];
}

- (void)switchToExtremeEconomy
{
	if (self.isExtremeEconomy)
		return;
	self.profileBeforeExtreme = @{
		@"graphics" : self.graphics ?: @"economy",
		@"displayMode" : self.displayMode ?: @"fit",
		@"width" : @(self.width),
		@"height" : @(self.height),
		@"colorDepth" : @(self.colorDepth)
	};
	self.graphics = @"extreme";
	self.displayMode = @"fixed";
	[self applyGraphicsProfile];
}

- (BOOL)restoreProfileBeforeExtreme
{
	NSDictionary* saved = self.profileBeforeExtreme;
	if (!self.isExtremeEconomy || saved.count == 0)
		return NO;
	NSString* graphics = [saved[@"graphics"] isKindOfClass:[NSString class]] ? saved[@"graphics"] : @"economy";
	self.graphics = [graphics isEqualToString:@"extreme"] ? @"economy" : graphics;
	[self applyGraphicsProfile];
	if ([saved[@"displayMode"] isKindOfClass:[NSString class]])
		self.displayMode = saved[@"displayMode"];
	if ([saved[@"width"] integerValue] >= 200 && [saved[@"height"] integerValue] >= 200)
	{
		self.width = [saved[@"width"] integerValue];
		self.height = [saved[@"height"] integerValue];
	}
	NSInteger depth = [saved[@"colorDepth"] integerValue];
	if (depth == 16 || depth == 32)
		self.colorDepth = depth;
	self.profileBeforeExtreme = @{};
	return YES;
}

- (void)applyGraphicsProfile
{
	if ([self.graphics isEqualToString:@"extreme"])
	{
		self.colorDepth = 8;
		self.width = 640;
		self.height = 480;
	}
	else if ([self.graphics isEqualToString:@"quality"])
	{
		self.colorDepth = 32;
		self.width = 1920;
		self.height = 1080;
	}
	else if ([self.graphics isEqualToString:@"balanced"])
	{
		self.colorDepth = 32;
		self.width = 1600;
		self.height = 900;
	}
	else
	{
		self.graphics = @"economy";
		self.colorDepth = 16;
		self.width = 1280;
		self.height = 800;
	}
}

- (NSString*)rdpPasswordAccount
{
	return [@"rdp:" stringByAppendingString:self.identifier ?: @""];
}

- (NSString*)sshPasswordAccount
{
	return [@"ssh-password:" stringByAppendingString:self.identifier ?: @""];
}

- (NSString*)sshKeyAccount
{
	return [@"ssh-key:" stringByAppendingString:self.identifier ?: @""];
}

- (NSString*)effectiveSSHHost
{
	return self.sshHost.length > 0 ? self.sshHost : (self.host ?: @"");
}

- (NSString*)displayTitle
{
	if (self.name.length > 0)
		return self.name;
	return self.host.length > 0 ? self.host : @"Сервер";
}

@end
