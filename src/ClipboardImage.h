#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/* Pictures between the Mac pasteboard and RDP CF_DIB. CF_DIB is a BMP file without its
 * 14-byte BITMAPFILEHEADER. xrdp 0.9 adds or strips that header and shows the picture to X
 * applications as image/bmp. */
@interface ClipboardImage : NSObject
/* PNG or TIFF (or, without text, any picture NSImage reads) -> 24-bit bottom-up CF_DIB. nil when there is no picture,
 * when the pasteboard holds files (Finder puts the file icon there too), or when the picture is
 * larger than maxPixels. */
+ (nullable NSData*)dibFromPasteboard:(NSPasteboard*)pasteboard
                            maxPixels:(NSUInteger)maxPixels
                               reason:(NSString* _Nullable* _Nullable)reason;
/* CF_DIB or CF_DIBV5 -> PNG and TIFF on the pasteboard. Returns NO when the data is not a picture. */
+ (BOOL)writeDIB:(NSData*)dib toPasteboard:(NSPasteboard*)pasteboard;
/* A single link (what browsers put next to a copied picture). Such text is not sent with the
 * picture, so server apps paste the picture instead of the link. */
+ (BOOL)isLinkText:(NSString*)text;
/* CF_DIB -> BMP file bytes. Exposed for tests and logging. */
+ (nullable NSData*)bmpFileFromDIB:(NSData*)dib;
@end

NS_ASSUME_NONNULL_END
