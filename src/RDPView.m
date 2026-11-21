#import "RDPView.h"
#import "AppleKeyboard.h"
#import <freerdp/scancode.h>

static const NSEventModifierFlags kFlagLShift = 0x000002;
static const NSEventModifierFlags kFlagRShift = 0x000004;
static const NSEventModifierFlags kFlagLCmd = 0x000008;
static const NSEventModifierFlags kFlagRCmd = 0x000010;
static const NSEventModifierFlags kFlagLAlt = 0x000020;
static const NSEventModifierFlags kFlagRAlt = 0x000040;
static const NSEventModifierFlags kFlagLCtl = 0x000001;
static const NSEventModifierFlags kFlagRCtl = 0x00002000;

@implementation RDPView
{
	NSLock* _lock;
	int _remoteWidth;
	int _remoteHeight;
	CGImageRef _image;
	NSMutableDictionary<NSNumber*, NSNumber*>* _scancodeDown;
	NSEventModifierFlags _previousFlags;
	BOOL _isoKeyboard;
	NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self)
	{
		_lock = [NSLock new];
		_scancodeDown = [NSMutableDictionary dictionary];
		_mapCommandToControl = YES;
		_isoKeyboard = dalny_mac_keyboard_is_iso();
		self.wantsLayer = YES;
		self.layer.backgroundColor = NSColor.blackColor.CGColor;
	}
	return self;
}

- (void)dealloc
{
	if (_image)
		CGImageRelease(_image);
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)isFlipped
{
	return NO;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking)
		[self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc]
	    initWithRect:self.bounds
	         options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
	                 NSTrackingMouseEnteredAndExited
	           owner:self
	        userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)noteRemoteSizeWidth:(int)width height:(int)height
{
	_remoteWidth = width;
	_remoteHeight = height;
}

- (void)updateFrameWithBytes:(const uint8_t*)bytes
                       width:(int)width
                      height:(int)height
                      stride:(int)stride
{
	if (!bytes || width <= 0 || height <= 0 || stride < width * 4)
		return;
	_remoteWidth = width;
	_remoteHeight = height;
	size_t bytesNeeded = (size_t)stride * (size_t)height;
	CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, bytesNeeded);
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
	CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)stride, space,
	                                 kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider,
	                                 NULL, false, kCGRenderingIntentDefault);
	CGDataProviderRelease(provider);
	CGColorSpaceRelease(space);
	CFRelease(data);
	[_lock lock];
	if (_image)
		CGImageRelease(_image);
	_image = image;
	CGImageRef shown = image ? CGImageRetain(image) : NULL;
	[_lock unlock];
	dispatch_async(dispatch_get_main_queue(), ^{
		self.layer.contents = shown ? (__bridge id)shown : nil;
		if (shown)
			CGImageRelease(shown);
	});
}

- (NSRect)imageRect
{
	if (_remoteWidth <= 0 || _remoteHeight <= 0)
		return self.bounds;
	NSRect bounds = self.bounds;
	CGFloat scale = MIN(bounds.size.width / _remoteWidth, bounds.size.height / _remoteHeight);
	if (!_fitDisplay)
		scale = MIN(scale, 1.0);
	CGFloat width = _remoteWidth * scale;
	CGFloat height = _remoteHeight * scale;
	return NSMakeRect(NSMidX(bounds) - width / 2.0, NSMidY(bounds) - height / 2.0, width, height);
}

- (BOOL)mapPoint:(NSPoint)point toX:(int*)x y:(int*)y
{
	NSRect image = [self imageRect];
	if (image.size.width < 1 || image.size.height < 1 || _remoteWidth <= 0)
		return NO;
	if (!NSPointInRect(point, image))
		return NO;
	CGFloat rx = (point.x - image.origin.x) / image.size.width * _remoteWidth;
	CGFloat ry = (image.origin.y + image.size.height - point.y) / image.size.height * _remoteHeight;
	*x = (int)rx;
	*y = (int)ry;
	return YES;
}

- (void)sendMouseAt:(NSEvent*)event button:(int)button down:(int)down
{
	if (!self.session)
		return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	int x = 0;
	int y = 0;
	if (![self mapPoint:point toX:&x y:&y])
		return;
	rdp_session_send_mouse(self.session, x, y, button, down);
}

- (void)mouseMoved:(NSEvent*)event
{
	[self sendMouseAt:event button:0 down:0];
}

- (void)mouseDragged:(NSEvent*)event
{
	[self sendMouseAt:event button:0 down:0];
}

- (void)rightMouseDragged:(NSEvent*)event
{
	[self sendMouseAt:event button:0 down:0];
}

- (void)mouseDown:(NSEvent*)event
{
	[self.window makeFirstResponder:self];
	[self sendMouseAt:event button:1 down:1];
}

- (void)mouseUp:(NSEvent*)event
{
	[self sendMouseAt:event button:1 down:0];
}

- (void)rightMouseDown:(NSEvent*)event
{
	[self sendMouseAt:event button:2 down:1];
}

- (void)rightMouseUp:(NSEvent*)event
{
	[self sendMouseAt:event button:2 down:0];
}

- (void)otherMouseDown:(NSEvent*)event
{
	[self sendMouseAt:event button:3 down:1];
}

- (void)otherMouseUp:(NSEvent*)event
{
	[self sendMouseAt:event button:3 down:0];
}

- (void)scrollWheel:(NSEvent*)event
{
	if (!self.session)
		return;
	CGFloat delta = event.scrollingDeltaY;
	if (event.hasPreciseScrollingDeltas)
		delta /= 8.0;
	int notches = (int)lround(delta);
	if (notches == 0)
		return;
	if (notches > 3)
		notches = 3;
	if (notches < -3)
		notches = -3;
	rdp_session_send_wheel(self.session, notches);
}

- (uint32_t)scancodeForMask:(NSEventModifierFlags)mask
{
	BOOL map = self.mapCommandToControl;
	if (mask == kFlagLShift)
		return RDP_SCANCODE_LSHIFT;
	if (mask == kFlagRShift)
		return RDP_SCANCODE_RSHIFT;
	if (mask == kFlagLCtl)
		return RDP_SCANCODE_LCONTROL;
	if (mask == kFlagRCtl)
		return RDP_SCANCODE_RCONTROL;
	if (mask == kFlagLAlt)
		return RDP_SCANCODE_LMENU;
	if (mask == kFlagRAlt)
		return RDP_SCANCODE_RMENU;
	if (mask == kFlagLCmd)
		return map ? RDP_SCANCODE_LCONTROL : RDP_SCANCODE_LWIN;
	if (mask == kFlagRCmd)
		return map ? RDP_SCANCODE_RCONTROL : RDP_SCANCODE_RWIN;
	return 0;
}

- (void)setScancode:(uint32_t)scancode down:(BOOL)down
{
	if (!self.session || scancode == 0)
		return;
	NSNumber* key = @(scancode);
	NSInteger count = [_scancodeDown[key] integerValue];
	if (down)
	{
		if (count == 0)
			rdp_session_send_scancode(self.session, scancode, 1, 0);
		_scancodeDown[key] = @(count + 1);
	}
	else if (count > 0)
	{
		count -= 1;
		if (count == 0)
		{
			rdp_session_send_scancode(self.session, scancode, 0, 0);
			[_scancodeDown removeObjectForKey:key];
		}
		else
		{
			_scancodeDown[key] = @(count);
		}
	}
}

- (void)flagsChanged:(NSEvent*)event
{
	NSEventModifierFlags flags = event.modifierFlags;
	if ((flags & NSEventModifierFlagCapsLock) != (_previousFlags & NSEventModifierFlagCapsLock))
	{
		rdp_session_send_scancode(self.session, RDP_SCANCODE_CAPSLOCK, 1, 0);
		rdp_session_send_scancode(self.session, RDP_SCANCODE_CAPSLOCK, 0, 0);
	}
	NSEventModifierFlags masks[] = {kFlagLShift, kFlagRShift, kFlagLCtl, kFlagRCtl,
	                                kFlagLAlt,   kFlagRAlt,   kFlagLCmd, kFlagRCmd};
	for (int i = 0; i < 8; i++)
	{
		BOOL was = (_previousFlags & masks[i]) != 0;
		BOOL now = (flags & masks[i]) != 0;
		if (was == now)
			continue;
		uint32_t scancode = [self scancodeForMask:masks[i]];
		[self setScancode:scancode down:now];
	}
	_previousFlags = flags;
}

- (void)sendKey:(NSEvent*)event down:(BOOL)down
{
	if (!self.session)
		return;
	uint32_t scancode = dalny_scancode_for_mac_key((uint32_t)event.keyCode, _isoKeyboard);
	if (scancode == 0)
		return;
	rdp_session_send_scancode(self.session, scancode, down ? 1 : 0, down && event.isARepeat);
}

- (void)keyDown:(NSEvent*)event
{
	[self flagsChanged:event];
	[self sendKey:event down:YES];
}

- (void)keyUp:(NSEvent*)event
{
	[self sendKey:event down:NO];
}

+ (BOOL)isLanguageShortcut:(NSEvent*)event
{
	if (event.type != NSEventTypeKeyDown || event.keyCode != 49) /* kVK_Space */
		return NO;
	NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
	                                                   NSEventModifierFlagOption | NSEventModifierFlagControl);
	return mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
}

- (void)sendLanguageToggle
{
	if (!self.session)
		return;
	for (NSNumber* key in [_scancodeDown allKeys])
		rdp_session_send_scancode(self.session, key.unsignedIntValue, 0, 0);
	[_scancodeDown removeAllObjects];
	/* Keys still held on the Mac count as already handled: releasing them sends nothing. */
	_previousFlags = (NSEventModifierFlags)CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & (kFlagLShift | kFlagRShift | kFlagLCmd | kFlagRCmd | kFlagLAlt |
	                                            kFlagRAlt | kFlagLCtl | kFlagRCtl | NSEventModifierFlagCapsLock);
	rdp_session_send_language_toggle(self.session);
}

- (BOOL)performKeyEquivalent:(NSEvent*)event
{
	/* Leave the language shortcut to the menu item. */
	if ([RDPView isLanguageShortcut:event])
		return NO;
	if (!self.mapCommandToControl || !(event.modifierFlags & NSEventModifierFlagCommand))
		return NO;
	if (event.type == NSEventTypeKeyDown)
	{
		[self flagsChanged:event];
		[self sendKey:event down:YES];
	}
	return YES;
}

- (void)releaseAllKeys
{
	for (NSNumber* key in [_scancodeDown allKeys])
		rdp_session_send_scancode(self.session, key.unsignedIntValue, 0, 0);
	[_scancodeDown removeAllObjects];
	_previousFlags = 0;
}

- (BOOL)resignFirstResponder
{
	[self releaseAllKeys];
	return [super resignFirstResponder];
}

@end
