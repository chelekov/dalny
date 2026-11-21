#import <Cocoa/Cocoa.h>
#import "Server.h"

NS_ASSUME_NONNULL_BEGIN

@interface ServerEditor : NSWindowController
- (instancetype)initWithServer:(DalnyServer*)server;
@property(nonatomic, copy, nullable) void (^onSave)(DalnyServer* server);
@end

NS_ASSUME_NONNULL_END
