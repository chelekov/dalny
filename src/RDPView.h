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
/* Sends left Alt + left Shift to the server (grp:alt_shift_toggle). Held modifiers are released
 * on the server first so the server sees exactly Alt+Shift. */
- (void)sendLanguageToggle;
/* Cmd+Shift+Space: the Mac shortcut for the language switch menu item. */
+ (BOOL)isLanguageShortcut:(NSEvent*)event;
- (void)noteRemoteSizeWidth:(int)width height:(int)height;
@end

NS_ASSUME_NONNULL_END
