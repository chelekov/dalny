#import "DalnyLog.h"
#import <Cocoa/Cocoa.h>

@implementation DalnyLog

+ (NSMutableString*)buffer
{
	static NSMutableString* text;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		text = [NSMutableString string];
	});
	return text;
}

+ (NSTextView*)textView
{
	static NSTextView* view;
	static NSWindow* window;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360)
		                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
		                                               NSWindowStyleMaskResizable
		                                       backing:NSBackingStoreBuffered
		                                         defer:NO];
		window.title = @"Журнал";
		NSScrollView* scroll = [NSTextView scrollableTextView];
		scroll.frame = window.contentView.bounds;
		scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		view = (NSTextView*)scroll.documentView;
		view.editable = NO;
		view.richText = NO;
		view.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
		[window.contentView addSubview:scroll];
	});
	return view;
}

+ (void)append:(NSString*)line
{
	if (line.length == 0)
		return;
	dispatch_async(dispatch_get_main_queue(), ^{
		NSDateFormatter* formatter = [NSDateFormatter new];
		formatter.dateFormat = @"HH:mm:ss";
		NSString* row = [NSString stringWithFormat:@"%@  %@\n", [formatter stringFromDate:[NSDate date]], line];
		[[self buffer] appendString:row];
		NSTextView* view = [self textView];
		[view.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:row]];
		[view scrollRangeToVisible:NSMakeRange(view.string.length, 0)];
	});
}

+ (NSString*)text
{
	return [[self buffer] copy];
}

+ (void)showWindow
{
	NSWindow* window = [self textView].window;
	[window center];
	[window makeKeyAndOrderFront:nil];
}

@end
