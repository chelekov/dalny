#import "ServerStore.h"

@implementation ServerStore

+ (instancetype)sharedStore
{
	static ServerStore* store;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		store = [ServerStore new];
		[store load];
	});
	return store;
}

+ (NSURL*)fileURL
{
	NSFileManager* files = [NSFileManager defaultManager];
	NSURL* base = [[files URLsForDirectory:NSApplicationSupportDirectory
	                             inDomains:NSUserDomainMask] firstObject];
	NSURL* folder = [base URLByAppendingPathComponent:@"Dalny" isDirectory:YES];
	[files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	return [folder URLByAppendingPathComponent:@"servers.json"];
}

- (void)load
{
	_servers = [NSMutableArray array];
	NSData* data = [NSData dataWithContentsOfURL:[ServerStore fileURL]];
	if (!data)
		return;
	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
	NSArray* list = [json isKindOfClass:[NSArray class]] ? json : nil;
	for (id item in list)
	{
		DalnyServer* server = [DalnyServer serverFromDictionary:item newIdentity:NO];
		if (server)
			[_servers addObject:server];
	}
}

- (void)save
{
	NSMutableArray* list = [NSMutableArray array];
	for (DalnyServer* server in self.servers)
		[list addObject:[server dictionaryRepresentation]];
	NSData* data = [NSJSONSerialization dataWithJSONObject:list options:NSJSONWritingPrettyPrinted error:NULL];
	if (!data)
		return;
	[data writeToURL:[ServerStore fileURL] atomically:YES];
}

- (void)addServer:(DalnyServer*)server
{
	if (!server)
		return;
	[self.servers addObject:server];
	[self save];
}

- (void)removeServer:(DalnyServer*)server
{
	[self.servers removeObject:server];
	[self save];
}

- (DalnyServer*)serverWithIdentifier:(NSString*)identifier
{
	for (DalnyServer* server in self.servers)
	{
		if ([server.identifier isEqualToString:identifier])
			return server;
	}
	return nil;
}

@end
