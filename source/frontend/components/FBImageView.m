//
//  FBImageView.m
//  FBDesktopNotifications
//
//  Created by Lee Byron on 11/9/09.
//  Copyright 2009 Facebook. All rights reserved.
//

#import "FBImageView.h"
#import "NSPasteboard+.h"


@implementation FBImageView

@synthesize image, backgroundColor, imageScaling;

- (id)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = [[NSColor clearColor] retain];
    self.imageScaling = NSImageScaleProportionallyDown;

    // get dragged images
    [self registerForDraggedTypes:kImagePBoardTypes];
  }
  return self;
}

- (void)dealloc
{
  [image release];
	[backgroundColor release];
  [acceptedPBoardTypes release];
  [super dealloc];
}

- (void)setImage:(NSImage*)aImage
{
  aImage = [aImage copy];
  [aImage retain];
  [image release];
  image = aImage;

  [image setScalesWhenResized:YES];
  [self setNeedsDisplay:YES];
}

- (void)setImageScaling:(NSImageScaling)scaling
{
  imageScaling = scaling;
  [self setNeedsDisplay:YES];
}

- (void)setBackgroundColor:(NSColor*)color
{
  backgroundColor = [color copy];
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect
{
  NSRect bounds = [self bounds];

  [backgroundColor set];
  [NSBezierPath fillRect:bounds];

  if (!image) {
    NSString* prompt = NSLocalizedString(@"Drag a photo here or click to browse", @"Prompt for attaching a photo");

    NSRect promptBounds = [self bounds];
    promptBounds.size.height *= 0.5;
    NSMutableParagraphStyle* style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [style setAlignment:NSCenterTextAlignment];

    // draw the light edge first
    NSDictionary *attr = [NSDictionary dictionaryWithObjectsAndKeys:
                          style, NSParagraphStyleAttributeName,
                          [NSColor colorWithCalibratedWhite:1.0 alpha:0.5], NSForegroundColorAttributeName, nil];
    [prompt drawInRect:promptBounds withAttributes:attr];

    // then draw the real text
    promptBounds.size.height += 1.0;
    attr = [NSDictionary dictionaryWithObjectsAndKeys:
            style, NSParagraphStyleAttributeName,
            [NSColor colorWithCalibratedWhite:0.4 alpha:1.0], NSForegroundColorAttributeName, nil];
    [prompt drawInRect:promptBounds withAttributes:attr];

    return;
  }

  NSSize imageSize = [image size];
  NSSize layoutSize = imageSize;
  float rx, ry, r;
  NSPoint pt;

  switch (imageScaling) {
    default:
    case NSImageScaleProportionallyDown:
      rx = bounds.size.width / layoutSize.width;
      ry = bounds.size.height / layoutSize.height;
      r = MIN(1, (rx < ry ? rx : ry));
      layoutSize.width *= r;
      layoutSize.height *= r;
      [image setSize:layoutSize];
      break;
    case NSImageScaleProportionallyUpOrDown:
      rx = bounds.size.width / layoutSize.width;
      ry = bounds.size.height / layoutSize.height;
      r = rx < ry ? rx : ry;
      layoutSize.width *= r;
      layoutSize.height *= r;
      [image setSize:layoutSize];
      break;
    case NSImageScaleAxesIndependently:
      layoutSize = bounds.size;
      [image setSize:layoutSize];
      break;
    case NSScaleNone:
      break;
  }

  // center image
  pt.x = (bounds.size.width - layoutSize.width) / 2;
  pt.y = (bounds.size.height - layoutSize.height) / 2;

  // draw image
  [image compositeToPoint:pt operation:NSCompositeSourceAtop];

  // return to original size
  [image setSize:imageSize];
}

// dragging
- (NSUInteger)draggingEntered:(id <NSDraggingInfo>)sender
{
  if ([[sender draggingPasteboard] hasImage]) {
    return NSDragOperationCopy;
  }
  return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
  // Try to make a Image out of dragging pasteboard
  NSImage *droppedImage = [[sender draggingPasteboard] getImage];

  if (droppedImage) {
    self.image = droppedImage;
    return YES;
  }
  return NO;
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
  return YES;
}

// opening from file
- (void)mouseUp:(NSEvent*)aEvent
{
  if (image) {
    return;
  }

  // Create the File Open Dialog class.
  NSOpenPanel* openPanel = [NSOpenPanel openPanel];
  [openPanel setCanChooseFiles:YES];
  [openPanel setAllowsMultipleSelection:NO];
  [openPanel setCanChooseDirectories:NO];
  [openPanel setTitle:@"Select a photo to attach"];

  // If the OK button was pressed, attach the image
  if ([openPanel runModalForTypes:kImageFilenames] == NSOKButton) {
    NSString* fileName = [[openPanel filenames] objectAtIndex:0];
    if (fileName) {
      NSImage* openedImage = [[NSImage alloc] initWithContentsOfFile:fileName];
      self.image = openedImage;
      [openedImage release];
    }
  }
}

@end
