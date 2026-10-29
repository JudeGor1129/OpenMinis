// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
@interface ICNAuth : NSObject
@property(nonatomic,readonly) NSString *deviceID;
- (instancetype)initWithStatePath:(NSString *)path;
- (NSDictionary *)pair:(NSDictionary *)body;
- (NSDictionary *)open:(NSDictionary *)envelope context:(NSDictionary **)context;
- (NSDictionary *)seal:(NSDictionary *)response context:(NSDictionary *)context;
@end
