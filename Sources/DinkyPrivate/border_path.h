#pragma once
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

// CGPathAddRoundedRect needs the radius to fit in the rect.
static void add_rounded_rect(CGMutablePathRef path, CGRect rect, double radius)
{
	radius = MAX(0, MIN(radius, MIN(rect.size.width, rect.size.height) / 2));
	CGPathAddRoundedRect(path, NULL, rect, radius, radius);
}

// Keep the inner outline and straight edges fixed. At each corner's midpoint the outer
// outline grows by the correction fraction of the width, tapering to zero at both tangents.
static void add_corrected_outer_rect(CGMutablePathRef path, CGRect rect, double radius, double width, double correction)
{
	radius = MAX(0, MIN(radius, MIN(rect.size.width, rect.size.height) / 2));
	if (radius <= width) {
		add_rounded_rect(path, rect, radius);
		return;
	}
	CGPoint centers[] = {
		{ CGRectGetMaxX(rect) - radius, CGRectGetMaxY(rect) - radius },
		{ CGRectGetMinX(rect) + radius, CGRectGetMaxY(rect) - radius },
		{ CGRectGetMinX(rect) + radius, CGRectGetMinY(rect) + radius },
		{ CGRectGetMaxX(rect) - radius, CGRectGetMinY(rect) + radius },
	};
	// Fine one-degree segments approximate the corrected curve at either backing scale.
	for (int corner = 0; corner < 4; corner++) {
		for (int step = 0; step <= 90; step++) {
			double angle = (corner * 90 + step) * M_PI / 180;
			double bulge = sin(2 * angle);
			double r = radius + correction * width * bulge * bulge;
			CGPoint point = CGPointMake(centers[corner].x + r * cos(angle),
				centers[corner].y + r * sin(angle));
			if (corner == 0 && step == 0) CGPathMoveToPoint(path, NULL, point.x, point.y);
			else CGPathAddLineToPoint(path, NULL, point.x, point.y);
		}
	}
	CGPathCloseSubpath(path);
}

// Shared by the native border and the standalone live comparison.
static CGPathRef dinky_border_path(CGRect bounds, double radius, double width, double correction)
{
	CGMutablePathRef ring = CGPathCreateMutable();
	if (correction == 0) add_rounded_rect(ring, bounds, radius + width);
	else add_corrected_outer_rect(ring, bounds, radius + width, width, correction);
	add_rounded_rect(ring, CGRectInset(bounds, width, width), radius);
	return ring;
}
