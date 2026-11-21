#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DalnyServer : NSObject
@property(nonatomic, copy) NSString* identifier;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* host;
@property(nonatomic) NSInteger port;
@property(nonatomic, copy) NSString* username;
@property(nonatomic, copy) NSString* graphics;
@property(nonatomic, copy) NSString* displayMode;
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@property(nonatomic) NSInteger colorDepth;
@property(nonatomic) BOOL mapCommandToControl;
@property(nonatomic) BOOL autoReconnect;
@property(nonatomic) BOOL shareClipboard;
@property(nonatomic) BOOL sshEnabled;
@property(nonatomic, copy) NSString* sshHost;
@property(nonatomic) NSInteger sshPort;
@property(nonatomic, copy) NSString* sshUsername;
@property(nonatomic, copy) NSString* sshAuth;
@property(nonatomic, copy) NSString* sshPublicKey;
@property(nonatomic, copy) NSString* certFingerprint;
/* Language switch setup on the server: "" not asked yet, "done", "declined". */
@property(nonatomic, copy) NSString* languageSetup;
/* Profile (graphics, displayMode, width, height, colorDepth) saved when switching to "extreme",
 * so the session window can switch back. Empty when not in use. Not exported. */
@property(nonatomic, copy) NSDictionary* profileBeforeExtreme;

+ (instancetype)newServer;
- (NSDictionary*)dictionaryRepresentation;
- (NSDictionary*)exportDictionary;
+ (nullable instancetype)serverFromDictionary:(NSDictionary*)dictionary newIdentity:(BOOL)newIdentity;
- (void)applyGraphicsProfile;
/* graphics: "economy" (16 bpp), "balanced", "quality" (32 bpp), "extreme" (640x480, 8 bpp). */
+ (NSString*)profileHint:(NSString*)graphics;
+ (int)profileIndex:(NSString*)graphics;
- (BOOL)isExtremeEconomy;
- (void)switchToExtremeEconomy;
- (BOOL)restoreProfileBeforeExtreme;
- (NSString*)rdpPasswordAccount;
- (NSString*)sshPasswordAccount;
- (NSString*)sshKeyAccount;
- (NSString*)effectiveSSHHost;
- (NSString*)displayTitle;
@end

NS_ASSUME_NONNULL_END
