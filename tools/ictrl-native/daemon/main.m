// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import "ICNProtocol.h"
#import "ICNAuth.h"
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <fcntl.h>

static ICNAuth *auth;
static dispatch_queue_t rpcQueue;
static NSDictionary *Request(int fd) {
    NSMutableData *wire=[NSMutableData data];
    NSData *delimiter=[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange split=NSMakeRange(NSNotFound,0);
    while(split.location==NSNotFound) {
        uint8_t buffer[2048]; ssize_t n=recv(fd,buffer,sizeof(buffer),0);
        if(n<0&&errno==EINTR)continue;
        if(n<=0)return nil;
        [wire appendBytes:buffer length:(NSUInteger)n];
        split=[wire rangeOfData:delimiter options:0 range:NSMakeRange(0,wire.length)];
        if((split.location==NSNotFound && wire.length>8192) || (split.location!=NSNotFound&&split.location>8192))return nil;
    }
    NSString *header=[[NSString alloc]initWithData:[wire subdataWithRange:NSMakeRange(0,split.location)] encoding:NSASCIIStringEncoding];
    NSArray *lines=[header componentsSeparatedByString:@"\r\n"];
    NSArray *first=[lines.firstObject componentsSeparatedByString:@" "];
    if(first.count!=3 || ![first[2] isEqual:@"HTTP/1.1"])return nil;
    NSString *method=first[0],*path=first[1];
    if(![@[@"GET",@"POST"] containsObject:method] || ![path hasPrefix:@"/"] || [path containsString:@"?"])return nil;
    NSMutableDictionary *headers=[NSMutableDictionary dictionary];
    for(NSUInteger i=1;i<lines.count;i++) {
        NSString *line=lines[i]; NSRange colon=[line rangeOfString:@":"];
        if(colon.location==NSNotFound || colon.location==0)return nil;
        NSString *key=[[line substringToIndex:colon.location] lowercaseString];
        NSString *value=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(headers[key] || [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location!=NSNotFound)return nil;
        headers[key]=value;
    }
    if(headers[@"transfer-encoding"] || headers[@"origin"] || headers[@"sec-fetch-site"])return nil;
    NSString *host=headers[@"host"];
    if(![@[@"127.0.0.1:8200",@"localhost:8200"] containsObject:host])return nil;
    NSString *len=headers[@"content-length"] ?: @"0";
    if(len.length==0 || len.length>6 || [len rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound)return nil;
    NSUInteger length=(NSUInteger)len.longLongValue;
    if(length>ICN_MAX_REQUEST || ([method isEqual:@"POST"] && length==0) || ([method isEqual:@"GET"]&&length!=0))return nil;
    NSUInteger start=split.location+4;
    if(wire.length>start+length)return nil; // No pipelining/request smuggling.
    NSMutableData *body=[[wire subdataWithRange:NSMakeRange(start,wire.length-start)] mutableCopy];
    while(body.length<length) {
        uint8_t buffer[4096]; ssize_t n=recv(fd,buffer,MIN(sizeof(buffer),length-body.length),0);
        if(n<0&&errno==EINTR)continue; if(n<=0)return nil;
        [body appendBytes:buffer length:(NSUInteger)n];
    }
    return @{@"method":method,@"path":path,@"body":body};
}
static void ReplyData(int fd,int status,NSString *type,NSData *data) {
    NSString *line=[NSString stringWithFormat:@"HTTP/1.1 %d Response\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n",status,type,(unsigned long)data.length];
    NSData *header=[line dataUsingEncoding:NSASCIIStringEncoding];
    if(ICNWriteExact(fd,header.bytes,header.length))ICNWriteExact(fd,data.bytes,data.length);
}
static void Reply(int fd,int status,NSDictionary *body) { ReplyData(fd,status,@"application/json",ICNJSON(body)); }
static NSDictionary *Failure(NSInteger code,NSString *message,id requestID) {
    return @{@"jsonrpc":@"2.0",@"id":requestID?:NSNull.null,@"error":@{@"code":@(code),@"message":message}};
}
static NSDictionary *Dispatch(NSDictionary *rpc) {
    id requestID=rpc[@"id"]?:NSNull.null;
    if(![rpc[@"jsonrpc"] isEqual:@"2.0"] || ![rpc[@"method"] isKindOfClass:NSString.class]
        || (!([requestID isKindOfClass:NSString.class]||[requestID isKindOfClass:NSNumber.class]||requestID==NSNull.null))
        || (rpc[@"params"]&&![rpc[@"params"] isKindOfClass:NSDictionary.class]))
        return Failure(-32600,@"Invalid JSON-RPC request",nil);
    NSString *method=rpc[@"method"]; NSDictionary *params=rpc[@"params"]?:@{};
    if(![@[@"device_info",@"screenshot"] containsObject:method])
        return Failure(-32601,@"Stage 1 only implements device_info and screenshot",requestID);
    NSArray *allowed=[method isEqual:@"screenshot"] ? @[@"format",@"quality",@"scale"]:@[];
    for(NSString *key in params) if(![allowed containsObject:key])return Failure(-32602,@"Unsupported parameter for this stage",requestID);
    NSDictionary *result=ICNBridgeCall([method isEqual:@"device_info"]?@"info":@"screenshot",params,8);
    if(result[@"error"]) {
        NSInteger code=[result[@"error"][@"code"] isEqual:@"invalid_params"] ? -32602:-32001;
        return @{@"jsonrpc":@"2.0",@"id":requestID,@"error":@{@"code":@(code),@"message":result[@"error"][@"message"],@"data":result[@"error"]}};
    }
    NSMutableDictionary *enriched=[result mutableCopy];
    enriched[@"device_id"]=auth.deviceID;
    if([method isEqual:@"device_info"])enriched[@"device_name"]=result[@"name"]?:@"iPhone";
    if([method isEqual:@"screenshot"]) {
        enriched[@"encoding"]=@"base64"; enriched[@"requested_scale"]=params[@"scale"]?:@2;
        enriched[@"width"]=result[@"point_width"]; enriched[@"height"]=result[@"point_height"];
        if([result[@"format"] isEqual:@"png"])[enriched removeObjectForKey:@"quality"];
    }
    return @{@"jsonrpc":@"2.0",@"id":requestID,@"result":enriched};
}
static NSDictionary *Schema(void) {
    return @{@"server":@"iCTRL Native",@"server_version":ICN_VERSION,@"protocol_version":@1,
        @"stage":@1,@"requires_ddi":@NO,@"experimental":@YES,
        @"auth":@"X25519 pairing with local approval; encrypted envelope_v1",
        @"methods":@[@{@"name":@"device_info",@"params":@[]},
                     @{@"name":@"screenshot",@"params":@[@"format: jpeg|png",@"scale: 0.25..3",@"quality: 0.1..1"]}],
        @"hint":@"Read-only experimental native bridge. No tap, typing, UI tree, DDI, video or LAN support."};
}
static void ICNHandleHTTP(int fd) {
    NSDictionary *request=Request(fd);
    if(!request) { Reply(fd,400,ICNError(@"bad_request",@"Invalid HTTP framing or browser-origin request")); return; }
    NSString *method=request[@"method"],*path=request[@"path"];
    if([method isEqual:@"GET"]) {
        if([path isEqual:@"/whoami"])Reply(fd,200,@{@"device_id":auth.deviceID,@"server_version":ICN_VERSION,@"protocol_version":@1});
        else if([path isEqual:@"/schema"])Reply(fd,200,Schema());
        else if([path isEqual:@"/skill/clients/cli"]||[path isEqual:@"/skill/clients/cli.sh"]||[path isEqual:@"/skill"]) {
            NSString *name=[path isEqual:@"/skill"] ? @"SKILL.md":([path hasSuffix:@".sh"]?@"ictrl.sh":@"ictrl");
            NSData *data=[NSData dataWithContentsOfFile:[ICN_RESOURCE stringByAppendingPathComponent:name]];
            if(data)ReplyData(fd,200,[name isEqual:@"ictrl"]?@"application/octet-stream":@"text/plain; charset=utf-8",data);
            else Reply(fd,503,ICNError(@"resource_missing",@"Bundled client not available"));
        } else Reply(fd,404,ICNError(@"not_found",@"No such endpoint"));
        return;
    }
    NSDictionary *object=ICNJSONData(request[@"body"]);
    if(!object) { Reply(fd,400,ICNError(@"bad_request",@"JSON object required")); return; }
    dispatch_sync(rpcQueue, ^{
        if([path isEqual:@"/pair"]) {
            NSDictionary *paired=[auth pair:object];
            Reply(fd,paired[@"error"]?403:200,paired);
        } else if([path isEqual:@"/rpc"]) {
            NSDictionary *context=nil; NSDictionary *rpc=[auth open:object context:&context];
            if(!context) { Reply(fd,401,rpc); return; }
            Reply(fd,200,[auth seal:Dispatch(rpc) context:context]);
        } else Reply(fd,404,ICNError(@"not_found",@"No such endpoint"));
    });
}
int main(void) {
    @autoreleasepool {
        if(getuid()!=ICN_MOBILE_UID || !ICNEnsureStateDirectory() || !ICNSafeStateDirectory()) { fprintf(stderr,"ictrld: unsafe user/state directory\n"); return 1; }
        auth=[[ICNAuth alloc]initWithStatePath:[ICN_STATE stringByAppendingPathComponent:@"sessions.json"]];
        if(!auth) { fprintf(stderr,"ictrld: unsafe/corrupt authorization store\n"); return 1; }
        rpcQueue=dispatch_queue_create("com.judegor.ictrl-native.rpc",DISPATCH_QUEUE_SERIAL);
        signal(SIGPIPE,SIG_IGN);
        int fd=socket(AF_INET,SOCK_STREAM,0),yes=1;
        setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
        struct sockaddr_in addr={0}; addr.sin_family=AF_INET; addr.sin_port=htons(8200); addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        if(fd<0 || bind(fd,(struct sockaddr *)&addr,sizeof(addr)) || listen(fd,4)) {
            fprintf(stderr,"ictrld: cannot bind 127.0.0.1:8200 (another runner may own it)\n"); if(fd>=0)close(fd); return 1;
        }
        fprintf(stderr,"ictrld: read-only stage1 listening on 127.0.0.1:8200\n");
        dispatch_semaphore_t slots=dispatch_semaphore_create(4);
        for(;;) {
            dispatch_semaphore_wait(slots,DISPATCH_TIME_FOREVER);
            struct sockaddr_in peer; socklen_t size=sizeof(peer);
            int client=accept(fd,(struct sockaddr *)&peer,&size);
            if(client<0) { dispatch_semaphore_signal(slots); if(errno==EINTR)continue; break; }
            if(peer.sin_addr.s_addr!=htonl(INADDR_LOOPBACK)) {close(client);dispatch_semaphore_signal(slots);continue;}
            ICNSetTimeout(client,5);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                @autoreleasepool {
                    @try { ICNHandleHTTP(client); } @catch(NSException *e) { Reply(client,500,ICNError(@"internal",@"Internal error")); }
                    shutdown(client,SHUT_RDWR); close(client); dispatch_semaphore_signal(slots);
                }
            });
        }
        close(fd);
    }
    return 1;
}
