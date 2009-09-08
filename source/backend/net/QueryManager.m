//
//  QueryManager.m
//  FBDesktopNotifications
//
//  Created by Lee Byron on 8/19/09.
//  Copyright 2009 Facebook. All rights reserved.
//

#import "QueryManager.h"
#import <FBCocoa/FBCocoa.h>
#import "ApplicationController.h"
#import "NetConnection.h"
#import "GlobalSession.h"
#import "PreferencesWindow.h"
#import "NSString+.h"
#import "NSDictionary+.h"


#define kQueryInterval 60
#define kRetryQueryInterval 60

#define kInfoQueryName @"info"
#define kInfoQueryFmt @"SELECT name, profile_url FROM user WHERE uid = %@"

#define kNotifQueryName @"notif"
#define kNotifQueryFmt @"SELECT notification_id, sender_id, recipient_id, " \
@"created_time, updated_time, title_html, title_text, body_html, body_text, " \
@"href, app_id, is_unread, is_hidden FROM notification "\
@"WHERE recipient_id = %@ AND ((is_unread = 0 AND notification_id IN (%@)) OR updated_time > %i) " \
@"ORDER BY created_time ASC"

#define kMessageQueryName @"messages"
#define kMessageQueryFmt @"SELECT thread_id, subject, snippet_author, snippet, unread, updated_time FROM thread " \
@"WHERE folder_id = 0 AND updated_time > %i"

#define kVerifyMessageQueryName @"verify_messages"
#define kVerifyMessageQueryFmt @"SELECT thread_id, unread FROM thread WHERE folder_id = 0"

#define kChainedPicQueryName @"pic"
#define kChainedPicQueryFmt @"SELECT uid, name, pic_square FROM user WHERE uid = %@ " \
@" OR uid IN (SELECT sender_id FROM #%@) OR uid IN (SELECT snippet_author FROM #%@)"

#define kChainedAppIconQueryName @"app_icon"
#define kChainedAppIconQueryFmt @"SELECT app_id, icon_url FROM application " \
@"WHERE app_id IN (SELECT app_id FROM #%@)"


@interface QueryManager (Private)

- (void)queryAfterDelay:(NSTimeInterval)delay;
- (void)query;
- (void)completedMultiquery:(id)response;
- (void)failedMultiquery:(NSError*)error;
- (void)processUserInfo:(id)userInfo;
- (void)processAppIcons:(id)fqlResultSet;
- (void)processPics:(id)fqlResultSet;
- (void)processNotifications:(id)fqlResultSet;
- (void)processMessages:(id)fqlResultSet;
- (void)processVerifyMessages:(id)fqlResultSet;

@end


@implementation QueryManager

-(id) initWithParent:(ApplicationController*)app
{
  self = [super init];
  if (self) {
    status    = QUERY_OFF;
    lastQuery = 0;
    parent    = app;
  }
  return self;
}

-(void) dealloc
{
  [queryTimer release];
  [super dealloc];
}

-(void) start
{
  [self query];
}

-(void) stop
{
  [queryTimer invalidate];
  queryTimer = nil;
  status = QUERY_OFF;
}


#pragma mark Private Methods
- (void)queryAfterDelay:(NSTimeInterval)delay
{
  if (queryTimer) {
    [queryTimer invalidate];
    [queryTimer release];
  }

  status = QUERY_DELAY_UNTIL_NEXT;
  queryTimer = [[NSTimer scheduledTimerWithTimeInterval:delay
                                                 target:self
                                               selector:@selector(query)
                                               userInfo:nil
                                                repeats:NO] retain];
  [[NSRunLoop currentRunLoop] addTimer:queryTimer forMode:NSDefaultRunLoopMode];
}

- (void)query
{
  // if we're not online, we shouldn't attempt a query.
  if (![[NetConnection netConnection] isOnline]) {
    return;
  }

  // release the wait timer
  if (queryTimer) {
    [queryTimer invalidate];
    [queryTimer release];
    queryTimer = nil;
  }

  // build queries
  NSString* unreadIDsList = [[[parent notifications] unreadNotifications] componentsJoinedByString:@","];
  NSString* notifQuery = [NSString stringWithFormat:kNotifQueryFmt,
                                                    [connectSession uid],
                                                    unreadIDsList,
                                                    [[parent notifications] mostRecentUpdateTime]];
  NSString* messageQuery = [NSString stringWithFormat:kMessageQueryFmt,
                                                      [[parent messages] mostRecentUpdateTime]];
  NSString* verifyMessageQuery = kVerifyMessageQueryFmt;
  NSString* picQuery = [NSString stringWithFormat:kChainedPicQueryFmt,
                                                  [connectSession uid],
                                                  kNotifQueryName,
                                                  kMessageQueryName];
  NSString* appIconQuery = [NSString stringWithFormat:kChainedAppIconQueryFmt,
                            kNotifQueryName];
  NSMutableDictionary* multiQuery =
  [NSMutableDictionary dictionaryWithObjectsAndKeys:notifQuery,   kNotifQueryName,
                                                    messageQuery, kMessageQueryName,
                                                    verifyMessageQuery, kVerifyMessageQueryName,
                                                    picQuery,     kChainedPicQueryName,
                                                    appIconQuery, kChainedAppIconQueryName, nil];
  if ([[parent menu] profileURL] == nil) {
    NSString* infoQuery = [NSString stringWithFormat:kInfoQueryFmt,
                                                     [connectSession uid]];
    [multiQuery setObject:infoQuery forKey:kInfoQueryName];
  }

  status = QUERY_WAITING_FOR_RESPONSE;
  [connectSession fqlMultiquery:multiQuery
                         target:self
                       selector:@selector(completedMultiquery:)
                          error:@selector(failedMultiquery:)];
}

- (void)completedMultiquery:(id)response
{
  // if we're not online, this must be bogus.
  if (![[NetConnection netConnection] isOnline]) {
    return;
  }

  // get ready to query again shortly...
  [self queryAfterDelay:kQueryInterval];

  // process query results
  [self processUserInfo:[response objectForKey:kInfoQueryName]];
  [self processAppIcons:[response objectForKey:kChainedAppIconQueryName]];
  [self processPics:[response objectForKey:kChainedPicQueryName]];
  [self processNotifications:[response objectForKey:kNotifQueryName]];
  [self processMessages:[response objectForKey:kMessageQueryName]];
  [self processVerifyMessages:[response objectForKey:kVerifyMessageQueryName]];

  [PreferencesWindow refresh];

  lastQuery = [[NSDate date] timeIntervalSince1970];
  [[NSApp delegate] invalidate];
}

- (void)failedMultiquery:(NSError*)error
{
  // if we're not online, it's obvious that this would fail
  if (![[NetConnection netConnection] isOnline]) {
    return;
  }

  // get ready to query again in a reasonable amount of time, if we're logged in
  if ([connectSession isLoggedIn]) {
    [self queryAfterDelay:kRetryQueryInterval];
  }

  // let us know what happened
  if ([error code] > 0) {
    NSLog(@"multiquery failed (fb error:%i) -> %@",
          [error code],
          [[error userInfo] objectForKey:kFBErrorMessageKey]);
  } else {
    NSLog(@"multiquery failed (net error:%i) -> %@",
          [error code],
          [[[[error userInfo] objectForKey:NSUnderlyingErrorKey] userInfo] objectForKey:NSLocalizedDescriptionKey]);
  }

  NSLog(@"suspect: %@", [error userInfo]);
}

- (void)processUserInfo:(id)userInfo
{
  if (userInfo == nil) {
    return;
  }
  userInfo = [userInfo objectAtIndex:0];
  [[parent menu] setUserName:[userInfo stringForKey:@"name"]];
  [[parent menu] setProfileURL:[userInfo stringForKey:@"profile_url"]];
}

- (void)processAppIcons:(id)result
{
  for (NSDictionary* icon in result) {
    NSString* appID   = [icon stringForKey:@"app_id"];
    NSString* iconUrl = [icon stringForKey:@"icon_url"];
    if (iconUrl) {
      [[parent appIcons] setImageURL:iconUrl forKey:appID];
    }
  }
}

- (void)processPics:(id)result
{
  for (NSDictionary* pic in result) {
    NSString* uid    = [pic stringForKey:@"uid"];
    NSString* name   = [pic stringForKey:@"name"];
    NSString* picUrl = [pic stringForKey:@"pic_square"];
    if (name) {
      [[parent names] setObject:name forKey:uid];
    }
    if (picUrl) {
      [[parent profilePics] setImageURL:picUrl forKey:uid];
    }
  }
}

- (void)processNotifications:(id)result
{
  NSArray* newNotifications = [[parent notifications] addNotificationsWithArray:result];
  if (lastQuery + (kQueryInterval * 5) > [[NSDate date] timeIntervalSince1970]) {
    for (FBNotification* notification in newNotifications) {
      if ([notification boolForKey:@"is_unread"]) {
        NSImage* pic = [[parent profilePics] imageForKey:[notification stringForKey:@"sender_id"]];
        [[parent bubbleManager] addBubbleWithText:[notification stringForKey:@"title_text"]
                                          // TODO - subText should use a properly encoded body_text when cortana 125906 is completed
                                          subText:[[notification stringForKey:@"body_html"] stringByReplacingOccurrencesOfString:@"<3" withString:@"\u2665"]
                                            image:pic
                                     notification:notification
                                          message:nil];
      }
    }
  }
}

- (void)processMessages:(id)result
{
  NSArray* newMessages = [[parent messages] addMessagesWithArray:result];

  if(lastQuery + (kQueryInterval * 5) > [[NSDate date] timeIntervalSince1970]) {
    for (FBMessage* message in newMessages) {
      if ([message boolForKey:@"unread"]) {
        NSString* uid = [message stringForKey:@"snippet_author"];
        NSImage* pic = [[parent profilePics] imageForKey:uid];

        NSString* name = [[parent names] objectForKey:uid];
        // TODO - should not need the manual <3 replacement after cortana 125906 is completed
        NSString* subject = [[message stringForKey:@"subject"] stringByReplacingOccurrencesOfString:@"<3" withString:@"\u2665"];

        NSString* bubText;
        if ([NSString exists:name]) {
          if ([NSString exists:subject]) {
            bubText = [NSString stringWithFormat:@"%@: %@", name, subject];
          } else {
            bubText = name;
          }
        } else {
          bubText = subject;
        }
        // TODO - should not need the manual <3 replacement after cortana 125906 is completed
        NSString* bubSubText = [[message stringForKey:@"snippet"] stringByReplacingOccurrencesOfString:@"<3" withString:@"\u2665"];
        if (![NSString exists:bubText]) {
          bubText = bubSubText;
          bubSubText = nil;
        }
        [[parent bubbleManager] addBubbleWithText:bubText
                                          subText:bubSubText
                                            image:pic
                                     notification:nil
                                          message:message];
      }
    }
  }
}

- (void)processVerifyMessages:(id)result
{
  [[parent messages] verifyMessagesWithArray:result];
}

@end
