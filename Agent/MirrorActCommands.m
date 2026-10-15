// SPDX-License-Identifier: GPL-3.0-or-later
//
// Extra commands for WebDriverAgent, included in FBCustomCommands.m by scripts/build-agent.sh.
// POST /mirroract/touch sends a touch straight to XCTest – without first querying the
// UI hierarchy of the active app (in WebDriverAgent that costs ~0.5 s per gesture).

#if !TARGET_OS_TV && !TARGET_OS_WATCH

#import <UIKit/UIKit.h>
#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCUIDevice.h"

@interface MirrorActCommands : NSObject <FBCommandHandler>
@end

@implementation MirrorActCommands

// Querying the device orientation costs ~0.3 s: not at all in portrait (iPhone), otherwise
// at most every 2 s – applies to gestures in quick succession
static UIInterfaceOrientation MirrorActOrientation = UIInterfaceOrientationPortrait;
static BOOL MirrorActOrientationLandscape = NO;
static NSDate *MirrorActOrientationDate = nil;

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/mirroract/touch"].withoutSession respondWithTarget:self action:@selector(handleTouch:)],
  ];
}

/// Interface orientation: portrait or landscape according to the image, the side from the device
+ (UIInterfaceOrientation)interfaceOrientationForLandscape:(BOOL)landscape
{
  BOOL pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  if (!landscape && !pad) {
    return UIInterfaceOrientationPortrait;
  }
  if (nil != MirrorActOrientationDate && MirrorActOrientationLandscape == landscape
      && -MirrorActOrientationDate.timeIntervalSinceNow < 2) {
    return MirrorActOrientation;
  }
  UIDeviceOrientation device = XCUIDevice.sharedDevice.orientation;
  if (landscape) {
    // UIDeviceOrientationLandscapeLeft corresponds to UIInterfaceOrientationLandscapeRight (same value)
    if (device == UIDeviceOrientationLandscapeLeft || device == UIDeviceOrientationLandscapeRight) {
      MirrorActOrientation = (UIInterfaceOrientation)device;
    } else if (!UIInterfaceOrientationIsLandscape(MirrorActOrientation)) {
      MirrorActOrientation = UIInterfaceOrientationLandscapeRight;
    }
  } else {
    MirrorActOrientation = device == UIDeviceOrientationPortraitUpsideDown
      ? UIInterfaceOrientationPortraitUpsideDown
      : UIInterfaceOrientationPortrait;
  }
  MirrorActOrientationLandscape = landscape;
  MirrorActOrientationDate = [NSDate date];
  return MirrorActOrientation;
}

/// {"landscape": bool, "points": [[x, y, t], …]}: points as seen on the screen (iOS points),
/// t in seconds since the touch began. Responds once the gesture has been played back.
+ (id<FBResponsePayload>)handleTouch:(FBRouteRequest *)request
{
  NSArray<NSArray<NSNumber *> *> *points = request.arguments[@"points"];
  if (![points isKindOfClass:NSArray.class] || points.count == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'points' is missing"
                                                                       traceback:nil]);
  }
  for (NSArray *point in points) {
    if (![point isKindOfClass:NSArray.class] || point.count < 3) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"each point is [x, y, t]"
                                                                         traceback:nil]);
    }
  }
  UIInterfaceOrientation orientation =
    [self interfaceOrientationForLandscape:[request.arguments[@"landscape"] boolValue]];
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"MirrorAct touch"
                                                                interfaceOrientation:orientation];
  NSArray<NSNumber *> *first = points.firstObject;
  XCPointerEventPath *path = [[XCPointerEventPath alloc]
                              initForTouchAtPoint:CGPointMake(first[0].doubleValue, first[1].doubleValue)
                              offset:first[2].doubleValue];
  for (NSUInteger index = 1; index < points.count; index++) {
    NSArray<NSNumber *> *point = points[index];
    [path moveToPoint:CGPointMake(point[0].doubleValue, point[1].doubleValue) atOffset:point[2].doubleValue];
  }
  [path liftUpAtOffset:points.lastObject[2].doubleValue];
  [record addPointerEventPath:path];

  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

@end

#endif
