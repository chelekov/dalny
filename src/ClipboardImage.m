#import "ClipboardImage.h"

static uint32_t read_le32(const uint8_t* p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t read_le16(const uint8_t* p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

static void put_le32(uint8_t* p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static void put_le16(uint8_t* p, uint16_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

@implementation ClipboardImage

+ (NSData*)bmpFileFromDIB:(NSData*)dib
{
	if (dib.length < 40)
		return nil;
	const uint8_t* bytes = dib.bytes;
	uint32_t headerSize = read_le32(bytes);
	if (headerSize < 40 || headerSize > dib.length)
		return nil;
	uint16_t bitCount = read_le16(bytes + 14);
	uint32_t compression = read_le32(bytes + 16);
	uint32_t colorsUsed = read_le32(bytes + 32);
	uint32_t masks = 0;
	/* BI_BITFIELDS (3) and BI_ALPHABITFIELDS (6) put the masks after a 40-byte header.
	 * V4 and V5 headers carry them inside the header. */
	if (headerSize == 40 && compression == 3)
		masks = 12;
	else if (headerSize == 40 && compression == 6)
		masks = 16;
	uint32_t colors = colorsUsed;
	if (colors == 0 && bitCount <= 8)
		colors = 1u << bitCount;
	uint64_t offset = 14ull + headerSize + masks + 4ull * colors;
	if (offset > 14ull + dib.length)
		return nil;
	NSMutableData* file = [NSMutableData dataWithLength:14];
	uint8_t* head = file.mutableBytes;
	head[0] = 'B';
	head[1] = 'M';
	put_le32(head + 2, (uint32_t)(14 + dib.length));
	put_le32(head + 10, (uint32_t)offset);
	[file appendData:dib];
	return file;
}

+ (BOOL)isLinkText:(NSString*)text
{
	NSString* trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (trimmed.length == 0 || trimmed.length > 8192)
		return NO;
	if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
		return NO;
	NSString* lower = trimmed.lowercaseString;
	for (NSString* scheme in @[ @"http://", @"https://", @"file://", @"data:", @"blob:" ])
		if ([lower hasPrefix:scheme])
			return YES;
	return NO;
}

+ (BOOL)writeDIB:(NSData*)dib toPasteboard:(NSPasteboard*)pasteboard
{
	NSData* bmp = [self bmpFileFromDIB:dib];
	if (!bmp)
		return NO;
	NSBitmapImageRep* rep = [NSBitmapImageRep imageRepWithData:bmp];
	if (!rep || rep.pixelsWide <= 0 || rep.pixelsHigh <= 0)
		return NO;
	NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	NSData* tiff = [rep TIFFRepresentation];
	if (!png && !tiff)
		return NO;
	[pasteboard clearContents];
	NSMutableArray* types = [NSMutableArray array];
	if (png)
		[types addObject:NSPasteboardTypePNG];
	if (tiff)
		[types addObject:NSPasteboardTypeTIFF];
	[pasteboard declareTypes:types owner:nil];
	if (png)
		[pasteboard setData:png forType:NSPasteboardTypePNG];
	if (tiff)
		[pasteboard setData:tiff forType:NSPasteboardTypeTIFF];
	return YES;
}

+ (NSData*)dibFromPasteboard:(NSPasteboard*)pasteboard maxPixels:(NSUInteger)maxPixels reason:(NSString**)reason
{
	if (reason)
		*reason = nil;
	if ([pasteboard availableTypeFromArray:@[ NSPasteboardTypeFileURL ]])
	{
		if (reason)
			*reason = @"Файлы через буфер обмена не передаются, только текст и картинки.";
		return nil;
	}
	/* Screenshots (⌘⌃⇧4) put PNG, Preview and Safari put TIFF (often PNG too). Anything else
	 * NSImage can read (JPEG, HEIC, PDF from Preview) is drawn into a bitmap, but only when there
	 * is no text: rich text from editors also carries a PDF picture of itself. */
	CGImageRef image = NULL;
	NSString* type = [pasteboard availableTypeFromArray:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF ]];
	NSData* data = type ? [pasteboard dataForType:type] : nil;
	NSBitmapImageRep* rep __attribute__((objc_precise_lifetime)) = data.length ? [NSBitmapImageRep imageRepWithData:data] : nil;
	image = rep.CGImage;
	/* Keeps the CGImage below alive until the end of the method. */
	NSImage* fallback __attribute__((objc_precise_lifetime)) = nil;
	if (!image && ![pasteboard availableTypeFromArray:@[ NSPasteboardTypeString ]] &&
	    [NSImage canInitWithPasteboard:pasteboard])
	{
		fallback = [[NSImage alloc] initWithPasteboard:pasteboard];
		NSRect rect = NSMakeRect(0, 0, fallback.size.width, fallback.size.height);
		if (fallback && rect.size.width >= 1 && rect.size.height >= 1)
			image = [fallback CGImageForProposedRect:&rect context:nil hints:nil];
	}
	if (!image)
		return nil;
	size_t width = CGImageGetWidth(image);
	size_t height = CGImageGetHeight(image);
	if (width == 0 || height == 0)
		return nil;
	if ((unsigned long long)width * height > maxPixels)
	{
		if (reason)
			*reason = [NSString stringWithFormat:@"Картинка %zux%zu слишком большая для буфера обмена.", width, height];
		return nil;
	}

	/* Draw on white so transparent areas do not turn black, then write 24-bit BGR rows
	 * bottom-up, each padded to 4 bytes. 24-bit BI_RGB is what every BMP reader accepts. */
	size_t rgbaStride = width * 4;
	NSMutableData* rgba = [NSMutableData dataWithLength:rgbaStride * height];
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes, width, height, 8, rgbaStride, space,
	                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(space);
	if (!context)
		return nil;
	CGContextSetRGBFillColor(context, 1, 1, 1, 1);
	CGContextFillRect(context, CGRectMake(0, 0, width, height));
	CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
	CGContextRelease(context);

	size_t rowSize = (width * 3 + 3) & ~(size_t)3;
	size_t pixelBytes = rowSize * height;
	NSMutableData* dib = [NSMutableData dataWithLength:40 + pixelBytes];
	uint8_t* out = dib.mutableBytes;
	put_le32(out + 0, 40);
	put_le32(out + 4, (uint32_t)width);
	put_le32(out + 8, (uint32_t)height); /* positive: bottom-up */
	put_le16(out + 12, 1);
	put_le16(out + 14, 24);
	put_le32(out + 16, 0); /* BI_RGB */
	put_le32(out + 20, (uint32_t)pixelBytes);
	put_le32(out + 24, 2835); /* 72 dpi */
	put_le32(out + 28, 2835);
	const uint8_t* src = rgba.bytes;
	uint8_t* pixels = out + 40;
	/* The bitmap context's first row in memory is the top of the picture. */
	for (size_t y = 0; y < height; y++)
	{
		const uint8_t* row = src + y * rgbaStride;
		uint8_t* dst = pixels + (height - 1 - y) * rowSize;
		for (size_t x = 0; x < width; x++)
		{
			dst[x * 3 + 0] = row[x * 4 + 2];
			dst[x * 3 + 1] = row[x * 4 + 1];
			dst[x * 3 + 2] = row[x * 4 + 0];
		}
	}
	return dib;
}

@end
