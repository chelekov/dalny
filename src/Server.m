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
	server.colorDepth = [dictionary[@"colorDepth"] integerValue] == 32 ? 32 : 16;
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
		@"certFingerprint" : self.certFingerprint ?: @""
	};
}

- (NSDictionary*)exportDictionary
{
	NSMutableDictionary* copy = [[self dictionaryRepresentation] mutableCopy];
	[copy removeObjectForKey:@"id"];
	[copy removeObjectForKey:@"sshPublicKey"];
	return @{@"kind" : @"dalny-server", @"version" : @1, @"server" : copy};
}

- (void)applyGraphicsProfile
{
	if ([self.graphics isEqualToString:@"quality"])
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
