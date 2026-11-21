#import <Cocoa/Cocoa.h>
#import "Server.h"

NS_ASSUME_NONNULL_BEGIN

@interface SessionWindow : NSWindowController
- (instancetype)initWithServer:(DalnyServer*)server;
@end

NS_ASSUME_NONNULL_END
