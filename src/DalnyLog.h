#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DalnyLog : NSObject
+ (void)append:(NSString*)line;
+ (NSString*)text;
+ (void)showWindow;
@end

NS_ASSUME_NONNULL_END
