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
#import "CarrotCachedRequest.h"
#import "Reachability.h"
#import "AmazonSDKUtil.h"
#include <CommonCrypto/CommonDigest.h>
#import <FacebookSDK/FacebookSDK.h>
#import <AdSupport/AdSupport.h>

#define kCarrotSDKVersion @"1.2.0"

extern void Carrot_Plant(Class appDelegateClass, NSString* appSecret);
extern void Carrot_GetFBAppId(NSMutableString* outString);
extern BOOL Carrot_HandleOpenURLFacebookSDK(NSURL* url);
extern NSString* URLEscapedString(NSString* inString);

@interface Carrot ()

@property (nonatomic) CarrotAuthenticationStatus lastAuthStatusReported;
@property (nonatomic, readwrite, setter=setAuthenticationStatus:) CarrotAuthenticationStatus authenticationStatus;
@property (nonatomic, readwrite, setter=setAuthenticationStatusReason:) CarrotAuthenticationStatusReason authenticationStatusReason;
@property (strong, nonatomic, readwrite) NSString* version;
@property (strong, nonatomic, readwrite) NSDate* installDate;

@end

static NSString* sCarrotAppID = nil;
static NSString* sCarrotURLSchemeSuffix = nil;
static NSString* sCarrotDebugUDID = nil;

@implementation Carrot

+ (Carrot*)sharedInstance
{
   static Carrot* sharedInstance = nil;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      if(![NSError instancesRespondToSelector:@selector(fberrorShouldNotifyUser)])
      {
         NSException *exception = [NSException exceptionWithName:@"AdditionalLinkerFlagRequired"
                                                          reason:@"Use of the Carrot SDK requires adding '-ObjC' to the 'Other Linker Flags' setting of your Xcode Project. See: https://gocarrot.com/docs/ios for more information."
                                                        userInfo:nil];
         @throw exception;
      }

      sharedInstance = [[Carrot alloc] init];
   });
   return sharedInstance;
}

+ (void)setSharedAppID:(NSString*)appID
{
   sCarrotAppID = appID;
}

+ (NSString*)sharedAppID
{
   if(!sCarrotAppID)
   {
      NSMutableString* retrievedAppId = [[NSMutableString alloc] init];
      Carrot_GetFBAppId(retrievedAppId);
      return retrievedAppId;
   }
   return sCarrotAppID;
}

+ (void)setSharedAppSchemeSuffix:(NSString*)schemeSuffix
{
   sCarrotURLSchemeSuffix = schemeSuffix;
}

+ (NSString*)sharedAppSchemeSuffix
{
   return sCarrotURLSchemeSuffix;
}

+ (void)plantInApplication:(Class)appDelegateClass withSecret:(NSString*)appSecret
{
   Carrot_Plant(appDelegateClass, appSecret);
}

+ (void)plant:(NSString*)appID inApplication:(Class)appDelegateClass withSecret:(NSString*)appSecret
{
   [Carrot setSharedAppID:appID];
   Carrot_Plant(appDelegateClass, appSecret);
}

+ (void)plant:(NSString*)appID inApplication:(Class)appDelegateClass urlSchemeSuffix:(NSString*)urlSchemeSuffix withSecret:(NSString*)appSecret
{
   [Carrot setSharedAppSchemeSuffix:urlSchemeSuffix];
   [Carrot setSharedAppID:appID];
   Carrot_Plant(appDelegateClass, appSecret);
}

+ (BOOL)performFacebookAuthAllowingUI:(BOOL)allowLoginUI
                        forPermission:(CarrotFacebookPermissionType)permission
{
   return Carrot_DoFacebookAuth(allowLoginUI, permission);
}

+ (BOOL)performFacebookAuthAllowingUI:(BOOL)allowLoginUI
                   forPermissionArray:(NSArray*)permissionArray
{
   return Carrot_DoFacebookAuthWithPermissions(allowLoginUI, (__bridge CFArrayRef)permissionArray);
}

+ (NSString*)debugUDID
{
   return sCarrotDebugUDID;
}

+ (void)setDebugUDID:(NSString*)debugUDID
{
   sCarrotDebugUDID = debugUDID;
}

- (void)setAuthenticationStatus:(CarrotAuthenticationStatus)status
{
   NSException *exception = [NSException exceptionWithName:@"DontUseThisSetter"
                                                    reason:@"Use setAuthenticationStatus:withError:andReason: instead."
                                                  userInfo: nil];
   @throw exception;
}

- (void)setAuthenticationStatusReason:(CarrotAuthenticationStatusReason)reason
{
   NSException *exception = [NSException exceptionWithName:@"DontUseThisSetter"
                                                    reason:@"Use setAuthenticationStatus:withError:andReason: instead."
                                                  userInfo: nil];
   @throw exception;
}

- (id)init
{
   NSString* appId = [Carrot sharedAppID];

   if(!appId || appId.length < 1)
   {
      NSException *exception = [NSException exceptionWithName:@"MissingAppIDException"
                                                       reason:@"'FacebookAppID' not found in Info.plist, and no AppID assigned via [FBSession setDefaultAppID:]. Use [Carrot plantInApplication:appId:withSecret:]."
                                                     userInfo: nil];
      @throw exception;
      return nil;
   }

   return [self initWithAppId:appId
                    appSecret:nil
              urlSchemeSuffix:[Carrot sharedAppSchemeSuffix]
               debugUDIDOrNil:[Carrot debugUDID]];
}

- (id)initWithAppId:(NSString*)appId appSecret:(NSString*)appSecret urlSchemeSuffix:(NSString*)urlSchemeSuffix debugUDIDOrNil:(NSString*)debugUDIDOrNil
{
   self = [super init];
   if(self)
   {
      _authenticationStatus = CarrotAuthenticationStatusUndetermined;
      self.lastAuthStatusReported = _authenticationStatus;
      _cachedSessionStatusReason = CarrotAuthenticationStatusReasonUnknown;

      self.appId = appId;
      self.appSecret = appSecret;
      self.udid = (debugUDIDOrNil == nil ? [[[ASIdentifierManager sharedManager] advertisingIdentifier] UUIDString] : debugUDIDOrNil);
      self.urlSchemeSuffix = urlSchemeSuffix;
      self.version = kCarrotSDKVersion;

      // Get data path
      NSArray* searchPaths = [[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask];
      self.dataPath = [[[searchPaths lastObject] path] stringByAppendingPathComponent:@"Carrot"];

      NSError* error = nil;
      BOOL succeeded = [[NSFileManager defaultManager] createDirectoryAtPath:self.dataPath
                                                 withIntermediateDirectories:YES
                                                                  attributes:nil
                                                                       error:&error];
      if(!succeeded)
      {
         NSLog(@"Unable to create Carrot data path: %@.", error);
         return nil;
      }

      // Create cache
      self.cache = [CarrotCache cacheWithPath:self.dataPath];
      if(!self.cache)
      {
         NSLog(@"Unable to create Carrot cache.");
         return nil;
      }

      // Assign install date
      _installDate = self.cache.installDate;

      self.requestThread = [[CarrotRequestThread alloc] initWithCarrot:self];
      if(!self.requestThread)
      {
         NSLog(@"Unable to create Carrot request thread.");
         return nil;
      }

      // Get bundle version information
      NSBundle* mainBundle = [NSBundle mainBundle];
      self.appVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
      self.appBuild  = [mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];

      // Check/warn if the app is set to exit in the background
      BOOL appExitsOnSuspend = NO;
      id temp = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"UIApplicationExitsOnSuspend"];
      if(temp != nil && [temp respondsToSelector:@selector(boolValue)])
         appExitsOnSuspend = [temp boolValue];
      if(appExitsOnSuspend)
      {
         NSLog(@"WARNING: Your application exits when it enters the background. This will prevent Carrot from tracking session times in your application. To change this, alter the 'UIApplicationExitsOnSuspend' key in your plist file in Xcode.");
      }
   }
   return self;
}

- (void)dealloc
{
   [self.requestThread stop];
   while(self.requestThread.isRunning)
   {
      sleep(1);
   }
   self.requestThread = nil;

   self.dataPath = nil;
   self.accessToken = nil;
   self.appId = nil;
   self.udid = nil;
   self.appSecret = nil;
   self.urlSchemeSuffix = nil;
}

- (void)setAccessToken:(NSString*)accessToken
{
   _accessToken = accessToken;

   if(self.authenticationStatus != CarrotAuthenticationStatusReady)
   {
      [self validateUser];
   }
}

- (void)setDelegate:(NSObject <CarrotDelegate>*)delegate
{
   _delegate = delegate;
   self.lastAuthStatusReported = CarrotAuthenticationStatusUndetermined;
   [self setAuthenticationStatus:_authenticationStatus withError:nil andReason:_authenticationStatusReason];
}

- (void)setAppSecret:(NSString*)appSecret
{
   _appSecret = appSecret;
}

- (void)setAuthenticationStatus:(CarrotAuthenticationStatus)authenticationStatus
                      withError:(NSError*)error andReason:(CarrotAuthenticationStatusReason)reason;
{
   @synchronized(self)
   {
      if(authenticationStatus != _authenticationStatus)
      {
         _authenticationStatusReason = reason;
         _authenticationStatus = authenticationStatus;
      }
   }

   if(self.lastAuthStatusReported != _authenticationStatus &&
      [[Carrot sharedInstance].delegate respondsToSelector:@selector(authenticationStatusChanged:withError:)])
   {
      // Delay the delegate notification just in case someone attempts to chain
      // Facebook SDK auth calls based off the delegate methods.
      dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.01f * NSEC_PER_SEC);
      dispatch_after(popTime, dispatch_get_main_queue(), ^(void)
      {
         self.lastAuthStatusReported = _authenticationStatus;
         [[Carrot sharedInstance].delegate authenticationStatusChanged:_authenticationStatus
                                                             withError:error];
      });
   }
}

- (BOOL)updateAuthenticationStatus:(long)httpCode
{
   BOOL ret = YES;
   switch(httpCode)
   {
      case 200:
      case 201:
      {
         // Everything is in order, we are online
         [self setAuthenticationStatus:CarrotAuthenticationStatusReady
                             withError:nil
                             andReason:self.cachedSessionStatusReason];

         // Signal the request thread to wake up
         [self.requestThread signal];
         break;
      }
      case 401: // Unauthorized
      {
         // The user has not allowed the 'publish_actions' permission.
         [self setAuthenticationStatus:CarrotAuthenticationStatusReadOnly
                             withError:nil
                             andReason:self.cachedSessionStatusReason];
         break;
      }
      case 405: // Method Not Allowed
      {
         // The user has not authorized the application, or deauthorized the application.
         [self setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized
                             withError:nil
                             andReason:self.cachedSessionStatusReason];
         break;
      }
      default:
      {
         ret = NO;
      }
   }
   return ret;
}

- (BOOL)handleOpenURL:(NSURL*)url
{
   BOOL ret = Carrot_HandleOpenURLFacebookSDK(url);
   self.launchUrl = url;

   if([url.scheme compare:[NSString stringWithFormat:@"fb%@%@", self.appId, self.urlSchemeSuffix]] == 0)
   {
      @try
      {
         NSMutableDictionary* queryParams = [[NSMutableDictionary alloc] init];

         // This block grabs the Auth case, where it's fb<AppID><Suffix>://authorize#params
         for(NSString* param in [url.fragment componentsSeparatedByString:@"&"])
         {
            NSArray* qparts = [param componentsSeparatedByString:@"="];
            [queryParams setObject:(qparts.count > 1 ? [qparts objectAtIndex:1] : nil)
                            forKey:[qparts objectAtIndex:0]];
         }

         // This block grabs the deep-link case, where it's fb<AppID><Suffix>://authorize?params
         for(NSString* param in [url.query componentsSeparatedByString:@"&"])
         {
            NSArray* qparts = [param componentsSeparatedByString:@"="];
            [queryParams setObject:(qparts.count > 1 ? [qparts objectAtIndex:1] : nil)
                            forKey:[qparts objectAtIndex:0]];
         }

         // In either case, assign access token
         [self setAccessToken:[queryParams objectForKey:@"access_token"]];

         // Check for deep linking
         NSString* target_url = [queryParams objectForKey:@"target_url"];
         if(target_url)
         {
            NSURL* targetURL = [NSURL URLWithString:[target_url stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            if([self.delegate respondsToSelector:@selector(applicationLinkRecieved:)])
            {
               [self.delegate applicationLinkRecieved:targetURL];
            }
         }
         return YES;
      }
      @catch (NSException* e) {}
   }
   else if([url.scheme compare:[NSString stringWithFormat:@"carrot%@%@",
                                self.appId, self.urlSchemeSuffix]] == 0)
   {
      @try
      {
         NSMutableDictionary* queryParams = [[NSMutableDictionary alloc] init];

         for(NSString* param in [url.query componentsSeparatedByString:@"&"])
         {
            NSArray* qparts = [param componentsSeparatedByString:@"="];
            [queryParams setObject:(qparts.count > 1 ? [qparts objectAtIndex:1] : nil)
                            forKey:[qparts objectAtIndex:0]];
         }

         NSString* target_url = [queryParams objectForKey:@"target_url"];
         if(target_url)
         {
            NSURL* targetURL = [NSURL URLWithString:[target_url stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            if([self.delegate respondsToSelector:@selector(applicationLinkRecieved:)])
            {
               [self.delegate applicationLinkRecieved:targetURL];
            }
         }
         return YES;
      }
      @catch (NSException* e) {}
   }
   return ret;
}

- (void)beginApplicationSession:(UIApplication*)application
{
   self.sessionStart = [NSDate date];
}

- (void)endApplicationSession:(UIApplication*)application
{
   self.sessionEnd = [NSDate date];

   NSDictionary* payload = @{
      @"start_time" : [NSNumber numberWithLongLong:(uint64_t)[self.sessionStart timeIntervalSince1970]],
      @"end_time" : [NSNumber numberWithLongLong:(uint64_t)[self.sessionEnd timeIntervalSince1970]]
   };

   dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [self beginBackgroundTaskForApplication:application];
      CarrotCachedRequest* cachedRequest =
      [CarrotCachedRequest requestForService:CarrotRequestServiceMetrics
                                  atEndpoint:@"/session.json"
                                 withPayload:payload
                                     inCache:self.cache];
      [self.requestThread processRequest:cachedRequest];
      [self endBackgroundTaskForApplication:application];
   });
}

- (void)postPremiumCurrencyPurchase:(float)amount inCurrency:(NSString*)currency
{
   NSDictionary* payload = @{
      @"amount" : [NSNumber numberWithFloat:amount],
      @"currency" : currency
   };
   [self.requestThread addRequestForService:CarrotRequestServiceMetrics
                                 atEndpoint:@"/purchase.json"
                                usingMethod:CarrotRequestTypePOST
                                withPayload:payload];
}

- (void)sendInstallMetricIfNeeded
{
   if(!self.cache.installMetricSent)
   {
      NSDictionary* payload = @{
         @"install_date" : [NSNumber numberWithLongLong:(uint64_t)[self.installDate timeIntervalSince1970]]
      };
      if([self.requestThread addRequestForService:CarrotRequestServiceMetrics
                                       atEndpoint:@"/install.json"
                                      usingMethod:CarrotRequestTypePOST
                                      withPayload:payload])
      {
         [self.cache markAppInstalled];
      }
   }
}

- (void)validateUser
{
   if(!self.accessToken) return;

   static dispatch_semaphore_t validateSema;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      validateSema = dispatch_semaphore_create(1);
   });

   NSDictionary* payload = @{
      @"api_key" : self.udid,
      @"access_token" : self.accessToken
   };

   dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      dispatch_semaphore_wait(validateSema, DISPATCH_TIME_FOREVER);

      CarrotRequest* authRequest =
      [CarrotRequest requestForService:CarrotRequestServiceAuth
                            atEndpoint:[NSString stringWithFormat:@"/games/%@/users.json", self.appId]
                           usingMethod:@"POST"
                           withPayload:payload
                              callback:^(CarrotRequest* request, NSHTTPURLResponse* response, NSData* data, CarrotRequestThread* requestThread) {
         long httpCode = response != nil ? response.statusCode : 401;

         if(httpCode == 404)
         {
            // No such user
            [self setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized withError:nil andReason:CarrotAuthenticationStatusReasonUnknown];
         }
         else if(httpCode == 403)
         {
            // User has deauthorized game
            [self setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized withError:nil andReason:CarrotAuthenticationStatusReasonUserRemovedApp];
         }
         else if(![self updateAuthenticationStatus:httpCode])
         {
            NSError* error = nil;
            NSDictionary* jsonReply = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            NSLog(@"Unknown error adding Carrot user (%ld): %@", (long)response.statusCode,
                  error ? error : jsonReply);
            [self setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error andReason:CarrotAuthenticationStatusReasonUnknown];
         }

         dispatch_semaphore_signal(validateSema);
      }];
      [self.requestThread addRequestInQueue:authRequest atFront:YES];
   });
}

- (void)setDevicePushToken:(NSData*)deviceToken
{
   NSString* deviceTokenString = [[[[deviceToken description]
                                    stringByReplacingOccurrencesOfString:@"<" withString:@""]
                                    stringByReplacingOccurrencesOfString:@">" withString:@""]
                                    stringByReplacingOccurrencesOfString:@" " withString:@""];
   if(deviceTokenString)
   {
      [self.requestThread addRequestForService:CarrotRequestServicePost
                                    atEndpoint:@"/me/devices.json"
                                   usingMethod:CarrotRequestTypePOST
                                   withPayload:@{@"device_type" : @"ios",
                                                 @"push_key" : deviceTokenString}];
   }
}

- (BOOL)postAchievement:(NSString*)achievementId
{
   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/achievements.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:@{@"achievement_id" : achievementId}];
}

- (BOOL)postHighScore:(NSUInteger)score
{
   NSDictionary* payload = @{@"value" : [NSNumber numberWithLong:score]};
   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/scores.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:payload];
}

- (BOOL)postAction:(NSString*)actionId forObjectInstance:(NSString*)objectInstanceId
{
   return [self postAction:actionId withProperties:nil forObjectInstance:objectInstanceId];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties forObjectInstance:(NSString*)objectInstanceId
{
   NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
                                   @"action_id" : actionId, @"object_instance_id" : objectInstanceId}];
   if(actionProperties != nil)
   {
      [payload setObject:actionProperties forKey:@"action_properties"];
   }

   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/actions.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:payload];
}

- (BOOL)postAction:(NSString*)actionId creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties
{
   return [self postAction:actionId withProperties:nil creatingInstanceOf:objectTypeId withProperties:objectProperties uploadingImage:nil andInstanceId:nil];
}

- (BOOL)postAction:(NSString*)actionId creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties uploadingImage:(UIImage *)image
{
   return [self postAction:actionId withProperties:nil creatingInstanceOf:objectTypeId withProperties:objectProperties uploadingImage:image andInstanceId:nil];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties
{
   return [self postAction:actionId withProperties:nil creatingInstanceOf:objectTypeId withProperties:objectProperties uploadingImage:nil andInstanceId:nil];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties uploadingImage:(UIImage *)image
{
   return [self postAction:actionId withProperties:nil creatingInstanceOf:objectTypeId withProperties:objectProperties uploadingImage:image andInstanceId:nil];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties andInstanceId:(NSString*)objectInstanceId
{
   return [self postAction:actionId withProperties:actionProperties creatingInstanceOf:objectTypeId withProperties:objectProperties uploadingImage:nil andInstanceId:objectInstanceId];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties uploadingImage:(UIImage*)image andInstanceId:(NSString*)objectInstanceId
{
   if(!objectProperties)
   {
      NSLog(@"objectProperties must not be nil.");
      return NO;
   }

   NSArray* requiredObjectProperties = (image == nil ? @[@"title", @"image", @"description"] : @[@"title", @"description"]);
   id nilMarker = [NSNull null];
   NSArray* valuesForRequiredProperties = [objectProperties objectsForKeys:requiredObjectProperties notFoundMarker:nilMarker];
   if([valuesForRequiredProperties containsObject:nilMarker])
   {
      NSLog(@"objectProperties must contain values for: %@", requiredObjectProperties);
      return NO;
   }

   // Process object properties
   NSMutableDictionary* fullObjectProperties = [NSMutableDictionary dictionaryWithDictionary:objectProperties];
   [fullObjectProperties setObject:objectTypeId forKey:@"object_type"];

   NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
                                   @"action_id" : actionId, @"object_properties" : fullObjectProperties}];

   // Image upload or hosted image
   if(image == nil)
   {
      [fullObjectProperties setObject:[objectProperties objectForKey:@"image"] forKey:@"image_url"];
      [fullObjectProperties removeObjectForKey:@"image"];
   }
   else
   {
      unsigned char hash[CC_SHA256_DIGEST_LENGTH];
      NSData* pngImage = UIImagePNGRepresentation(image);
      if(!CC_SHA256([pngImage bytes], (unsigned int)[pngImage length], hash)) return NO;

      NSString* sha256 = [NSDataWithBase64 base64EncodedStringFromData:[NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH]];
      [fullObjectProperties setObject:URLEscapedString(sha256) forKey:@"image_sha"];
      [payload setObject:[NSDataWithBase64 base64EncodedStringFromData:pngImage] forKey:@"image_bytes"];
   }

   if(objectInstanceId != nil)
   {
      [fullObjectProperties setObject:objectInstanceId forKey:@"identifier"];
   }

   if(actionProperties != nil)
   {
      [payload setObject:actionProperties forKey:@"action_properties"];
   }

   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/actions.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:payload];
}

-(BOOL)likeGame
{
   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/like.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:@{@"object" : @"game"}];
}

-(BOOL)likePublisher
{
   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/like.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:@{@"object" : @"publisher"}];
}

-(BOOL)likeAchievement:(NSString*)achievementId;
{
   NSString* likeObject = [NSString stringWithFormat:@"achievement:%@", achievementId];
   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/like.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:@{@"object" : likeObject}];
}

-(BOOL)likeObject:(NSString*)objectInstanceId
{
   NSString* likeObject = [NSString stringWithFormat:@"object:%@", objectInstanceId];
   return [self.requestThread addRequestForService:CarrotRequestServicePost
                                        atEndpoint:@"/me/like.json"
                                       usingMethod:CarrotRequestTypePOST
                                       withPayload:@{@"object" : likeObject}];
}

- (void)beginBackgroundTaskForApplication:(UIApplication*)application
{
   self.backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
      [self endBackgroundTaskForApplication:application];
   }];
}

- (void)endBackgroundTaskForApplication:(UIApplication*)application
{
   [application endBackgroundTask: self.backgroundTask];
   self.backgroundTask = UIBackgroundTaskInvalid;
}

@end
