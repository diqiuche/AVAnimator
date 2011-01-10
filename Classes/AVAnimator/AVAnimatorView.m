//
//  AVAnimatorView.m
//
//  Created by Moses DeJong on 3/18/09.
//
//  License terms defined in License.txt.

#import "AVAnimatorView.h"

#import <QuartzCore/QuartzCore.h>

#import <AVFoundation/AVAudioPlayer.h>

#import <AudioToolbox/AudioFile.h>
#import "AudioToolbox/AudioServices.h"

#import "CGFrameBuffer.h"
#import "AVResourceLoader.h"
#import "AVFrameDecoder.h"

//#define DEBUG_OUTPUT

// util class AVAnimatorViewAudioPlayerDelegate declaration

@interface AVAnimatorViewAudioPlayerDelegate : NSObject <AVAudioPlayerDelegate> {	
@public
	AVAnimatorView *animator;
}

- (id) initWithAnimator:(AVAnimatorView*)inAnimator;

@end // class AVAnimatorViewAudioPlayerDelegate declaration

@implementation AVAnimatorViewAudioPlayerDelegate

- (id) initWithAnimator:(AVAnimatorView*)inAnimator {
	self = [super init];
	if (self == nil)
		return nil;
	// Note that we don't retain a ref here, since the AVAnimatorView is
	// the only object that can ref this object, holding a ref would create
	// a circular reference and the view would never be deallocated.
	self->animator = inAnimator;
	return self;
}

// Invoked when audio player was interrupted, for example by
// an incoming phone call.

- (void)audioPlayerBeginInterruption:(AVAudioPlayer *)player
{
	// FIXME: pass reason for stop (loop, interrupt)
  
	[animator pause];
}

- (void)audioPlayerEndInterruption:(AVAudioPlayer *)player
{
	// Resume playback of audio
  
  // FIXME: Should we unpause right away or should we leave the player in the
  // paused state and let the user start it again? Perhaps just make sure
  // that it is paused and that the controls are visible.
  
  //	[player play];
  
	[animator unpause];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error
{
	// The audio must not contain improperly formatted data
	assert(FALSE);
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag
{
	// The audio must not contain improperly formatted data
	assert(flag);
}

@end // class AVAnimatorViewAudioPlayerDelegate implementation

// private properties declaration for AVAnimatorView class
#include "AVAnimatorViewPrivate.h"

// AVAnimatorView class

@implementation AVAnimatorView

// public properties

@synthesize resourceLoader = m_resourceLoader;
@synthesize frameDecoder = m_frameDecoder;
@synthesize animatorFrameDuration = m_animatorFrameDuration;
@synthesize animatorNumFrames = m_animatorNumFrames;
@synthesize animatorRepeatCount = m_animatorRepeatCount;
@synthesize animatorOrientation = m_animatorOrientation;

// private properties

@synthesize animatorAudioURL = m_animatorAudioURL;
@synthesize prevFrame = m_prevFrame;
@synthesize nextFrame = m_nextFrame;
@synthesize animatorPrepTimer = m_animatorPrepTimer;
@synthesize animatorReadyTimer = m_animatorReadyTimer;
@synthesize animatorDecodeTimer = m_animatorDecodeTimer;
@synthesize animatorDisplayTimer = m_animatorDisplayTimer;
@synthesize currentFrame = m_currentFrame;
@synthesize repeatedFrameCount = m_repeatedFrameCount;
@synthesize avAudioPlayer = m_avAudioPlayer;
@synthesize audioSimulatedStartTime = m_audioSimulatedStartTime;
@synthesize state = m_state;
@synthesize animatorMaxClockTime = m_animatorMaxClockTime;
@synthesize animatorDecodeTimerInterval = m_animatorDecodeTimerInterval;
@synthesize renderSize = m_renderSize;
@synthesize isReadyToAnimate = m_isReadyToAnimate;
@synthesize startAnimatorWhenReady = m_startAnimatorWhenReady;

- (void) dealloc {
	// This object can't be deallocated while animating, this could
	// only happen if user code incorrectly dropped the last ref.
  
  //	NSLog(@"AVAnimatorViewController dealloc");
  
	NSAssert(self.state != PAUSED, @"dealloc while paused");
	NSAssert(self.state != ANIMATING, @"dealloc while animating");
    
	self.animatorAudioURL = nil;
  
  /*
   CGImageRef imgRef1 = imageView.image.CGImage;
   CGImageRef imgRef2 = prevFrame.CGImage;
   CGImageRef imgRef3 = nextFrame.CGImage;
   */
  
	// Explicitly release image inside the imageView, the
	// goal here is to get the imageView to drop the
	// ref to the CoreGraphics image and avoid a memory
	// leak. This should not be needed, but it is.
  
	self.image = nil;
  
	self.prevFrame = nil;
	self.nextFrame = nil;
  
  // Release resource loader and frame decoder
  // after image related objects, in case the image
  // objects held a ref to frame buffers in the
  // decoder class.
  
	self.resourceLoader = nil;
  self.frameDecoder = nil;
  
	self.animatorPrepTimer = nil;
  self.animatorReadyTimer = nil;
  self.animatorDecodeTimer = nil;
  self.animatorDisplayTimer = nil;
  
	// Reset the delegate state for the audio player object
	// and release the delegate. The avAudioPlayer object
	// can still exist on the event queue after it has been
	// released here, so resetting the delegate avoids a
	// crash invoking delegate method on a now invalid ref.
  
  if (self.avAudioPlayer) {
    self.avAudioPlayer.delegate = self->m_originalAudioDelegate;
    [self->m_retainedAudioDelegate release];
    self.avAudioPlayer = nil;
  }
  self.audioSimulatedStartTime = nil;
  
  [super dealloc];
}

// static ctor

+ (AVAnimatorView*) aVAnimatorView
{
  return [AVAnimatorView aVAnimatorViewWithFrame:[UIScreen mainScreen].applicationFrame];
}

+ (AVAnimatorView*) aVAnimatorViewWithFrame:(CGRect)viewFrame
{
  AVAnimatorView *obj = [[AVAnimatorView alloc] initWithFrame:viewFrame];
  [obj autorelease];
  return obj;
}

// Note: there is no init method since this class makes use of the default
// init method in the superclass.

// Return the final path component for either file or URL strings.

- (NSString*) _getLastPathComponent:(NSString*)path
{
	// Find the last '/' in the string, then use everything after that as the entry name
	NSString *lastPath;
	NSRange lastSlash = [path rangeOfString:@"/" options:NSBackwardsSearch];
	NSRange restOfPathRange;
	restOfPathRange.location = lastSlash.location + 1;
	restOfPathRange.length = [path length] - restOfPathRange.location;
	lastPath = [path substringWithRange:restOfPathRange];
	return lastPath;
}

// For "foo.bar" trim ".bar" off the end of the filename.

- (NSString*) _getFilenameWithoutExtension:(NSString*)filename extension:(NSString*)extension
{
	NSRange lastDot = [filename rangeOfString:extension options:NSBackwardsSearch];
	
	if (lastDot.location == NSNotFound) {
		return nil;
	} else {
		NSRange beforeDotRange;
		beforeDotRange.location = 0;
		beforeDotRange.length = lastDot.location;
		return [filename substringWithRange:beforeDotRange];
	}
}

// This loadViewImpl method is not the atomatically invoked loadView from the view controller class.
// It needs to be explicitly invoked after the view widget has been created.

- (void) loadViewImpl {  
	BOOL isRotatedToLandscape = FALSE;
	size_t renderWidth, renderHeight;

  // FIXME: these settings would need to be available somehow to the caller, but if this method
  // is invoked on init, then they will not be.
  
	if (self.animatorOrientation == UIImageOrientationUp) {
		isRotatedToLandscape = FALSE;
	} else if (self.animatorOrientation == UIImageOrientationLeft) {
		// 90 deg CCW for Landscape Orientation
		isRotatedToLandscape = TRUE;
	} else if (self.animatorOrientation == UIImageOrientationRight) {
		// 90 deg CW for Landscape Right Orientation
		isRotatedToLandscape = TRUE;
	} else if (self.animatorOrientation == UIImageOrientationDown) {
		// 180 deg CW rotation
		isRotatedToLandscape = FALSE;    
	} else {
		NSAssert(FALSE,@"Unsupported animatorOrientation");
	}
	
	if (!isRotatedToLandscape) {
		if (self.animatorOrientation == UIImageOrientationDown) {
      [self rotateToUpsidedown];
    }
	} else  {
		if (self.animatorOrientation == UIImageOrientationLeft) {
			[self rotateToLandscape];
		} else {
			[self rotateToLandscapeRight];
    }
	}
  
  // FIXME: order of operations condition here between container setting frame and
  // this method getting invoked! Make sure frame change is not processed after this!
  
	if (isRotatedToLandscape) {
		renderWidth = self.frame.size.height;
		renderHeight = self.frame.size.width;
	} else {
		renderWidth = self.frame.size.width;
		renderHeight = self.frame.size.height;
	}
  
	//	renderWidth = applicationFrame.size.width;
	//	renderHeight = applicationFrame.size.height;
  
	CGSize rs;
	rs.width = renderWidth;
	rs.height = renderHeight;
	self.renderSize = rs;
  
  // View defaults to opaque, decoder might know
  // that there is an alpha channel, but not
  // until the frame source data has been read.
  
  self.opaque = TRUE;
  
	// User events to this layer are ignored
  
	self.userInteractionEnabled = FALSE;
  
  // FIXME: If opaque, does background color need
  // to be set to clear instead of black?
  
	self.backgroundColor = [UIColor blackColor];
  
	NSAssert(self.resourceLoader, @"resourceLoader must be defined");
	NSAssert(self.frameDecoder, @"frameDecoder must be defined");
  
	NSAssert(self.animatorAudioURL == nil, @"animatorAudioURL must be nil");
  
  // FIXME: may or may not need to set this? Figure out based on what is in header.
  //	NSAssert(animatorFrameDuration != 0.0, @"animatorFrameDuration was not defined");
  
	// Note that we don't load any data from the movie archive or from the
	// audio files at load time. Resource loading is done only as a result
	// of a call to prepareToAnimate. Only a state change of
	// ALLOCATED -> LOADED is possible here.
  
	if (self.state == ALLOCATED) {
		self.state = LOADED;
	}
  
  // Unknown view flags.
  
  // FIXME: Does this default to YES? clearsContextBeforeDrawing, if so
  // should we set it to NO unless in 32 bpp mode?
  
  // clipsToBounds ? Should be YES?
}

- (void) _createAudioPlayer
{
	NSError *error;
	NSError **errorPtr = &error;
	AVAudioPlayer *avPlayer = nil;
  
  if (self.animatorAudioURL == nil) {
    return;
  }
	NSURL *audioURL = self.animatorAudioURL;
  
	NSString *audioURLPath = [audioURL path];
	NSString *audioURLTail = [self _getLastPathComponent:audioURLPath];
	char *audioURLTailStr = (char*) [audioURLTail UTF8String];
	NSAssert(audioURLTailStr != NULL, @"audioURLTailStr is NULL");
	NSAssert(audioURLTail != nil, @"audioURLTail is nil");
  
	avPlayer = [AVAudioPlayer alloc];
	avPlayer = [avPlayer initWithContentsOfURL:audioURL error:errorPtr];
  [avPlayer autorelease];
  
	if (error.code == kAudioFileUnsupportedFileTypeError) {
		NSAssert(FALSE, @"unsupported audio file format");
	}
  
	NSAssert(avPlayer, @"AVAudioPlayer could not be allocated");
  
	self.avAudioPlayer = avPlayer;
  
	AVAnimatorViewAudioPlayerDelegate *audioDelegate;
  
	audioDelegate = [[AVAnimatorViewAudioPlayerDelegate alloc] initWithAnimator:self];
  
	// Note that in OS 3.0, the delegate does not seem to be retained though it
	// was retained in OS 2.0. Explicitly retain it as a separate ref. Save
	// the original delegate value and reset it before dropping the ref to the
	// audio player just to be safe.
  
	self->m_originalAudioDelegate = self.avAudioPlayer.delegate;
	self.avAudioPlayer.delegate = audioDelegate;
	self->m_retainedAudioDelegate = audioDelegate;
  
	NSLog(@"%@", [NSString stringWithFormat:@"default avPlayer volume was %f", avPlayer.volume]);
  
	// Get the audio player ready by pre-loading buffers from disk
  
	[self.avAudioPlayer prepareToPlay];
}

// This method is invoked in the prep state via a timer callback
// while the widget is preparing to animate. This method will
// load resources once we know the files exist in the tmp dir.

- (BOOL) _loadResources
{
	NSLog(@"Started _loadResources");
  NSAssert(self.resourceLoader, @"resourceLoader");
  
	BOOL isReady = [self.resourceLoader isReady];
  if (!isReady) {
    NSLog(@"Not Yet Ready in _loadResources");
    return FALSE;
  }
  
	NSLog(@"Ready _loadResources");
  
	NSArray *resourcePathsArr = [self.resourceLoader getResources];
  
	// First path is the movie file, second is the audio
  
	NSAssert([resourcePathsArr count] == 1 || [resourcePathsArr count] == 2, @"expected 1 or 2 resource paths");
  
	NSString *videoPath = nil;
	NSString *audioPath = nil;
  
	videoPath = [resourcePathsArr objectAtIndex:0];
  if ([resourcePathsArr count] == 2) {
    audioPath = [resourcePathsArr objectAtIndex:1];
  }
  
  NSAssert(self.frameDecoder, @"frameDecoder");
  
	BOOL worked = [self.frameDecoder openForReading:videoPath];
	NSAssert(worked, @"frameDecoder openForReading failed");
  
	NSLog(@"%@", [NSString stringWithFormat:@"frameDecoder openForReading \"%@\"", [videoPath lastPathComponent]]);
    
  // Read frame duration from movie by default. If user explicitly indicated a frame duration
  // the use it instead of what appears in the movie.
  
  if (self.animatorFrameDuration == 0.0) {
    AVFrameDecoder *decoder = self.frameDecoder;
    NSTimeInterval duration = [decoder frameDuration];
    NSAssert(duration != 0.0, @"frame duration can't be zero");
    self.animatorFrameDuration = duration;
  }

  // Query alpha channel support in frame decoder
  
  if ([self.frameDecoder hasAlphaChannel]) {
    // This view will blend with other views
    self.opaque = FALSE;
  }
  
  // Get image data for initial keyframe
    
  UIImage *img = [self.frameDecoder advanceToFrame:0];
  NSAssert(img != nil, @"frame decoder must advance to first frame");    
  self.image = img;
	self.currentFrame = 0;
  
	// Create AVAudioPlayer that plays audio from the file on disk
  
  if (audioPath) {
    NSURL *url = [NSURL fileURLWithPath:audioPath];
    self.animatorAudioURL = url;
  }
  
	return TRUE;
}

- (void) _cleanupReadyToAnimate
{
	[self.animatorReadyTimer invalidate];
	self.animatorReadyTimer = nil;
  
  //NSLog(@"AVAnimatorViewController: _cleanupReadyToAnimate");
}

// When an animaton widget is ready to start loading any
// resources needed to play video/audio, this method is invoked.

- (void) _loadResourcesCallback:(NSTimer *)timer
{
	NSAssert(self.state == PREPPING, @"expected to be in PREPPING state");
  
  // If the view has not been added to a window yet, then we are not
  // ready to load resources yet.
  
  if (self.window == nil) {
    return;
  }
  
	// Prepare movie and audio, if needed
  
	BOOL ready = [self _loadResources];
  if (!ready) {
    // Note that the prep timer is not invalidated in this case
    return;
  }
  
	// Finish up init state
  
	[self.animatorPrepTimer invalidate];
	self.animatorPrepTimer = nil;  
  
	// Init audio data
	
	[self _createAudioPlayer];
  
	self.animatorNumFrames = [self.frameDecoder numFrames];
	assert(self.animatorNumFrames >= 2);
  
	self.state = READY;
	self.isReadyToAnimate = TRUE;
  
  // Send out a notification that indicates that the movie is now fully loaded
  // and is ready to play.
  
  [self _cleanupReadyToAnimate];
  
  // Send notification to object(s) that regestered interest in prepared action
  
  [[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorPreparedToAnimateNotification
                                                      object:self];
  
  if (self.startAnimatorWhenReady) {
    [self startAnimator];
  }
  
	return;
}

- (void) rotateToPortrait
{
	self.layer.transform = CATransform3DIdentity;
}

- (void) rotateToUpsidedown
{
  float angle = M_PI;  //rotate CCW 180°, or π radians
	self.layer.transform = CATransform3DMakeRotation(angle, 0, 0.0, 1.0);
}

- (void) landscapeCenterAndRotate:(UIView*)viewToRotate
                            angle:(float)angle
{
  float portraitWidth = self.frame.size.height;
  float portraitHeight = self.frame.size.width;
  float landscapeWidth = portraitHeight;
  float landscapeHeight = portraitWidth;
  
	float landscapeHalfWidth = landscapeWidth / 2.0;
	float landscapeHalfHeight = landscapeHeight / 2.0;
	
	int portraitHalfWidth = portraitWidth / 2.0;
	int portraitHalfHeight = portraitHeight / 2.0;
	
	int xoff = landscapeHalfWidth - portraitHalfWidth;
	int yoff = landscapeHalfHeight - portraitHalfHeight;	
  
	CGRect frame = CGRectMake(-xoff, -yoff, landscapeWidth, landscapeHeight);
	viewToRotate.frame = frame;

  viewToRotate.layer.transform = CATransform3DMakeRotation(angle, 0, 0.0, 1.0);
}

- (void) rotateToLandscape
{
	float angle = M_PI / 2;  //rotate CCW 90°, or π/2 radians
  [self landscapeCenterAndRotate:self angle:angle];
}

- (void) rotateToLandscapeRight
{
	float angle = -1 * (M_PI / 2);  //rotate CW 90°, or -π/2 radians
  [self landscapeCenterAndRotate:self angle:angle];
}

// Invoke this method to prepare the video and audio data so that it can be played
// as soon as startAnimator is invoked. If this method is invoked twice, it
// does nothing on the second invocation. An activity indicator is shown on screen
// while the data is getting ready to animate.

- (void) prepareToAnimate
{
	if (self.isReadyToAnimate) {
		return;
	} else if (self.state == PREPPING) {
		return;
	} else if (self.state == STOPPED && !self.isReadyToAnimate) {
		// Edge case where an earlier prepare was canceled and
		// the animator never became ready to animate.
		self.state = PREPPING;
	} else if (self.state > PREPPING) {
		return;
	} else {
		// Must be ALLOCATED or LOADED
		assert(self.state < PREPPING);
		self.state = PREPPING;
	}
  
	// Lookup window this view is in to force animator and
	// busy indicator to be allocated when the event loop
	// is next entered. This code exists because of some
	// strange edge case where this view does not get
	// added to the containing window before the blocking load.
  
//  if (self.window == nil) {
//  		NSAssert(FALSE, @"animator view is not inside a window");
//  }
  
	// Schedule a callback that will do the prep operation
  
	self.animatorPrepTimer = [NSTimer timerWithTimeInterval: 0.10
                                                    target: self
                                                  selector: @selector(_loadResourcesCallback:)
                                                  userInfo: NULL
                                                   repeats: TRUE];
  
	[[NSRunLoop currentRunLoop] addTimer: self.animatorPrepTimer forMode: NSDefaultRunLoopMode];
}

// Invoke this method to start the animator, if the animator is not yet
// ready to play then this method will return right away and the animator
// will be started when it is ready.

- (void) startAnimator
{
	[self prepareToAnimate];
  
	// If still preparing, just set a flag so that the animator
	// will start when the prep operation is finished.
  
	if (self.state < READY) {
		self.startAnimatorWhenReady = TRUE;
		return;
	}
  
	// No-op when already animating
  
	if (self.state == ANIMATING) {
		return;
	}
  
	// Can only transition from PAUSED to ANIMATING via unpause
  
	assert(self.state != PAUSED);
  
	assert(self.state == READY || self.state == STOPPED);
  
	self.state = ANIMATING;
  
	// Animation is broken up into two stages. Assume there are two frames that
	// should be displayed at times T1 and T2. At time T1 + animatorFrameDuration/4
	// check the audio clock offset and use that time to schedule a callback to
	// be fired at time T2. The callback at T2 will simply display the image.
  
	// Amount of time that will elapse between the expected time that a frame
	// will be displayed and the time when the next frame decode operation
	// will be invoked.
  
	self.animatorDecodeTimerInterval = self.animatorFrameDuration / 4.0;
  
	// Calculate upper limit for time that maps to specific frames.
  
	self.animatorMaxClockTime = ((self.animatorNumFrames - 1) * self.animatorFrameDuration) -
    (self.animatorFrameDuration / 10);
  
	// Create initial callback that is invoked until the audio clock
	// has started running.
  
	self.animatorDecodeTimer = [NSTimer timerWithTimeInterval: self.animatorFrameDuration / 2.0
                                                      target: self
                                                    selector: @selector(_animatorDecodeInitialFrameCallback:)
                                                    userInfo: NULL
                                                     repeats: FALSE];
  
  [[NSRunLoop currentRunLoop] addTimer: self.animatorDecodeTimer forMode: NSDefaultRunLoopMode];
  
  if (self.avAudioPlayer) {
    [self.avAudioPlayer play];
    [self _setAudioSessionCategory];
  } else {
    self.audioSimulatedStartTime = [NSDate date];
  }
  
  // Turn off the event idle timer so that the screen is not dimmed while playing
	
	UIApplication *thisApplication = [UIApplication sharedApplication];	
  thisApplication.idleTimerDisabled = YES;
	
	// Send notification to object(s) that regestered interest in start action
  
	[[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorDidStartNotification
                                                      object:self];
  
  // Display the initial frame right away. The initial frame callback logic
  // will decode the second frame when the clock starts running, but the
  // first frames needs to be shown until that callback is invoked.
  
  [self showFrame:0];
  NSAssert(self.currentFrame == 0, @"currentFrame must be zero");
  
  return;
}

-(void)_setAudioSessionCategory {
	// Define audio session as MediaPlayback, so that audio output is not silenced
	// when the silent switch is set. This is a non-mixing mode, so any audio
	// being played is silenced.
  
	UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
	OSStatus result =
	AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory);
	if (result != 0) {
		NSLog(@"%@", [NSString stringWithFormat:@"AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,kAudioSessionCategory_MediaPlayback) error : %d", result]);
	}
}

// Invoke this method to stop the animator and cancel all callbacks.

- (void) stopAnimator
{
	if (self.state == STOPPED) {
		// When already stopped, don't generate another AVAnimatorDidStopNotification
		return;
	}
  
	// stopAnimator can be invoked in any state, it needs to cleanup
	// any pending callbacks and stop audio playback.
  
	self.state = STOPPED;
	
	[self.animatorPrepTimer invalidate];
	self.animatorPrepTimer = nil;
  
	[self _cleanupReadyToAnimate];
  
	[self.animatorDecodeTimer invalidate];
	self.animatorDecodeTimer = nil;
  
	[self.animatorDisplayTimer invalidate];
	self.animatorDisplayTimer = nil;
  
  if (self.avAudioPlayer) {
    [self.avAudioPlayer stop];
    self.avAudioPlayer.currentTime = 0.0;
  }
  
	self.repeatedFrameCount = 0;
  
	self.prevFrame = nil;
	self.nextFrame = nil;
  
	[self.frameDecoder rewind];
  
	// Reset idle timer
	
	UIApplication *thisApplication = [UIApplication sharedApplication];	
  thisApplication.idleTimerDisabled = NO;
  
	// Send notification to object(s) that regestered interest in the stop action
  
	[[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorDidStopNotification
                                                      object:self];
  
	return;
}

- (BOOL) isAnimatorRunning
{
	return (self.state == ANIMATING);
}

- (BOOL) isInitializing
{
	return (self.state < ANIMATING);
}

- (void) pause
{
  // FIXME: What state could this be in other than animating? Could be some tricky race conditions
  // here related to where the event comes from. Also note that an interruption can cause a pause
  // action, it can't be ignored from an interruption since that has to work!
  
  //	NSAssert(state == ANIMATING, @"pause only valid while animating");
  
  if (self.state != ANIMATING) {
    // Ignore since an odd race condition could happen when window is put away or when
    // incoming call triggers this method.
    return;
  }
  
	[self.animatorDecodeTimer invalidate];
	self.animatorDecodeTimer = nil;
  
	[self.animatorDisplayTimer invalidate];
	self.animatorDisplayTimer = nil;
  
	[self.avAudioPlayer pause];
  
	self.repeatedFrameCount = 0;
  
	self.state = PAUSED;
  
	// Send notification to object(s) that regestered interest in the pause action
  
	[[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorDidPauseNotification
                                                      object:self];
}

- (void) unpause
{
	//NSAssert(state == PAUSED, @"unpause when not paused");
  if (self.state != PAUSED) {
    return;
  }
  
	self.state = ANIMATING;
  
	[self.avAudioPlayer play];
  
	// Resume decoding callbacks
  
	self.animatorDecodeTimer = [NSTimer timerWithTimeInterval: self.animatorDecodeTimerInterval
                                                      target: self
                                                    selector: @selector(_animatorDecodeFrameCallback:)
                                                    userInfo: NULL
                                                     repeats: FALSE];
  
	[[NSRunLoop currentRunLoop] addTimer: self.animatorDecodeTimer forMode: NSDefaultRunLoopMode];
  
	// Send notification to object(s) that regestered interest in the unpause action
  
	[[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorDidUnpauseNotification
                                                      object:self];	
}

- (void) rewind
{
	[self stopAnimator];
  [self startAnimator];
}

- (void) doneAnimator
{
	[self stopAnimator];
  
	// Send notification to object(s) that regestered interest in the done animating action
  
	[[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorDoneNotification
                                                      object:self];	
}

// Util function that will query the clock time and map that time to a frame
// index. The frame index has an upper bound, it will be reported as
// (self.animatorNumFrames - 2) if the clock time reported is larger
// than the number of valid frames.

- (void) _queryCurrentClockTimeAndCalcFrameNow:(NSTimeInterval*)currentTimePtr
                                   frameNowPtr:(NSUInteger*)frameNowPtr
{
	// Query audio clock time right now
  
	NSTimeInterval currentTime;
  
  if (self->m_avAudioPlayer == nil) {
    NSAssert(self.audioSimulatedStartTime, @"audioSimulatedStartTime is nil");
    currentTime = [self.audioSimulatedStartTime timeIntervalSinceNow] * -1;
  } else {
    currentTime = self->m_avAudioPlayer.currentTime;
  }
  
	// Calculate the frame to the left of the time interval
	// (time/window) based on the current clock time. In the
	// simple case, the calculated frame will be the same
	// as the one currently being displayed. This logic
	// truncates the (time/window) result so that frameNow + 1
	// will be the index of the next frame. A reported time
	// that is less than zero will be returned as zero.
	// The frameNow value has the range [0, SIZE-2] since
	// it must always be one less than the largest frame.
  
	NSUInteger frameNow;
  
	if (currentTime <= 0.0) {
		currentTime = 0.0;
		frameNow = 0;
	} else if (currentTime <= self.animatorFrameDuration) {
		frameNow = 0;
	} else if (currentTime > self.animatorMaxClockTime) {
		frameNow = self.animatorNumFrames - 1 - 1;
	} else {
		frameNow = (NSUInteger) (currentTime / self.animatorFrameDuration);
    
		// Check for the very tricky case where the currentTime
		// is very close to the frame interval time. A floating
		// point value that is very close to the frame interval
		// should not be truncated.
    
		NSTimeInterval plusOneTime = (frameNow + 1) * self.animatorFrameDuration;
		NSAssert(currentTime <= plusOneTime, @"currentTime can't be larger than plusOneTime");
		NSTimeInterval plusOneDelta = (plusOneTime - currentTime);
    
		if (plusOneDelta < (self.animatorFrameDuration / 100.0)) {
			frameNow++;
		}
    
		NSAssert(frameNow <= (self.animatorNumFrames - 1 - 1), @"frameNow larger than second to last frame");
	}
  
	*frameNowPtr = frameNow;
	*currentTimePtr = currentTime;
}

// This callback is invoked as the animator begins. The first
// frame or two need to sync to the audio clock before recurring
// callbacks can be scheduled to decode and paint.

- (void) _animatorDecodeInitialFrameCallback: (NSTimer *)timer {
	assert(self.state == ANIMATING);
  
	// Audio clock time right now
  
	NSTimeInterval currentTime;
	NSUInteger frameNow;
  
	[self _queryCurrentClockTimeAndCalcFrameNow:&currentTime frameNowPtr:&frameNow];	
  
#ifdef DEBUG_OUTPUT
	if (TRUE) {
		NSLog(@"%@%@%f", @"_animatorDecodeInitialFrameCallback: ",
          @"\tcurrentTime: ", currentTime);
	}
#endif	
  
	if (currentTime < (self.animatorFrameDuration / 2.0)) {
		// Ignore reported times until they are at least half way to the
		// first frame time. The audio could take a moment to start and it
		// could report a number of zero or less than zero times. Keep
		// scheduling a non-repeating call to _animatorDecodeFrameCallback
		// until the audio clock is actually running.
    
		if (self.animatorDecodeTimer != nil) {
			[self.animatorDecodeTimer invalidate];
			//self.animatorDecodeTimer = nil;
		}
    
		self.animatorDecodeTimer = [NSTimer timerWithTimeInterval: self.animatorDecodeTimerInterval
                                                        target: self
                                                      selector: @selector(_animatorDecodeInitialFrameCallback:)
                                                      userInfo: NULL
                                                       repeats: FALSE];
    
		[[NSRunLoop currentRunLoop] addTimer: self.animatorDecodeTimer forMode: NSDefaultRunLoopMode];
	} else {
		// Reported time is now at least half way to the second frame, so
		// we are ready to schedule recurring callbacks. Invoking the
		// decode frame callback will setup the next frame and
		// schedule the callbacks.
    
		[self _animatorDecodeFrameCallback:nil];
    
		NSAssert(self.animatorDecodeTimer != nil, @"should have scheduled a decode callback");
	}
}

// Invoked at a time between two frame display times.
// This callback will queue the next display operation
// and it will do the next frame decode operation.
// This method takes care of the case where the decode
// logic is too slow because the next trip to the event
// loop will display the next frame as soon as possible.

- (void) _animatorDecodeFrameCallback: (NSTimer *)timer {
  if (self.state != ANIMATING) {
    NSAssert(FALSE, @"state is not ANIMATING");
  }
  
	NSTimeInterval currentTime;
	NSUInteger frameNow;
  
	[self _queryCurrentClockTimeAndCalcFrameNow:&currentTime frameNowPtr:&frameNow];	
	
#ifdef DEBUG_OUTPUT
	if (TRUE) {
		NSUInteger secondToLastFrameIndex = self.animatorNumFrames - 1 - 1;
    
		NSTimeInterval timeExpected = (frameNow * self.animatorFrameDuration) +
      self.animatorDecodeTimerInterval;
		NSTimeInterval timeDelta = currentTime - timeExpected;
		NSString *formatted = [NSString stringWithFormat:@"%@%@%d%@%d%@%d%@%@%.4f%@%.4f",
                           @"_animatorDecodeFrameCallback: ",
                           @"\tanimator current frame: ", self.currentFrame,
                           @"\tframeNow: ", frameNow,
                           @" (", secondToLastFrameIndex, @")",
                           @"\tcurrentTime: ", currentTime,
                           @"\tdelta: ", timeDelta
                           ];
		NSLog(@"%@", formatted);
	}
#endif
 
	// If the audio clock is reporting nonsense results like time going
	// backwards, just treat it like the clock is stuck. If a number
	// of stuck clock callbacks are found then animator will be stopped.
  
	if (frameNow < self.currentFrame) {
		NSString *msg = [NSString stringWithFormat:@"frameNow %d can't be less than currentFrame %d",
                     frameNow, self.currentFrame];
		NSLog(@"%@", msg);
    
		frameNow = self.currentFrame;
	}
  
	NSUInteger nextFrameIndex = frameNow + 1;
  
	// Figure out which callbacks should be scheduled
  
	BOOL isAudioClockStuck = FALSE;
	BOOL shouldScheduleDisplayCallback = TRUE;
	BOOL shouldScheduleDecodeCallback = TRUE;
	BOOL shouldScheduleLastFrameCallback = FALSE;  
  
  if ((frameNow > 0) && (frameNow == self.currentFrame)) {
    // The audio clock must be stuck, because there is no change in
		// the frame to display. This is basically a no-op, schedule
		// another frame decode operation but don't schedule a
		// frame display operation. Because the clock is stuck, we
		// don't know exactly when to schedule the callback for
		// based on frameNow, so schedule it one frame duration from now.
    
		isAudioClockStuck = TRUE;
		shouldScheduleDisplayCallback = FALSE;
    
    self.repeatedFrameCount = self.repeatedFrameCount + 1;
  } else {
    self.repeatedFrameCount = 0;
  }
  
  self.currentFrame = frameNow;
  
	if (self.repeatedFrameCount > 10) {
		// Audio clock has stopped reporting progression of time
		NSLog(@"%@", [NSString stringWithFormat:@"audio time not progressing: %f", currentTime]);
	} else if (self.repeatedFrameCount > 20) {
		NSLog(@"%@", [NSString stringWithFormat:@"doneAnimator because audio time not progressing"]);
    
		[self doneAnimator];
		return;
	}
  
	// Schedule the next frame display callback. In the case where the decode
	// operation takes longer than the time until the frame interval, the
	// display operation will be done as soon as the decode is over.	
  
	NSTimeInterval nextFrameExpectedTime;
	NSTimeInterval delta;
  
	if (shouldScheduleDisplayCallback) {
    if (isAudioClockStuck != FALSE) {
      NSAssert(FALSE, @"isAudioClockStuck is FALSE");
    }
    
		nextFrameExpectedTime = (nextFrameIndex * self.animatorFrameDuration);
		delta = nextFrameExpectedTime - currentTime;
    //if (delta <= 0.0) {
    //  NSAssert(FALSE, @"display delta is not a positive number");
    //}
    if (delta < 0.001) {
      // Display frame right away when running behind schedule.
      delta = 0.001;
    }
    
		if (self.animatorDisplayTimer != nil) {
			[self.animatorDisplayTimer invalidate];
			//self.animatorDisplayTimer = nil;
		}
    
		self.animatorDisplayTimer = [NSTimer timerWithTimeInterval: delta
                                                         target: self
                                                       selector: @selector(_animatorDisplayFrameCallback:)
                                                       userInfo: NULL
                                                        repeats: FALSE];
    
		[[NSRunLoop currentRunLoop] addTimer: self.animatorDisplayTimer forMode: NSDefaultRunLoopMode];			
	}
  
	// Schedule the next frame decode operation. Figure out when the
	// decode event should be invoked based on the clock time. This
	// logic will automatically sync the decode operation to the
	// audio clock each time this method is invoked. If the clock
	// is stuck, just take care of this in the next callback.
  
	if (!isAudioClockStuck) {
		NSUInteger secondToLastFrameIndex = self.animatorNumFrames - 1 - 1;
    
		if (frameNow == secondToLastFrameIndex) {
			// When on the second to last frame, we should schedule
			// an event that puts away the last frame at the end
			// of the frame display interval.
      
			shouldScheduleDecodeCallback = FALSE;
			shouldScheduleLastFrameCallback = TRUE;
		}			
	}
  
	if (shouldScheduleDecodeCallback || shouldScheduleLastFrameCallback) {
		if (isAudioClockStuck) {
			delta = self.animatorFrameDuration;
		} else if (shouldScheduleLastFrameCallback) {
			nextFrameExpectedTime = ((nextFrameIndex + 1) * self.animatorFrameDuration);
			delta = nextFrameExpectedTime - currentTime;
		} else {
			nextFrameExpectedTime = (nextFrameIndex * self.animatorFrameDuration) + self.animatorDecodeTimerInterval;
			delta = nextFrameExpectedTime - currentTime;
		}
    //if (delta <= 0.0) {
    //  NSAssert(FALSE, @"decode delta is not a positive number");
    //}
    if (delta < 0.002) {
      // Decode next frame right away when running behind schedule.
      delta = 0.002;
    }    
    
		if (self.animatorDecodeTimer != nil) {
			[self.animatorDecodeTimer invalidate];
			//self.animatorDecodeTimer = nil;
		}
    
		SEL aSelector = @selector(_animatorDecodeFrameCallback:);
    
		if (shouldScheduleLastFrameCallback) {
			aSelector = @selector(_animatorDoneLastFrameCallback:);
		}
    
		self.animatorDecodeTimer = [NSTimer timerWithTimeInterval: delta
                                                        target: self
                                                      selector: aSelector
                                                      userInfo: NULL
                                                       repeats: FALSE];
    
		[[NSRunLoop currentRunLoop] addTimer: self.animatorDecodeTimer forMode: NSDefaultRunLoopMode];		
	}
  
	// Decode the next frame, this operation could take some time, so it needs to
	// be done after callbacks have been scheduled. If the decode time takes longer
	// than the amount of time before the display callback, then the display
	// callback will be invoked right after the decode operation is finidhed.
  
	if (isAudioClockStuck) {
		// no-op
	} else {
		BOOL wasFrameDecoded = [self _animatorDecodeNextFrame];
    
		if (!wasFrameDecoded) {
			// Cancel the frame display callback at the end of this interval
      
			if (self.animatorDisplayTimer != nil) {
				[self.animatorDisplayTimer invalidate];
				self.animatorDisplayTimer = nil;
			}	
		}
	}
}

// Invoked after the final animator frame is shown on screen, this callback
// will stop the animator and set it off on another loop iteration if
// required. Note that this method is invoked at the exact time the
// last frame in the animation would have stopped displaying. If the
// animation loops and the first frame is shown again right away, then
// it will be displayed as close to the exact time as possible.

- (void) _animatorDoneLastFrameCallback: (NSTimer *)timer {
#ifdef DEBUG_OUTPUT
	NSTimeInterval currentTime;
	NSUInteger frameNow;
  
  [self _queryCurrentClockTimeAndCalcFrameNow:&currentTime frameNowPtr:&frameNow];
  
  NSTimeInterval timeExpected = ((self.currentFrame+2) * self.animatorFrameDuration);
  
  NSTimeInterval timeDelta = currentTime - timeExpected;  
  
  NSLog(@"_animatorDoneLastFrameCallback currentTime: %.4f delta: %.4f", currentTime, timeDelta);
#endif
	[self stopAnimator];
	
	// Continue to loop animator until loop counter reaches 0
  
	if (self.animatorRepeatCount > 0) {
		self.animatorRepeatCount = self.animatorRepeatCount - 1;
		[self startAnimator];
	} else {
		[self doneAnimator];
	}
}

// Invoked at a time as close to the actual display time
// as possible. This method is designed to have as low a
// latency as possible. This method changes the UIImage
// inside the UIImageView. It does not deallocate the
// currently displayed image or do any other possibly
// resource intensive operations. The run loop is returned
// to as soon as possible so that the frame will be rendered
// as soon as possible.

- (void) _animatorDisplayFrameCallback: (NSTimer *)timer {
  if (self->m_state != ANIMATING) {
    NSAssert(FALSE, @"state is not ANIMATING");
  }
  
#ifdef DEBUG_OUTPUT
	NSTimeInterval currentTime;
	NSUInteger frameNow;
	
	[self _queryCurrentClockTimeAndCalcFrameNow:&currentTime frameNowPtr:&frameNow];		
  
	if (TRUE) {
		NSTimeInterval timeExpected = ((self.currentFrame+1) * self.animatorFrameDuration);
    
		NSTimeInterval timeDelta = currentTime - timeExpected;
    
		NSString *formatted = [NSString stringWithFormat:@"%@%@%d%@%.4f%@%.4f",
                           @"_animatorDisplayFrameCallback: ",
                           @"\tdisplayFrame: ", self.currentFrame+1,
                           @"\tcurrentTime: ", currentTime,
                           @"\tdelta: ", timeDelta
                           ];
		NSLog(@"%@", formatted);
  }
#endif // DEBUG_OUTPUT
  
	// Display the "next" frame image, this logic does
	// the minimium amount of work to paint the display
	// with the contents of a UIImage. No objects are
	// allocated in this callback and no objects
	// are released. In the case of a duplicate
	// frame, where the next frame is the exact same
	// data as the previous frame, the render callback
	// will not change the value of nextFrame so
	// this method can just avoid updating the display.
  
	UIImage *currentImage = self.image;
	self.prevFrame = currentImage;
  
	if (currentImage != self->m_nextFrame) {
		self.image = self->m_nextFrame;
	}
  
  // Test release of frame now, instead of in next decode callback. Seems
  // that holding until the next decode does not actually release sometimes.
  
  //self.prevFrame = nil;
  
  // FIXME: why hold onto the ref to a frame into the next decode cycle?
  // Could this be causing the need for 3 framebuffers instead of 2?
  
	return;
}

// Display the given animator frame, in the range [1 to N]
// where N is the largest frame number. Note that this method
// should only be called when the animator is not running.

- (void) showFrame: (NSInteger) frame {
	if ((frame >= self.animatorNumFrames) || (frame < 0) || frame == self.currentFrame)
		return;
	
	self.currentFrame = frame - 1;
	[self _animatorDecodeNextFrame];
  // _animatorDisplayFrameCallback expects currentFrame
  // to be set to the frame index just before the one
  // to be displayed, so invoke and then set currentFrame.
  // Note that state must be switched to ANIMATING to
  // avoid an error check in _animatorDisplayFrameCallback.
  AVAudioPlayerState state = self.state;
	self.state = ANIMATING;
	[self _animatorDisplayFrameCallback:nil];
  self.state = state;
  self.currentFrame = frame;
}

// This method is invoked to decode the next frame
// of data and prepare the data to be rendered
// in the image view. In the normal case, the
// next frame is rendered and TRUE is returned.
// If the next frame is an exact duplicate of the
// previous frame, then FALSE is returned to indicate
// that no update is needed for the next frame.

- (BOOL) _animatorDecodeNextFrame {
	NSUInteger nextFrameNum = self.currentFrame + 1;
	NSAssert(nextFrameNum >= 0 && nextFrameNum < self.animatorNumFrames, @"nextFrameNum is invalid");
  
	// Deallocate UIImage object for the frame before
	// the currently displayed one. This will drop the
	// provider ref if it is holding the last ref.
	// Note that this should also clear the data
	// provider flag on an associated CGFrameBuffer
	// so that it can be used again.
  
  //	int refCount;
  
	UIImage *prevFrameImage = self.prevFrame;
  
	if (prevFrameImage != nil) {
		if (prevFrameImage != self.nextFrame) {
			NSAssert(prevFrameImage != self.image,
               @"self.prevFrame is not the same as current image");
		}
    
    //		refCount = [prevFrameImage retainCount];
    //		NSLog([NSString stringWithFormat:@"refCount before %d", refCount]);
    
		self.prevFrame = nil;
    
    //		if (refCount > 1) {
    //			refCount = [prevFrameImage retainCount];
    //			NSLog([NSString stringWithFormat:@"refCount after %d", refCount]);
    //		} else {
    //			NSLog([NSString stringWithFormat:@"should have been freed"]);			
    //		}
	}
  
	// Advance the "current frame" in the movie. In the case where
  // the next frame is exactly the same as the previous frame,
  // nil will be returned.
  
	UIImage *img = [self.frameDecoder advanceToFrame:nextFrameNum];
  
	if (img == nil) {
		return FALSE;
  } else {
    self.nextFrame = img;
    return TRUE;
  }
}

// Invoked when UIView is added to a window. This is typically invoked at some idle
// time when the windowing system is pepared to handle reparenting.

- (void)willMoveToWindow:(UIWindow *)newWindow
{
  [super willMoveToWindow:newWindow];
  [self loadViewImpl];
}

@end
