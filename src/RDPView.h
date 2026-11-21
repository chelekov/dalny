#import <Cocoa/Cocoa.h>
#import "session.h"

NS_ASSUME_NONNULL_BEGIN

@interface RDPView : NSView
@property(nonatomic, assign) RDPSession* session;
@property(nonatomic) BOOL mapCommandToControl;
@property(nonatomic) BOOL fitDisplay;
- (void)updateFrameWithBytes:(const uint8_t*)bytes
                       width:(int)width
                      height:(int)height
                      stride:(int)stride;
- (void)releaseAllKeys;
- (void)noteRemoteSizeWidth:(int)width height:(int)height;
@end

NS_ASSUME_NONNULL_END
