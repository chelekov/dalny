#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSHClient : NSObject
@property(nonatomic, readonly) int localPort;
@property(nonatomic, readonly) BOOL running;

+ (NSURL*)knownHostsURL;
+ (BOOL)generateEd25519PublicKey:(NSString* _Nullable* _Nullable)publicKey
                      privateKey:(NSString* _Nullable* _Nullable)privateKey
                           error:(NSError* _Nullable* _Nullable)error;

- (BOOL)startHost:(NSString*)host
             port:(int)port
         username:(NSString*)username
       remotePort:(int)remotePort
           keyPEM:(nullable NSString*)keyPEM
         password:(nullable NSString*)password
          askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
              log:(void (^)(NSString* line))log
            error:(NSError* _Nullable* _Nullable)error;

- (void)stop;
/* Tunnel still running? Also forwards new ssh stderr lines to the log. NO once ssh has exited. */
- (BOOL)checkAlive;

+ (BOOL)installPublicKey:(NSString*)publicKey
                    host:(NSString*)host
                    port:(int)port
                username:(NSString*)username
                password:(NSString*)password
                 askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
                     log:(void (^)(NSString* line))log
                   error:(NSError* _Nullable* _Nullable)error;

/* Runs a POSIX sh script on the server as the SSH user (no sudo). Key or password auth, same
 * known_hosts rules as the tunnel. Returns stdout and stderr together, or nil on an SSH failure. */
+ (nullable NSString*)runScript:(NSString*)script
                           host:(NSString*)host
                           port:(int)port
                       username:(NSString*)username
                         keyPEM:(nullable NSString*)keyPEM
                       password:(nullable NSString*)password
                        askHost:(BOOL (^)(NSString* fingerprint, BOOL changed))askHost
                            log:(void (^)(NSString* line))log
                          error:(NSError* _Nullable* _Nullable)error;
@end

NS_ASSUME_NONNULL_END
