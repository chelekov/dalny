#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Updater : NSObject
+ (NSString*)tokenAccount;
+ (void)checkSilently;
+ (void)checkInteractively;
@end

NS_ASSUME_NONNULL_END
