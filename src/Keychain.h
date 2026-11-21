#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Keychain : NSObject
+ (BOOL)setSecret:(NSString*)secret account:(NSString*)account error:(NSError* _Nullable* _Nullable)error;
+ (nullable NSString*)secretForAccount:(NSString*)account error:(NSError* _Nullable* _Nullable)error;
+ (BOOL)deleteAccount:(NSString*)account error:(NSError* _Nullable* _Nullable)error;
@end

NS_ASSUME_NONNULL_END
