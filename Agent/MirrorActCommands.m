// SPDX-License-Identifier: GPL-3.0-or-later
//
// Zusatzbefehle für WebDriverAgent, von scripts/build-agent.sh in FBCustomCommands.m eingebunden.
// POST /mirroract/touch schickt eine Berührung direkt an XCTest – ohne vorher die
// Bedienungshierarchie der aktiven App abzufragen (das kostet bei WebDriverAgent ~0,5 s pro Geste).

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

// Ausrichtung des Geräts abzufragen kostet ~0,3 s: im Hochformat (iPhone) gar nicht, sonst
// höchstens alle 2 s – gilt für schnell aufeinanderfolgende Gesten
static UIInterfaceOrientation MirrorActOrientation = UIInterfaceOrientationPortrait;
static BOOL MirrorActOrientationLandscape = NO;
static NSDate *MirrorActOrientationDate = nil;

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/mirroract/touch"].withoutSession respondWithTarget:self action:@selector(handleTouch:)],
  ];
}

/// Ausrichtung der Oberfläche: Hoch- oder Querformat laut Bild, die Seite vom Gerät
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
    // UIDeviceOrientationLandscapeLeft entspricht UIInterfaceOrientationLandscapeRight (gleicher Wert)
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

/// {"landscape": bool, "points": [[x, y, t], …]}: Punkte wie auf dem Bildschirm zu sehen (iOS-Punkte),
/// t in Sekunden ab Berührungsbeginn. Antwortet, wenn die Geste abgespielt ist.
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
