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

+ (instancetype)newServer;
- (NSDictionary*)dictionaryRepresentation;
- (NSDictionary*)exportDictionary;
+ (nullable instancetype)serverFromDictionary:(NSDictionary*)dictionary newIdentity:(BOOL)newIdentity;
- (void)applyGraphicsProfile;
- (NSString*)rdpPasswordAccount;
- (NSString*)sshPasswordAccount;
- (NSString*)sshKeyAccount;
- (NSString*)effectiveSSHHost;
- (NSString*)displayTitle;
@end

NS_ASSUME_NONNULL_END
