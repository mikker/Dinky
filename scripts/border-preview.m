#import <AppKit/AppKit.h>
#import "../Sources/DinkyPrivate/border_path.h"
#import "../Sources/DinkyPrivate/skylight.h"

extern CFArrayRef SLSWindowIteratorGetCornerRadii(CFTypeRef iterator) __attribute__((weak_import));

@interface BorderView : NSView
@property double correction;
@property double width;
@property int radius;
@end
@implementation BorderView
- (void)drawRect:(NSRect)dirtyRect
{
	CGContextRef context = NSGraphicsContext.currentContext.CGContext;
	CGContextClearRect(context, self.bounds);
	CGPathRef ring = dinky_border_path(self.bounds, self.radius, self.width, self.correction);
	CGContextSetRGBFillColor(context, 0, 122.0 / 255, 1, 1);
	CGContextAddPath(context, ring);
	CGContextEOFillPath(context);
	CGPathRelease(ring);
}
@end

@interface Preview : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property NSPanel *border;
@property BorderView *borderView;
@property NSTextField *label;
@property NSTextField *widthLabel;
@property NSSlider *widthSlider;
@property NSInteger percent;
@property NSInteger lastPercent;
@end
@implementation Preview
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	self.percent = 5;
	self.lastPercent = 5;
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
		backing:NSBackingStoreBuffered defer:NO];
	self.window.title = @"Dinky border comparison";
	self.window.contentMinSize = NSMakeSize(640, 480);
	// A floating test window stays outside Dinky's normal-window tiling and borders.
	self.window.level = NSFloatingWindowLevel;
	self.window.delegate = self;
	self.window.releasedWhenClosed = NO;
	self.label = [NSTextField labelWithString:@""];
	self.label.font = [NSFont systemFontOfSize:24];
	self.label.frame = NSMakeRect(32, 350, 570, 40);
	[self.window.contentView addSubview:self.label];
	NSTextField *help = [NSTextField wrappingLabelWithString:@"Choose a correction below. Space toggles it against 0%.\nAdjust the border width and inspect the corners.\n\nYour running Dinky is unchanged. Close this window to finish."];
	help.frame = NSMakeRect(32, 230, 570, 110);
	[self.window.contentView addSubview:help];
	self.widthLabel = [NSTextField labelWithString:@"Border width: 4 pt"];
	self.widthLabel.frame = NSMakeRect(32, 190, 570, 24);
	[self.window.contentView addSubview:self.widthLabel];
	self.widthSlider = [NSSlider sliderWithValue:4 minValue:1 maxValue:16 target:self action:@selector(changeWidth:)];
	self.widthSlider.continuous = YES;
	self.widthSlider.frame = NSMakeRect(32, 155, 552, 28);
	[self.widthSlider setAccessibilityLabel:@"Border width in points"];
	[self.window.contentView addSubview:self.widthSlider];
	NSButton *toggle = [NSButton buttonWithTitle:@"Toggle original / correction" target:self action:@selector(toggle:)];
	toggle.keyEquivalent = @" ";
	toggle.frame = NSMakeRect(32, 75, 250, 36);
	[self.window.contentView addSubview:toggle];
	NSArray<NSNumber *> *percentages = @[@0, @5, @6, @7, @8, @9, @10];
	for (NSUInteger i = 0; i < percentages.count; i++) {
		NSInteger percent = percentages[i].integerValue;
		NSButton *button = [NSButton buttonWithTitle:[NSString stringWithFormat:@"%ld%%", (long)percent] target:self action:@selector(selectPercent:)];
		button.tag = percent;
		button.frame = NSMakeRect(32 + i * 80, 25, 72, 36);
		[self.window.contentView addSubview:button];
	}
	self.border = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
	self.border.level = NSFloatingWindowLevel;
	self.border.opaque = NO;
	self.border.backgroundColor = NSColor.clearColor;
	self.border.hasShadow = NO;
	self.border.ignoresMouseEvents = YES;
	self.border.hidesOnDeactivate = NO;
	self.borderView = [[BorderView alloc] initWithFrame:NSZeroRect];
	self.border.contentView = self.borderView;
	[self.window center];
	[self.window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
	[self update];
}
- (void)update
{
	// Read the same first integer corner radius used by Dinky, for this actual native window.
	NSArray *ids = @[@(self.window.windowNumber)];
	CFTypeRef query = SLSWindowQueryWindows(SLSMainConnectionID(), (__bridge CFArrayRef)ids, 1);
	CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
	if (iterator && SLSWindowIteratorAdvance(iterator) && SLSWindowIteratorGetCornerRadii) {
		CFArrayRef radii = SLSWindowIteratorGetCornerRadii(iterator);
		if (radii && CFArrayGetCount(radii)) {
			int radius = 0;
			CFNumberGetValue(CFArrayGetValueAtIndex(radii, 0), kCFNumberIntType, &radius);
			self.borderView.radius = radius;
		}
		if (radii) CFRelease(radii);
	}
	if (iterator) CFRelease(iterator);
	if (query) CFRelease(query);
	self.label.stringValue = self.percent ? [NSString stringWithFormat:@"%ld%% optical correction", (long)self.percent] : @"0% original geometry";
	self.borderView.correction = self.percent / 100.0;
	self.borderView.width = self.widthSlider.doubleValue;
	self.widthLabel.stringValue = [NSString stringWithFormat:@"Border width: %g pt", self.borderView.width];
	[self.border setFrame:NSInsetRect(self.window.frame, -self.borderView.width, -self.borderView.width) display:YES];
	[self.borderView setNeedsDisplay:YES];
	[self.border orderWindow:NSWindowBelow relativeTo:self.window.windowNumber];
}
- (void)changeWidth:(NSSlider *)sender
{
	// Quarter-point steps remain useful at both 1x and 2x display scales.
	sender.doubleValue = round(sender.doubleValue * 4) / 4;
	[self update];
}
- (void)selectPercent:(NSButton *)sender
{
	self.percent = sender.tag;
	if (self.percent) self.lastPercent = self.percent;
	[self update];
}
- (void)toggle:(id)sender
{
	self.percent = self.percent ? 0 : self.lastPercent;
	[self update];
}
- (void)windowDidMove:(NSNotification *)notification { [self update]; }
- (void)windowDidResize:(NSNotification *)notification { [self update]; }
- (void)windowDidChangeBackingProperties:(NSNotification *)notification { [self update]; }
- (void)windowWillClose:(NSNotification *)notification { [NSApp terminate:nil]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(void)
{
	@autoreleasepool {
		NSApplication *app = NSApplication.sharedApplication;
		[app setActivationPolicy:NSApplicationActivationPolicyRegular];
		Preview *delegate = [Preview new];
		app.delegate = delegate;
		[app run];
	}
	return 0;
}
