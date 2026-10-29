// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#define ICN_VERSION @"0.1.2"
#define ICN_SOCKET "/var/jb/var/mobile/Library/ictrl-native/bridge.sock"
#define ICN_STATE @"/var/jb/var/mobile/Library/ictrl-native"
#define ICN_RESOURCE @"/var/jb/usr/share/ictrl-native"
#define ICN_DAEMON "/var/jb/usr/libexec/ictrld"
#define ICN_MAX_FRAME (6 * 1024 * 1024)
#define ICN_MAX_REQUEST (64 * 1024)
#define ICN_MOBILE_UID 501
// A fixed, audited IPC vocabulary: info, screenshot, approve_pair only.
NSDictionary *ICNBridgeCall(NSString *method, NSDictionary *params, NSTimeInterval timeout);
BOOL ICNReadExact(int fd, void *buffer, size_t length);
BOOL ICNWriteExact(int fd, const void *buffer, size_t length);
NSDictionary *ICNReadFrame(int fd, NSUInteger maximum);
BOOL ICNWriteFrame(int fd, NSDictionary *object);
BOOL ICNVerifyPeer(int fd, BOOL daemonPeer);
NSDictionary *ICNError(NSString *code, NSString *message);
NSDictionary *ICNJSONData(NSData *data);
NSData *ICNJSON(NSDictionary *object);
void ICNSetTimeout(int fd, NSTimeInterval seconds);
BOOL ICNEnsureStateDirectory(void);
BOOL ICNSafeStateDirectory(void);
