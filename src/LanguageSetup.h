#import <Cocoa/Cocoa.h>
#import "Server.h"

NS_ASSUME_NONNULL_BEGIN

/* Turns on the us,ru layouts with grp:alt_shift_toggle for the SSH user on the server.
 * No sudo: XFCE xfconf (keyboard-layout channel) plus setxkbmap on the user's xrdp display. */
@interface LanguageSetup : NSObject
/* The script that runs on the server. Also shown in the README. */
+ (NSString*)remoteScript;
/* Runs on a background queue. log is called from any thread. done runs on the main queue. */
+ (void)runForServer:(DalnyServer*)server
                 log:(void (^)(NSString* line))log
                done:(void (^)(BOOL ok, NSString* title, NSString* detail))done;
/* Runs and shows the result in an alert (a sheet when window is given). */
+ (void)runInteractiveForServer:(DalnyServer*)server
                         window:(nullable NSWindow*)window
                            log:(void (^)(NSString* line))log;
@end

NS_ASSUME_NONNULL_END
