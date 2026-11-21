#import <Foundation/Foundation.h>
#import "Server.h"

NS_ASSUME_NONNULL_BEGIN

@interface ServerStore : NSObject
@property(nonatomic, readonly) NSMutableArray<DalnyServer*>* servers;
+ (instancetype)sharedStore;
- (void)save;
- (void)addServer:(DalnyServer*)server;
- (void)removeServer:(DalnyServer*)server;
- (nullable DalnyServer*)serverWithIdentifier:(NSString*)identifier;
@end

NS_ASSUME_NONNULL_END
