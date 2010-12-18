//
//  MovieControlsView.m
//  MovieControlsDemo
//
//  Created by Moses DeJong on 4/11/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "MovieControlsView.h"
#import "MovieControlsViewController.h"

@implementation MovieControlsView

@synthesize viewController, currentEvent;

- (id)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self == nil)
		return nil;

	// Init code

	return self;
}

- (void)dealloc {
	// Note that we don't release self.viewController here

    [super dealloc];
}

// override hitTest so that this view can detect when a
// button press event is recieved and passed to one of
// the contained views.

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	NSLog(@"hitTest in MovieControlsView");

	[viewController	touchesAnyEvent];

	return [super hitTest:point withEvent:event];
}

// This implementation does not invoke [viewController touchesAnyEvent]
// it is invoked only from the view controller.

- (UIView *)hitTestSuper:(CGPoint)point withEvent:(UIEvent *)event
{
//	NSLog(@"hitTestSuper in MovieControlsView");

	return [super hitTest:point withEvent:event];
}

@end
