// SPDX-License-Identifier: Apache-2.0
// Native implementation of iCTRL's documented envelope-v1. X25519 and SHA/HMAC
// primitives in vendor/ictrl are reused unmodified under the upstream license.
#import "ICNAuth.h"
#import "ICNProtocol.h"
#import "ictrl.h"
#import <Security/SecRandom.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>

static NSData *H(NSData *key, NSData *data) {
    uint8_t out[32]; hmac_sha256(key.bytes, key.length, data.bytes, data.length, out);
    return [NSData dataWithBytes:out length:32];
}
static NSData *Join(NSString *label, NSData *a, NSData *b) {
    NSMutableData *data = [[label dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (a) [data appendData:a]; if (b) [data appendData:b]; return data;
}
static NSData *Random(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    return SecRandomCopyBytes(kSecRandomDefault,length,data.mutableBytes) == errSecSuccess ? data : nil;
}
static NSString *Hex(NSData *data) {
    NSMutableData *out = [NSMutableData dataWithLength:data.length*2+1];
    hex_encode(data.bytes,data.length,out.mutableBytes);
    return [NSString stringWithUTF8String:out.bytes];
}
static NSData *Unhex(id value, NSUInteger length) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != length*2) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:length];
    return hex_decode([value UTF8String], out.mutableBytes, length) == 0 ? out : nil;
}
static NSData *Crypt(NSData *key, NSData *nonce, NSData *input) {
    NSMutableData *out = [NSMutableData dataWithLength:input.length];
    const uint8_t *src = input.bytes; uint8_t *dst = out.mutableBytes;
    hmac_ctx base; hmac_init(&base,key.bytes,key.length);
    for (NSUInteger at=0; at<input.length; at+=32) {
        uint32_t be = htonl((uint32_t)(at/32)); uint8_t stream[32];
        hmac_ctx block = base;
        hmac_update(&block,nonce.bytes,nonce.length); hmac_update(&block,(void *)&be,4); hmac_final(&block,stream);
        for (NSUInteger j=0; j<MIN((NSUInteger)32,input.length-at);j++) dst[at+j]=src[at+j]^stream[j];
    }
    return out;
}
static BOOL Equal(NSData *a, NSData *b) {
    if (a.length != b.length) return NO;
    const uint8_t *x=a.bytes,*y=b.bytes; uint8_t delta=0;
    for (NSUInteger i=0;i<a.length;i++) delta|=x[i]^y[i]; return delta==0;
}
static BOOL Save(NSString *path, NSDictionary *state) {
    NSData *data = ICNJSON(state);
    NSString *temp = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = open(temp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if (fd < 0) return NO;
    NSUInteger at=0; BOOL ok=YES;
    while (at<data.length) {
        ssize_t n=write(fd,(const char *)data.bytes+at,data.length-at);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) { ok=NO; break; } at+=n;
    }
    if (ok) ok=fsync(fd)==0;
    close(fd);
    if (ok) ok=rename(temp.fileSystemRepresentation,path.fileSystemRepresentation)==0;
    if (!ok) unlink(temp.fileSystemRepresentation);
    int dir=open(path.stringByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY);
    if (dir>=0) { fsync(dir); close(dir); }
    return ok;
}
@interface ICNAuth ()
@property(nonatomic,readwrite) NSString *deviceID;
@property(nonatomic) NSString *statePath;
@property(nonatomic) NSMutableDictionary *sessions;
@property(nonatomic) NSMutableDictionary *seen;
@property(nonatomic) double pairAfter;
@end
@implementation ICNAuth
- (instancetype)initWithStatePath:(NSString *)path {
    if (!(self=[super init])) return nil;
    _statePath=path; _sessions=[NSMutableDictionary dictionary]; _seen=[NSMutableDictionary dictionary];
    struct stat s;
    NSDictionary *state=nil;
    if (lstat(path.fileSystemRepresentation,&s)==0) {
        if (!S_ISREG(s.st_mode) || s.st_uid!=getuid() || (s.st_mode & 077) || s.st_size>65536) return nil;
        int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
        if (fd<0) return nil;
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];
        size_t at=0;
        while(at<data.length) {
            ssize_t n=read(fd,(char *)data.mutableBytes+at,data.length-at);
            if(n<0&&errno==EINTR)continue;
            if(n<=0)break; at+=n;
        }
        close(fd);
        state = at==data.length ? ICNJSONData(data):nil;
        if (!state) return nil; // Never silently replace an unsafe or corrupt store.
    } else if (errno!=ENOENT) return nil;
    _deviceID=[state[@"device_id"] isKindOfClass:NSString.class] ? state[@"device_id"] : NSUUID.UUID.UUIDString;
    if (state && ![state[@"sessions"] isKindOfClass:NSDictionary.class]) return nil;
    double now=NSDate.date.timeIntervalSince1970;
    for (NSString *tok in state[@"sessions"]) {
        NSDictionary *entry=state[@"sessions"][tok];
        NSData *key=[entry isKindOfClass:NSDictionary.class] ? Unhex(entry[@"key"],32):nil;
        uint8_t hash[32]; if (!key) return nil;
        sha256(key.bytes,key.length,hash);
        if (![tok isEqual:Hex([NSData dataWithBytes:hash length:4])]) return nil;
        if (![entry[@"last_used"] isKindOfClass:NSNumber.class]) return nil;
        if (now-[entry[@"last_used"] doubleValue]<30*86400) _sessions[tok]=entry;
    }
    if (![self persist]) return nil;
    return self;
}
- (BOOL)persist { return Save(self.statePath,@{ @"device_id":self.deviceID,@"sessions":self.sessions }); }
- (NSDictionary *)pair:(NSDictionary *)body {
    double now=NSDate.date.timeIntervalSince1970;
    if (now<self.pairAfter) return ICNError(@"pair_cooldown",@"Wait before requesting another pairing");
    NSString *name=body[@"client_name"];
    if (![name isKindOfClass:NSString.class] || name.length==0 || name.length>64
        || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
        return ICNError(@"bad_request",@"client_name must be 1..64 characters without control characters");
    NSString *pubText=body[@"pub"];
    NSData *pub=[pubText isKindOfClass:NSString.class] && pubText.length<=48 ? [[NSData alloc]initWithBase64EncodedString:pubText options:0]:nil;
    if (pub.length!=32) return ICNError(@"bad_request",@"X25519 pub (base64, 32 bytes) is required");
    NSData *priv=Random(32), *key=Random(32);
    if (!priv || !key) return ICNError(@"internal",@"Secure random unavailable");
    uint8_t devicePub[32], shared[32];
    x25519_base(devicePub,priv.bytes); x25519(shared,priv.bytes,pub.bytes);
    uint8_t any=0; for (NSUInteger i=0;i<32;i++) any|=shared[i];
    if (!any) return ICNError(@"bad_request",@"Invalid X25519 public key");
    uint8_t hash[32]; sha256(pub.bytes,pub.length,hash);
    NSString *fingerprint=Hex([NSData dataWithBytes:hash length:4]);
    self.pairAfter=now+15;
    NSDictionary *decision=ICNBridgeCall(@"approve_pair",@{@"name":name,@"fingerprint":fingerprint},50);
    self.pairAfter=NSDate.date.timeIntervalSince1970+15;
    if (![decision[@"approved"] isEqual:@YES]) return ICNError(@"pair_denied",@"User denied, device locked, or local approval is unavailable");
    sha256(key.bytes,key.length,hash);
    NSString *tok=Hex([NSData dataWithBytes:hash length:4]);
    if (self.sessions[tok]) return ICNError(@"internal",@"Session ID collision; request a new pairing");
    if (self.sessions.count>=8) return ICNError(@"session_limit",@"Session limit reached; revoke existing sessions before pairing");
    NSData *public=[NSData dataWithBytes:devicePub length:32];
    NSData *wrap=H([NSData dataWithBytes:shared length:32],Join(@"ictrl-pair",pub,public));
    NSData *pad=H(wrap,[@"ictrl-wrap" dataUsingEncoding:NSUTF8StringEncoding]);
    uint8_t wrapped[32]; const uint8_t *k=key.bytes,*p=pad.bytes;
    for(NSUInteger i=0;i<32;i++)wrapped[i]=k[i]^p[i];
    self.sessions[tok]=@{@"key":Hex(key),@"name":name,@"last_used":@(now)};
    if (![self persist]) { [self.sessions removeObjectForKey:tok]; return ICNError(@"internal",@"Cannot persist authorization"); }
    return @{ @"tok":tok,@"client_name":name,@"expires":@((long long)now+30*86400),
        @"pub":[public base64EncodedStringWithOptions:0],@"token_ct":Hex([NSData dataWithBytes:wrapped length:32]) };
}
- (NSDictionary *)open:(NSDictionary *)e context:(NSDictionary **)context {
    *context=nil;
    id ts=e[@"ts"],v=e[@"v"];
    NSString *tok=e[@"tok"],*nonceHex=e[@"nonce"],*ctText=e[@"ct"];
    if (![v isKindOfClass:NSNumber.class] || [v intValue]!=1 || ![tok isKindOfClass:NSString.class])
        return ICNError(@"auth_required",@"Encrypted envelope v1 required; pair once with on-device approval");
    NSData *nonce=Unhex(nonceHex,16),*tag=Unhex(e[@"tag"],32),*tok4=Unhex(tok,4);
    if (![ts isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)ts)==CFBooleanGetTypeID()
        || !isfinite([ts doubleValue]) || [ts doubleValue]<0 || [ts doubleValue]!=floor([ts doubleValue])
        || [ts doubleValue]>9007199254740991.0 || !nonce || !tag || !tok4
        || ![ctText isKindOfClass:NSString.class] || ctText.length>ICN_MAX_REQUEST)
        return ICNError(@"bad_envelope",@"Malformed envelope fields");
    NSData *ct=[[NSData alloc]initWithBase64EncodedString:ctText options:0];
    if (!ct) return ICNError(@"bad_envelope",@"Invalid base64 ciphertext");
    double now=NSDate.date.timeIntervalSince1970;
    if (fabs(now-[ts doubleValue])>120) return ICNError(@"ts_skew",@"Request timestamp outside +/-120 seconds");
    NSMutableDictionary *entry=[self.sessions[tok] mutableCopy];
    NSData *key=Unhex(entry[@"key"],32);
    if (!key || now-[entry[@"last_used"] doubleValue]>=30*86400) return ICNError(@"auth_failed",@"Unknown or expired session; pair again");
    uint64_t be=CFSwapInt64HostToBig([ts unsignedLongLongValue]);
    NSMutableData *signedData=[Join(@"v1",tok4,[NSData dataWithBytes:&be length:8]) mutableCopy];
    [signedData appendData:nonce]; [signedData appendData:ct];
    NSData *mac=H(key,Join(@"ictrl-v1|mac",nonce,nil));
    if (!Equal(tag,H(mac,signedData))) return ICNError(@"bad_tag",@"MAC verification failed");
    // Canonical bytes, not caller-provided hex casing, form the replay key.
    NSString *canonical=Hex(nonce);
    NSMutableDictionary *seen=self.seen[tok];
    if (!seen) { seen=[NSMutableDictionary dictionary]; self.seen[tok]=seen; }
    for (NSString *n in seen.allKeys) if (now-[seen[n] doubleValue]>120) [seen removeObjectForKey:n];
    if (seen[canonical]) return ICNError(@"nonce_replayed",@"Nonce already used");
    if (seen.count>=4096) return ICNError(@"rate_limited",@"Replay cache full; wait for timestamp expiry");
    seen[canonical]=ts;
    entry[@"last_used"]=@(now); self.sessions[tok]=entry;
    // Persist at most once/hour; replay tracking remains process-scoped.
    if (now-[entry[@"saved_at"] doubleValue]>3600) { entry[@"saved_at"]=@(now); [self persist]; }
    *context=@{@"key":key,@"nonce":nonce,@"nonce_hex":canonical};
    NSData *plain=Crypt(H(key,Join(@"ictrl-v1|enc-req",nonce,nil)),nonce,ct);
    return ICNJSONData(plain) ?: @{};
}
- (NSDictionary *)seal:(NSDictionary *)response context:(NSDictionary *)context {
    NSData *key=context[@"key"],*nonce=context[@"nonce"];
    NSData *ct=Crypt(H(key,Join(@"ictrl-v1|enc-resp",nonce,nil)),nonce,ICNJSON(response));
    NSData *tag=H(H(key,Join(@"ictrl-v1|mac",nonce,nil)),Join(@"resp",nonce,ct));
    return @{@"v":@1,@"nonce":context[@"nonce_hex"],@"ct":[ct base64EncodedStringWithOptions:0],@"tag":Hex(tag)};
}
@end
