#import <Cocoa/Cocoa.h>
#import "Server.h"

NS_ASSUME_NONNULL_BEGIN

/* One-click server setup for the SSH user, no sudo (scripts in Contents/Resources/server):
 * - keyboard: us,ru with grp:alt_shift_toggle in XFCE, in the live session, and kept there by a
 *   small watcher (xorgxrdp loads plain "us" on every reconnect; ibus is told to leave XKB alone);
 * - pictures: a helper adds image/png next to xrdp's image/bmp (and back) in the X clipboard. */
@interface LanguageSetup : NSObject
/* The script that runs on the server, helpers included. nil when the bundle lacks them. */
+ (nullable NSString*)remoteScript;
/* Runs on a background queue. log is called from any thread. done runs on the main queue.
 * quiet: no host-key questions (the session already confirmed the key). */
+ (void)runForServer:(DalnyServer*)server
               quiet:(BOOL)quiet
                 log:(void (^)(NSString* line))log
                done:(void (^)(BOOL ok, NSString* title, NSString* detail))done;
/* Runs and shows the result in an alert (a sheet when window is given). */
+ (void)runInteractiveForServer:(DalnyServer*)server
                         window:(nullable NSWindow*)window
                            log:(void (^)(NSString* line))log;
/* After each connect of a server that was set up: install or restart the helpers if needed.
 * Writes to the log only. */
+ (void)ensureForServer:(DalnyServer*)server log:(void (^)(NSString* line))log;
@end

NS_ASSUME_NONNULL_END
