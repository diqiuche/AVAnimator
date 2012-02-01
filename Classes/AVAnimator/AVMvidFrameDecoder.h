//
//  AVMvidFrameDecoder.h
//  QTFileParserApp
//
//  Created by Moses DeJong on 4/23/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "AVFrameDecoder.h"
#import "maxvid_file.h"

// If USE_SEGMENTED_MMAP is defined, then each frame will be contained in a separate
// mmap segment. Otherwise, a single memory map will be used for the entire mvid file.

#define USE_SEGMENTED_MMAP

#if defined(USE_SEGMENTED_MMAP)
@class SegmentedMappedData;
#endif // USE_SEGMENTED_MMAP

@interface AVMvidFrameDecoder : AVFrameDecoder {
  NSString *m_filePath;
  MVFileHeader m_mvHeader;
  MVFrame *m_mvFrames;
  BOOL m_isOpen;
  
#if defined(USE_SEGMENTED_MMAP)
  SegmentedMappedData *m_mappedData;
#else
  NSData *m_mappedData;
#endif // USE_SEGMENTED_MMAP
  
  CGFrameBuffer *m_currentFrameBuffer;  
	NSArray *m_cgFrameBuffers;
  
  int frameIndex;
  BOOL m_resourceUsageLimit;

#if defined(REGRESSION_TESTS)
  BOOL m_simulateMemoryMapFailure;
#endif // REGRESSION_TESTS
}

@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, retain) CGFrameBuffer *currentFrameBuffer;
@property (nonatomic, copy) NSArray *cgFrameBuffers;

#if defined(USE_SEGMENTED_MMAP)
@property (nonatomic, retain) SegmentedMappedData *mappedData;
#else
@property (nonatomic, copy) NSData *mappedData;
#endif // REGRESSION_TESTS

#if defined(REGRESSION_TESTS)
@property (nonatomic, assign) BOOL simulateMemoryMapFailure;
#endif // REGRESSION_TESTS

+ (AVMvidFrameDecoder*) aVMvidFrameDecoder;

// Open resource identified by path

- (BOOL) openForReading:(NSString*)path;

// Close resource opened earlier

- (void) close;

// Reset current frame index to -1, before the first frame

- (void) rewind;

// Advance the current frame index to the indicated frame index and store result in nextFrameBuffer

- (UIImage*) advanceToFrame:(NSUInteger)newFrameIndex;

// Decoding frames may require additional resources that are not required
// to open the file and examine the header contents. This method will
// allocate decoding resources that are required to actually decode the
// video frames from a specific file. It is possible that allocation
// could fail, for example if decoding would require too much memory.
// The caller would need to check for a FALSE return value to determine
// how to handle the case where allocation of decode resources fails.

- (BOOL) allocateDecodeResources;

- (void) releaseDecodeResources;

// Return the current frame buffer, this is the buffer that was most recently written to via
// a call to advanceToFrame. Returns nil on init or after a rewind operation.

- (CGFrameBuffer*) currentFrameBuffer;

// Properties

// Dimensions of each frame
- (NSUInteger) width;
- (NSUInteger) height;

// True when resource has been opened via openForReading
- (BOOL) isOpen;

// Total frame count
- (NSUInteger) numFrames;

// Current frame index, can be -1 at init or after rewind
- (NSInteger) frameIndex;

// Time each frame shold be displayed
- (NSTimeInterval) frameDuration;

@end
