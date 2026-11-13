#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "border_path.h"
#include <assert.h>
#include <stdio.h>

// Compile against the same header as borders.m, not a Swift reconstruction of its geometry.
static bool contains(CGPathRef path, double x, double y) {
    return CGPathContainsPoint(path, NULL, CGPointMake(x, y), true);
}

int main(void) {
    double widths[] = {0.5, 1, 1.25, 4, 16};
    for (int i = 0; i < 5; i++) {
        double w = widths[i], radius = 12, r = radius + w;
        CGRect bounds = CGRectMake(0, 0, 240, 180);
        CGPathRef original = dinky_border_path(bounds, radius, w, 0);
        CGPathRef corrected = dinky_border_path(bounds, radius, w, .05);
        assert(CGRectEqualToRect(CGPathGetPathBoundingBox(corrected), bounds));
        assert(!contains(corrected, 120, 90));
        assert(contains(corrected, 120, w / 2));
        assert(!contains(corrected, 120, w + .01));

        // All four diagonal midpoints gain exactly 5% of width; the inner edge stays fixed.
        for (int x = -1; x <= 1; x += 2) for (int y = -1; y <= 1; y += 2) {
            double cx = x < 0 ? r : 240 - r, cy = y < 0 ? r : 180 - r;
            double inside = r + .049 * w, outside = r + .051 * w;
            assert(!contains(original, cx + x * inside / sqrt(2), cy + y * inside / sqrt(2)));
            assert(contains(corrected, cx + x * inside / sqrt(2), cy + y * inside / sqrt(2)));
            assert(!contains(corrected, cx + x * outside / sqrt(2), cy + y * outside / sqrt(2)));
            assert(!contains(corrected, cx + x * (radius - .01) / sqrt(2), cy + y * (radius - .01) / sqrt(2)));
            assert(contains(corrected, cx + x * (radius + .01) / sqrt(2), cy + y * (radius + .01) / sqrt(2)));
        }
        CGPathRelease(original);
        CGPathRelease(corrected);

        original = dinky_border_path(bounds, 0, w, 0);
        corrected = dinky_border_path(bounds, 0, w, .05);
        assert(CGPathEqualToPath(original, corrected));
        CGPathRelease(original);
        CGPathRelease(corrected);
    }
    puts("native border path: five widths, four corners, midpoint correction, unchanged inner/straight/square edges passed");
}
