/* Carrot -- Copyright (C) 2012 GoCarrot Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <Carrot/Carrot.h>
#import "Carrot+Internal.h"
#import <FacebookSDK/FacebookSDK.h>

static BOOL sCarrotDidFacebookSDKAuth = NO;

NSString* Carrot_GetAccessTokenFromSession(FBSession* session)
{
   return [[session accessTokenData] accessToken];
}

void Carrot_GetFBAppId(NSMutableString* outString)
{
   [outString setString:[FBSettings defaultAppID]];
}

BOOL Carrot_HandleOpenURLFacebookSDK(NSURL* url)
{
   if(sCarrotDidFacebookSDKAuth)
   {
      return [[FBSession activeSession] handleOpenURL:url];
   }
   return NO;
}

void Carrot_HandleApplicationDidBecomeActive()
{
   [[FBSession activeSession] handleDidBecomeActive];

   switch([[FBSession activeSession] state])
   {
      // Attempt to resume session.
      case FBSessionStateCreatedTokenLoaded:
      {
         [Carrot sharedInstance].cachedSessionStatusReason = CarrotAuthenticationStatusReasonSessionExists;

         if([FBSession openActiveSessionWithAllowLoginUI:NO])
         {
            [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession([FBSession activeSession])];
         }
      }
      break;

      case FBSessionStateCreatedOpening:
      {
         [Carrot sharedInstance].cachedSessionStatusReason = CarrotAuthenticationStatusReasonNewSession;
      }
      break;

      // Session already open.
      case FBSessionStateOpenTokenExtended:
      case FBSessionStateOpen:
      {
         [Carrot sharedInstance].cachedSessionStatusReason = CarrotAuthenticationStatusReasonSessionExists;

         [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession([FBSession activeSession])];
      }
      break;

      default:
      {
         [Carrot sharedInstance].cachedSessionStatusReason = CarrotAuthenticationStatusReasonNewSession;
      }
      break;
   }
}

static void HandleFacebookSessionError(NSError* error, CarrotAuthenticationStatus denyStatus)
{
   if(error.fberrorShouldNotifyUser)
   {
      if([[error userInfo][FBErrorLoginFailedReason]
          isEqualToString:FBErrorLoginFailedReasonSystemDisallowedWithoutErrorValue])
      {
         // User has disabled the app in the iOS Settings for Facebook
         [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized withError:error andReason:CarrotAuthenticationStatusReasonAppDisabledInSettings];
      }
      else
      {
         // An unknown error that should be presented to the user
         [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error andReason:CarrotAuthenticationStatusReasonUnknownShowUser];
         /*
         [[[UIAlertView alloc] initWithTitle:@"Facebook Error"
                                     message:error.fberrorUserMessage
                                    delegate:nil
                           cancelButtonTitle:@"OK"
                           otherButtonTitles:nil] show];
          */
      }
   }
   else
   {
      if(error.fberrorCategory == FBErrorCategoryUserCancelled)
      {
         // User has denied granting requested permissions
         [[Carrot sharedInstance] setAuthenticationStatus:denyStatus withError:error andReason:CarrotAuthenticationStatusReasonUserDeniedPermissions];
      }
      else if(error.fberrorCategory == FBErrorCategoryAuthenticationReopenSession)
      {
         NSInteger underlyingSubCode = [[error userInfo]
                                        [@"com.facebook.sdk:ParsedJSONResponseKey"]
                                        [@"body"]
                                        [@"error"]
                                        [@"error_subcode"] integerValue];
         if(underlyingSubCode == 458)
         {
            // User has removed the app from their Facebook settings
            [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized withError:error andReason:CarrotAuthenticationStatusReasonUserRemovedApp];
         }
         else
         {
            // The session has expired
            [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized withError:error andReason:CarrotAuthenticationStatusReasonSessionExpired];
         }
      }
      else
      {
         [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error andReason:CarrotAuthenticationStatusReasonUnknown];
      }
   }
}

static void (^Carrot_FacebookSDKCompletionHandler)(FBSession*, FBSessionState, NSError*) = ^(FBSession* session, FBSessionState status, NSError* error)
{
   if(session && [session isOpen])
   {
      [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession(session)];

      // Fetch user id for convenience of developers
      [FBRequestConnection
       startForMeWithCompletionHandler:^(FBRequestConnection* connection,
                                         id<FBGraphUser> user,
                                         NSError* error) {
          if(error == nil && [user isKindOfClass:[NSDictionary class]])
          {
             [Carrot sharedInstance].facebookUser = [NSDictionary dictionaryWithDictionary:(NSDictionary*)user];
          }
       }];
   }
   else
   {
      HandleFacebookSessionError(error, CarrotAuthenticationStatusNotAuthorized);
   }
};

static void (^Carrot_FacebookSDKReauthorizeHandler)(FBSession*, NSError*) = ^(FBSession* session, NSError* error)
{
   if(error != nil)
   {
      HandleFacebookSessionError(error, [Carrot sharedInstance].authenticationStatus);
   }
   else if(session && [session isOpen])
   {
      [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession(session)];
   }
};

int Carrot_DoFacebookAuth(int allowLoginUI, int permission)
{
   NSArray* permissionsArray = nil;
   switch(permission)
   {
      case CarrotFacebookPermissionRead:
      {
         // 'email' is only here because we are required to request a basic
         // read permission, and this is the one people are used to giving.
         permissionsArray = @[@"email"];
         break;
      }
      case CarrotFacebookPermissionPublishActions:
      {
         permissionsArray = @[@"publish_actions"];
         break;
      }
      case CarrotFacebookPermissionReadWrite:
      {
         permissionsArray = @[@"email", @"publish_actions"];
         break;
      }

      default:
      {
#ifdef DEBUG
         NSException *exception = [NSException exceptionWithName:@"BadPermissionException"
                                                          reason:@"Permission request must be CarrotFacebookPermissionRead, CarrotFacebookPermissionReadWrite or CarrotFacebookPermissionPublishActions."
                                                        userInfo:nil];
         @throw exception;
#endif
      }
   }

   return Carrot_DoFacebookAuthWithPermissions(allowLoginUI, (CFArrayRef)permissionsArray);
}

int Carrot_DoFacebookAuthWithPermissions(int allowLoginUI, CFArrayRef permissions)
{
   int ret = 0;
   int permissionType = CarrotFacebookPermissionRead;

   NSArray* permissionsArray = (NSArray*)permissions;
   NSSet* publishPermissions = [NSSet setWithArray:@[@"publish_stream", @"publish_actions", @"publish_checkins", @"create_event"]];

   // Determine if this contains read, write, or both types of permissions
   if([publishPermissions intersectsSet:[NSSet setWithArray:permissionsArray]])
   {
      permissionType = CarrotFacebookPermissionPublishActions;
      for(id permission in permissionsArray)
      {
         if(![publishPermissions containsObject:permission])
         {
            permissionType = CarrotFacebookPermissionReadWrite;
            break;
         }
      }
   }

   if(permissionType == CarrotFacebookPermissionRead)
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;
      NSLog(@"Opening Facebook session with read permissions: %@", permissionsArray);

      [FBSession openActiveSessionWithReadPermissions:permissionsArray
                                         allowLoginUI:allowLoginUI
                                    completionHandler:Carrot_FacebookSDKCompletionHandler];
   }
   else if(permissionType == CarrotFacebookPermissionPublishActions &&
           [[FBSession activeSession] isOpen])
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;

      NSLog(@"Requesting new Facebook publish permissions: %@", permissionsArray);
      [[FBSession activeSession]
       requestNewPublishPermissions:permissionsArray
       defaultAudience:FBSessionDefaultAudienceFriends
       completionHandler:Carrot_FacebookSDKReauthorizeHandler];
   }

   return ret;
}
