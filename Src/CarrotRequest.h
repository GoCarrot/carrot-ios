/* Carrot -- Copyright (C) 2012 Carrot Inc.
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

#import <Foundation/Foundation.h>
#include <sqlite3.h>

@class CarrotRequestThread;

typedef void (^CarrotRequestResponse)(NSHTTPURLResponse* response, NSData* data, CarrotRequestThread* requestThread);

extern NSString* CarrotRequestTypeGET;
extern NSString* CarrotRequestTypePOST;

@interface CarrotRequest : NSObject

@property (strong, nonatomic, readonly) NSString* endpoint;
@property (strong, nonatomic, readonly) NSDictionary* payload;
@property (strong, nonatomic, readonly) NSString* method;
@property (strong, nonatomic, readonly) CarrotRequestResponse callback;

+ (id)requestForEndpoint:(NSString*)endpoint usingMethod:(NSString*)method withPayload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback;
- (id)initWithEndpoint:(NSString*)endpoint usingMethod:(NSString*)method payload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback;

- (NSString*)description;

@end