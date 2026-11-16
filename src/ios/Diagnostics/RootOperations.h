#ifndef MINIS_ROOT_OPERATIONS_H
#define MINIS_ROOT_OPERATIONS_H
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include "PluginArchivePolicy.h"
#include "RootCommandProcess.h"

static pthread_mutex_t MROActiveLock = PTHREAD_MUTEX_INITIALIZER;
static MinisRootChildControl *MROActiveChild = NULL;
static inline void MROSetActiveChild(MinisRootChildControl *control) {
    pthread_mutex_lock(&MROActiveLock); MROActiveChild = control; pthread_mutex_unlock(&MROActiveLock);
}
static inline void MROClearActiveChild(MinisRootChildControl *control) {
    pthread_mutex_lock(&MROActiveLock); if (MROActiveChild == control) MROActiveChild = NULL; pthread_mutex_unlock(&MROActiveLock);
}
static inline void MRORevokeActiveChild(void) {
    pthread_mutex_lock(&MROActiveLock); MinisRootChildControl *control = MROActiveChild;
    if (control) MRChildRevoke(control); pthread_mutex_unlock(&MROActiveLock);
}

static void MROEmit(NSDictionary *object, int code) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (!data) _exit(74);
    const uint8_t *p = data.bytes; size_t left = data.length;
    while (left) { ssize_t n = write(STDOUT_FILENO, p, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) _exit(74); p += n; left -= (size_t)n; }
    (void)write(STDOUT_FILENO, "\n", 1); _exit(code);
}
static void MROFail(NSString *action, NSString *code, NSString *message) {
    MROEmit(@{@"protocol": @3, @"ok": @NO, @"action": action ?: @"unknown", @"code": code ?: @"error", @"stage": @"root-operation", @"error": message ?: @"Operation failed"}, 1);
}
static NSString *MROHexSHA(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    static const char h[] = "0123456789abcdef"; char out[65];
    for (int i = 0; i < 32; i++) { out[i * 2] = h[digest[i] >> 4]; out[i * 2 + 1] = h[digest[i] & 15]; }
    out[64] = 0; return [NSString stringWithUTF8String:out];
}
static NSString *MRORequired(NSDictionary *request, NSString *key, NSString *action) {
    id value = request[key];
    if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) MROFail(action, @"invalid_request", [NSString stringWithFormat:@"Missing %@", key]);
    return value;
}
static NSDictionary *MROIDs(void) {
    return @{@"uid": @(getuid()), @"euid": @(geteuid()), @"gid": @(getgid()), @"egid": @(getegid()), @"root_verified": @(getuid() == 0 && geteuid() == 0 && getgid() == 0 && getegid() == 0)};
}
static NSString *MROStateBase(NSString *action) {
    char bootstrap[PATH_MAX];
    if (!realpath("/var/jb", bootstrap)) MROFail(action, @"bootstrap_missing", @"Active rootless bootstrap cannot resolve.");
    NSString *base = [NSString stringWithFormat:@"%s/var/tmp/MinisSystemAccess", bootstrap];
    struct stat st;
    if (lstat(base.fileSystemRepresentation, &st) != 0) {
        if (mkdir(base.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) MROFail(action, @"state_create_failed", @"Cannot create root operation state.");
        (void)chmod(base.fileSystemRepresentation, 0700);
    }
    char resolved[PATH_MAX];
    if (!realpath(base.fileSystemRepresentation, resolved) || ![[NSString stringWithUTF8String:resolved] isEqualToString:base])
        MROFail(action, @"state_invalid", @"Root operation state path is not canonical.");
    if (lstat(base.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) || (st.st_mode & 077) != 0 || (st.st_uid != 0 && st.st_uid != 501)) MROFail(action, @"state_invalid", @"Root operation state directory is unsafe.");
    return base;
}
static void MROFsyncDir(NSString *path, NSString *action) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0 || fsync(fd)) { if (fd >= 0) close(fd); MROFail(action, @"directory_sync_failed", @"Parent directory fsync failed."); }
    close(fd);
}
static void MROAtomic(NSData *data, NSString *path, mode_t mode, NSString *action) {
    NSString *dir = path.stringByDeletingLastPathComponent;
    struct stat st; if (lstat(dir.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) || (st.st_mode & 077) != 0) MROFail(action, @"staging_parent_invalid", @"Destination parent is unsafe.");
    NSString *tmp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".minis-root-%@.tmp", NSUUID.UUID.UUIDString]];
    int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode & 0777);
    if (fd < 0) MROFail(action, @"staging_open_failed", @"Cannot create staging file.");
    const uint8_t *p = data.bytes; size_t left = data.length;
    while (left) { ssize_t n = write(fd, p, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) { close(fd); unlink(tmp.fileSystemRepresentation); MROFail(action, @"staging_write_failed", @"Cannot write staging file."); } p += n; left -= (size_t)n; }
    if (fsync(fd) || close(fd) || rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation)) { unlink(tmp.fileSystemRepresentation); MROFail(action, @"staging_commit_failed", @"Cannot atomically publish staging file."); }
    (void)chmod(path.fileSystemRepresentation, mode & 0777); MROFsyncDir(dir, action);
}
static BOOL MROUUID(NSString *value) { return value.length == 36 && [[NSUUID alloc] initWithUUIDString:value] != nil; }
static BOOL MROSHA(NSString *value) {
    if (value.length != 64) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound;
}
static NSString *MROStagePath(NSString *base, NSString *stageID, BOOL final, NSString *action) {
    NSString *dir = [base stringByAppendingPathComponent:@"Packages"];
    struct stat st; if (lstat(dir.fileSystemRepresentation, &st) != 0) { if (mkdir(dir.fileSystemRepresentation, 0700) && errno != EEXIST) MROFail(action, @"staging_create_failed", @"Cannot create package staging directory."); }
    if (lstat(dir.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) || (st.st_mode & 077) != 0) MROFail(action, @"staging_invalid", @"Package staging directory is unsafe.");
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stageID, final ? @"deb" : @"part"]];
}
static void MROAudit(NSString *base, NSDictionary *metadata, NSString *action) {
    NSString *dir = [base stringByAppendingPathComponent:@"Audit"]; mkdir(dir.fileSystemRepresentation, 0700);
    NSString *path = [dir stringByAppendingPathComponent:@"system-access.jsonl"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:NULL]; NSMutableData *line = [json mutableCopy]; [line appendBytes:"\n" length:1];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) MROFail(action, @"audit_open_failed", @"Cannot open audit log.");
    const uint8_t *p = line.bytes; size_t left = line.length;
    while (left) { ssize_t n = write(fd, p, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) { close(fd); MROFail(action, @"audit_write_failed", @"Cannot write audit log."); } p += n; left -= (size_t)n; }
    if (fsync(fd) || close(fd)) MROFail(action, @"audit_sync_failed", @"Cannot sync audit log."); MROFsyncDir(dir, action);
}
static NSData *MROChunk(NSDictionary *request, NSString *action) {
    NSString *encoded = MRORequired(request, @"chunk_base64", action);
    if (encoded.length > 2400000) MROFail(action, @"chunk_too_large", @"Encoded chunk exceeds the bounded request size.");
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!data || data.length == 0 || data.length > 1700000) MROFail(action, @"chunk_invalid", @"Chunk is not bounded base64 data.");
    return data;
}
static NSString *MROFilePath(NSString *base, NSString *stageID, NSString *suffix, NSString *action) {
    NSString *dir = [base stringByAppendingPathComponent:@"Files"];
    struct stat st;
    if (lstat(dir.fileSystemRepresentation, &st) != 0) {
        if (mkdir(dir.fileSystemRepresentation, 0700) && errno != EEXIST) MROFail(action, @"file_staging_create_failed", @"Cannot create file staging directory.");
        (void)chmod(dir.fileSystemRepresentation, 0700);
    }
    if (lstat(dir.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) || (st.st_mode & 077) != 0) MROFail(action, @"file_staging_invalid", @"File staging directory is unsafe.");
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stageID, suffix]];
}
static mode_t MROCopyTargetMode(NSString *target, NSString *action) {
    NSString *root = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";
    if (![target isKindOfClass:NSString.class] || !target.isAbsolutePath || target.length > PATH_MAX - 1 ||
        ![target hasPrefix:[root stringByAppendingString:@"/"]] || [target containsString:@"//"] ||
        ![target.stringByStandardizingPath isEqualToString:target] || [target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        MROFail(action, @"copy_target_invalid", @"Target must be one canonical DynamicLibraries file.");
    for (NSString *part in target.pathComponents) if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) MROFail(action, @"copy_target_invalid", @"Dot path components are forbidden.");
    NSString *name = target.lastPathComponent;
    if (name.length == 0 || name.length > 128 || (![name.pathExtension.lowercaseString isEqualToString:@"dylib"] && ![name.pathExtension.lowercaseString isEqualToString:@"plist"]))
        MROFail(action, @"copy_extension_denied", @"Only a dylib or companion plist can be copied into DynamicLibraries.");
    char parent[PATH_MAX], expected[PATH_MAX];
    if (!realpath(target.stringByDeletingLastPathComponent.fileSystemRepresentation, parent) || !realpath(root.fileSystemRepresentation, expected) || strcmp(parent, expected))
        MROFail(action, @"copy_parent_invalid", @"DynamicLibraries parent is not canonical.");
    struct stat st; if (lstat(target.fileSystemRepresentation, &st) == 0) MROFail(action, @"copy_target_exists", @"Refusing to overwrite an existing injection file.");
    if (errno != ENOENT) MROFail(action, @"copy_target_stat_failed", @"Cannot inspect the injection target.");
    return [name.pathExtension.lowercaseString isEqualToString:@"dylib"] ? 0755 : 0644;
}
static void MROFileAbort(NSDictionary *request) {
    NSString *action=@"file_abort", *mode=MRORequired(request,@"mode",action), *stageID=MRORequired(request,@"stage_id",action), *session=MRORequired(request,@"session_id",action);
    if (![mode isEqualToString:@"limited"] && ![mode isEqualToString:@"expert"]) MROFail(action,@"mode_invalid",@"File cleanup requires limited or expert mode.");
    if (!MROUUID(stageID)||!MinisSessionSystemAccessKey(session)) MROFail(action,@"request_invalid",@"File stage identity is invalid.");
    NSString *base=MROStateBase(action); for (NSString *suffix in @[@"part",@"bin",@"json"]) { NSString *path=MROFilePath(base,stageID,suffix,action); struct stat st; if(lstat(path.fileSystemRepresentation,&st)==0) { if(!S_ISREG(st.st_mode)||S_ISLNK(st.st_mode)||(st.st_mode&077)!=0) MROFail(action,@"file_stage_invalid",@"Staged file is unsafe."); if(unlink(path.fileSystemRepresentation)) MROFail(action,@"file_abort_failed",@"Cannot remove staged file."); } } MROFsyncDir([base stringByAppendingPathComponent:@"Files"],action); NSMutableDictionary *result=[MROIDs() mutableCopy]; [result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@YES,@"action":action,@"stage":@"aborted",@"session_id":session,@"stage_id":stageID}]; MROAudit(base,result,action); MROEmit(result,0);
}
static void MROFileStageChunk(NSDictionary *request) {
    NSString *action=@"file_stage_chunk", *mode=MRORequired(request,@"mode",action), *stageID=MRORequired(request,@"stage_id",action), *session=MRORequired(request,@"session_id",action), *target=MRORequired(request,@"target",action), *totalSHA=MRORequired(request,@"total_sha256",action);
    if (![mode isEqualToString:@"limited"] && ![mode isEqualToString:@"expert"]) MROFail(action,@"mode_invalid",@"File staging requires limited or expert mode.");
    if (!MROUUID(stageID)||!MinisSessionSystemAccessKey(session)||!MROSHA(totalSHA.lowercaseString)) MROFail(action,@"request_invalid",@"File stage identity is invalid.");
    mode_t fileMode=MROCopyTargetMode(target,action); (void)fileMode;
    NSNumber *offsetNumber=request[@"offset"], *totalNumber=request[@"total_bytes"]; if(![offsetNumber isKindOfClass:NSNumber.class]||![totalNumber isKindOfClass:NSNumber.class])MROFail(action,@"request_invalid",@"File chunk offset and total are required.");
    NSUInteger offset=offsetNumber.unsignedIntegerValue,total=totalNumber.unsignedIntegerValue; NSData *chunk=MROChunk(request,action); if(!total||total>MINIS_ROOT_FILE_LIMIT||offset>total||chunk.length>total-offset)MROFail(action,@"request_invalid",@"File chunk range is outside the limit.");
    NSString *base=MROStateBase(action), *part=MROFilePath(base,stageID,@"part",action), *metaPath=MROFilePath(base,stageID,@"json",action); struct stat st;
    if(offset==0){if(lstat(part.fileSystemRepresentation,&st)==0||lstat(metaPath.fileSystemRepresentation,&st)==0)MROFail(action,@"file_stage_exists",@"Stage ID already exists; refusing overwrite."); NSDictionary *meta=@{@"session_id":session,@"stage_id":stageID,@"target":target,@"total_bytes":@(total),@"sha256":totalSHA.lowercaseString}; NSData *json=[NSJSONSerialization dataWithJSONObject:meta options:0 error:NULL]; MROAtomic(json,metaPath,0600,action); int create=open(part.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);if(create<0)MROFail(action,@"file_stage_create_failed",@"Cannot create staged file.");close(create);}
    else { NSData *metaData=[NSData dataWithContentsOfFile:metaPath options:0 error:NULL]; NSDictionary *meta=metaData?[NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL]:nil; if(![meta isKindOfClass:NSDictionary.class]||![meta[@"session_id"] isEqual:session]||![meta[@"target"] isEqual:target]||![meta[@"total_bytes"] isEqual:totalNumber]||![meta[@"sha256"] isEqual:totalSHA.lowercaseString])MROFail(action,@"file_stage_identity_mismatch",@"File stage metadata does not match.");}
    int fd=open(part.fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);if(fd<0)MROFail(action,@"file_stage_open_failed",@"Cannot open staged file.");if(fstat(fd,&st)||!S_ISREG(st.st_mode)||(size_t)st.st_size!=offset){close(fd);MROFail(action,@"file_stage_offset_mismatch",@"File stage is not append-only.");}if(lseek(fd,(off_t)offset,SEEK_SET)<0){close(fd);MROFail(action,@"file_stage_seek_failed",@"Cannot seek staged file.");}const uint8_t *p=chunk.bytes;size_t left=chunk.length;while(left){ssize_t n=write(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);MROFail(action,@"file_stage_write_failed",@"Cannot append staged file.");}p+=n;left-=n;}if(fsync(fd)||close(fd))MROFail(action,@"file_stage_sync_failed",@"Cannot sync staged file.");NSUInteger received=offset+chunk.length;BOOL final=[request[@"final"] boolValue];if(final){if(received!=total)MROFail(action,@"file_stage_incomplete",@"Final chunk does not complete file.");NSData *all=[NSData dataWithContentsOfFile:part options:NSDataReadingMappedIfSafe error:NULL];if(!all||all.length!=total||![MROHexSHA(all) isEqualToString:totalSHA.lowercaseString])MROFail(action,@"file_stage_hash_failed",@"Staged file hash failed.");NSString *bin=MROFilePath(base,stageID,@"bin",action);if(rename(part.fileSystemRepresentation,bin.fileSystemRepresentation))MROFail(action,@"file_stage_finalize_failed",@"Cannot finalize staged file.");MROFsyncDir(bin.stringByDeletingLastPathComponent,action);NSMutableDictionary *result=[MROIDs() mutableCopy];[result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@YES,@"action":action,@"stage":@"staged",@"session_id":session,@"stage_id":stageID,@"target":target,@"bytes":@(total),@"sha256":totalSHA.lowercaseString}];MROAudit(base,result,action);MROEmit(result,0);}NSMutableDictionary *result=[MROIDs() mutableCopy];[result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@YES,@"action":action,@"stage":@"chunk",@"session_id":session,@"stage_id":stageID,@"target":target,@"bytes_received":@(received),@"total_bytes":@(total)}];MROEmit(result,0);
}
static void MROFilePublish(NSDictionary *request) {
    NSString *action=@"file_publish",*mode=MRORequired(request,@"mode",action),*stageID=MRORequired(request,@"stage_id",action),*session=MRORequired(request,@"session_id",action),*target=MRORequired(request,@"target",action),*expectedSHA=MRORequired(request,@"total_sha256",action);if(![mode isEqualToString:@"limited"]&&! [mode isEqualToString:@"expert"])MROFail(action,@"mode_invalid",@"File publish requires limited or expert mode.");if(!MROUUID(stageID)||!MinisSessionSystemAccessKey(session)||!MROSHA(expectedSHA.lowercaseString))MROFail(action,@"request_invalid",@"File publish identity is invalid.");mode_t fileMode=MROCopyTargetMode(target,action);NSString *base=MROStateBase(action),*bin=MROFilePath(base,stageID,@"bin",action),*metaPath=MROFilePath(base,stageID,@"json",action);NSData *metaData=[NSData dataWithContentsOfFile:metaPath options:0 error:NULL];NSDictionary *meta=metaData?[NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL]:nil; if(![meta isKindOfClass:NSDictionary.class]||![meta[@"session_id"] isEqual:session]||![meta[@"target"] isEqual:target]||![meta[@"sha256"] isEqual:expectedSHA.lowercaseString])MROFail(action,@"file_stage_identity_mismatch",@"File stage metadata does not match.");struct stat st;if(lstat(bin.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||S_ISLNK(st.st_mode)||(st.st_mode&077)!=0)MROFail(action,@"file_stage_missing",@"Final staged file is missing or unsafe.");NSData *data=[NSData dataWithContentsOfFile:bin options:NSDataReadingMappedIfSafe error:NULL];if(!data||![MROHexSHA(data) isEqualToString:expectedSHA.lowercaseString])MROFail(action,@"file_stage_changed",@"Staged file changed after transfer.");if(link(bin.fileSystemRepresentation,target.fileSystemRepresentation))MROFail(action,errno==EEXIST?@"copy_target_exists":@"copy_publish_failed",@"Cannot publish file without overwriting.");if(chmod(target.fileSystemRepresentation,fileMode)||fsync(open(target.stringByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC)))MROFail(action,@"copy_sync_failed",@"Published file could not be synced.");unlink(bin.fileSystemRepresentation);unlink(metaPath.fileSystemRepresentation);MROFsyncDir([base stringByAppendingPathComponent:@"Files"],action);NSMutableDictionary *result=[MROIDs() mutableCopy];[result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@YES,@"action":action,@"stage":@"published",@"session_id":session,@"stage_id":stageID,@"target":target,@"bytes":@(data.length),@"sha256":expectedSHA.lowercaseString}];MROAudit(base,result,action);MROEmit(result,0);
}
static void MROStageAbort(NSDictionary *request) {
    NSString *action=@"stage_abort",*mode=MRORequired(request,@"mode",action),*stageID=MRORequired(request,@"stage_id",action),*session=MRORequired(request,@"session_id",action);
    if (![mode isEqualToString:@"limited"] && ![mode isEqualToString:@"expert"]) MROFail(action,@"mode_invalid",@"Staging cleanup requires limited or expert mode.");
    if (!MROUUID(stageID)||!MinisSessionSystemAccessKey(session)) MROFail(action,@"request_invalid",@"Stage identity is invalid.");
    NSString *base=MROStateBase(action); for (NSString *suffix in @[@"part", @"deb"]) { NSString *path=MROStagePath(base,stageID,[suffix isEqualToString:@"deb"],action); struct stat st; if(lstat(path.fileSystemRepresentation,&st)==0) { if(!S_ISREG(st.st_mode)||S_ISLNK(st.st_mode)||(st.st_mode&077)!=0) MROFail(action,@"stage_invalid",@"Staged package is unsafe."); if(unlink(path.fileSystemRepresentation)) MROFail(action,@"stage_abort_failed",@"Cannot remove staged package."); } } MROFsyncDir([base stringByAppendingPathComponent:@"Packages"],action); NSMutableDictionary *result=[MROIDs() mutableCopy]; [result addEntriesFromDictionary:@{@"protocol":@3, @"ok":@YES, @"action":action, @"stage":@"aborted", @"session_id":session, @"stage_id":stageID}]; MROAudit(base,result,action); MROEmit(result,0);
}
static void MROStageChunk(NSDictionary *request) {
    NSString *action = @"stage_chunk"; NSString *mode = MRORequired(request, @"mode", action), *stageID = MRORequired(request, @"stage_id", action), *package = MRORequired(request, @"package", action), *session = MRORequired(request, @"session_id", action), *totalSHA = MRORequired(request, @"total_sha256", action);
    if (![mode isEqualToString:@"limited"] && ![mode isEqualToString:@"expert"]) MROFail(action, @"mode_invalid", @"Staging requires limited or expert mode.");
    if (!MROUUID(stageID) || !MRPackageID(package.UTF8String) || !MinisSessionSystemAccessKey(session) || !MROSHA(totalSHA.lowercaseString)) MROFail(action, @"request_invalid", @"Stage identity is invalid.");
    NSNumber *offsetNumber = request[@"offset"], *totalNumber = request[@"total_bytes"]; if (![offsetNumber isKindOfClass:NSNumber.class] || ![totalNumber isKindOfClass:NSNumber.class]) MROFail(action, @"request_invalid", @"Chunk offset and total are required.");
    NSUInteger offset = offsetNumber.unsignedIntegerValue, total = totalNumber.unsignedIntegerValue; NSData *chunk = MROChunk(request, action);
    if (total == 0 || total > MINIS_ROOT_FILE_LIMIT || offset > total || chunk.length > total - offset) MROFail(action, @"request_invalid", @"Chunk range is outside the package bound.");
    BOOL final = [request[@"final"] boolValue]; NSString *base = MROStateBase(action); NSString *part = MROStagePath(base, stageID, NO, action); struct stat st = {0};
    if (offset == 0) { if (lstat(part.fileSystemRepresentation, &st) == 0) MROFail(action, @"stage_exists", @"Stage ID already exists; refusing overwrite."); int fd = open(part.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600); if (fd < 0) MROFail(action, @"stage_create_failed", @"Cannot create staging part."); close(fd); }
    int fd = open(part.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC); if (fd < 0) MROFail(action, @"stage_open_failed", @"Cannot open staging part.");
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || (size_t)st.st_size != offset) { close(fd); MROFail(action, @"stage_offset_mismatch", @"Stage offset is not append-only."); }
    const uint8_t *p = chunk.bytes; size_t left = chunk.length; if (lseek(fd, (off_t)offset, SEEK_SET) < 0) { close(fd); MROFail(action, @"stage_seek_failed", @"Cannot seek staging part."); }
    while (left) { ssize_t n = write(fd, p, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) { close(fd); MROFail(action, @"stage_write_failed", @"Cannot append staging part."); } p += n; left -= (size_t)n; }
    if (fsync(fd) || close(fd)) MROFail(action, @"stage_sync_failed", @"Cannot sync staging part.");
    NSUInteger received = offset + chunk.length;
    if (final) {
        if (received != total) MROFail(action, @"stage_incomplete", @"Final chunk does not complete the package.");
        NSData *all = [NSData dataWithContentsOfFile:part options:NSDataReadingMappedIfSafe error:NULL]; MinisPluginInfo info = {0};
        if (!all || all.length != total || !MinisInspectPlugin(all.bytes, all.length, &info) || strcmp(info.package, package.UTF8String) || ![MROHexSHA(all) isEqualToString:totalSHA.lowercaseString]) MROFail(action, @"deb_rejected", @"Staged DEB failed archive, package or SHA validation.");
        NSString *finalPath = MROStagePath(base, stageID, YES, action); if (rename(part.fileSystemRepresentation, finalPath.fileSystemRepresentation)) MROFail(action, @"stage_finalize_failed", @"Cannot finalize staged package."); MROFsyncDir(finalPath.stringByDeletingLastPathComponent, action);
        NSMutableDictionary *result = [MROIDs() mutableCopy]; [result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@YES,@"action":action,@"stage":@"staged",@"session_id":session,@"stage_id":stageID,@"package":package,@"version":[NSString stringWithUTF8String:info.version] ?: @"",@"staged_path":finalPath,@"bytes":@(total),@"sha256":totalSHA.lowercaseString}]; MROAudit(base,result,action); MROEmit(result,0);
    }
    NSMutableDictionary *result = [MROIDs() mutableCopy]; [result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@YES,@"action":action,@"stage":@"chunk",@"session_id":session,@"stage_id":stageID,@"package":package,@"bytes_received":@(received),@"total_bytes":@(total)}]; MROEmit(result,0);
}
static NSDictionary *MRORunDpkg(NSString *path, NSString *package, NSString *mode) {
    char *argv[] = {(char*)"/var/jb/usr/bin/dpkg", (char*)"--status-fd", (char*)"1", (char*)"-i", (char*)path.fileSystemRepresentation, NULL};
    MinisRootChildControl c; c.lock=(pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER; c.pid=0;c.revoked=0; MROSetActiveChild(&c); MinisRootChildResult r=MRRunChild("/var/jb/usr/bin/dpkg",argv,180000,&c); MROClearActiveChild(&c);
    NSString *out=r.out ? ([NSString stringWithUTF8String:r.out] ?: @"") : @""; NSString *err=r.err ? ([NSString stringWithUTF8String:r.err] ?: @"") : @"";
    NSDictionary *d=@{@"package":package,@"mode":mode,@"exit_code":@(r.exitCode),@"signal":@(r.signal),@"timed_out":@(r.timedOut),@"output_truncated":@(r.truncated),@"stdout":out,@"stderr":err}; MRChildFree(&r); return d;
}
static void MROInstall(NSDictionary *request) {
    NSString *action=@"plugin_install",*mode=MRORequired(request,@"mode",action),*stageID=MRORequired(request,@"stage_id",action),*package=MRORequired(request,@"package",action),*session=MRORequired(request,@"session_id",action),*expectedSHA=MRORequired(request,@"total_sha256",action);
    if (![mode isEqualToString:@"limited"] && ![mode isEqualToString:@"expert"]) MROFail(action,@"mode_invalid",@"Plugin installation requires limited or expert mode.");
    if (!MROUUID(stageID)||!MRPackageID(package.UTF8String)||!MinisSessionSystemAccessKey(session)||!MROSHA(expectedSHA.lowercaseString)) MROFail(action,@"request_invalid",@"Installation identity is invalid.");
    if (!MRManagedLabel(package.UTF8String,[mode isEqualToString:@"expert"])) MROFail(action,@"package_not_allowed",@"Limited mode allows only managed package identifiers.");
    NSString *base=MROStateBase(action),*path=MROStagePath(base,stageID,YES,action); struct stat st;
    if (lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||S_ISLNK(st.st_mode)||(st.st_mode&077)!=0) MROFail(action,@"stage_missing",@"Final staged package is missing or unsafe.");
    NSData *staged=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL]; MinisPluginInfo info={0};
    if (!staged || !MinisInspectPlugin(staged.bytes, staged.length, &info) || strcmp(info.package, package.UTF8String) || ![MROHexSHA(staged) isEqualToString:expectedSHA.lowercaseString]) MROFail(action,@"stage_changed",@"Staged package changed after transfer; refusing install.");
    NSDictionary *dpkg=MRORunDpkg(path,package,mode); BOOL ok=[dpkg[@"exit_code"] intValue]==0&&[dpkg[@"signal"] intValue]==0&&! [dpkg[@"timed_out"] boolValue];
    NSMutableDictionary *result=[MROIDs() mutableCopy]; [result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@(ok),@"action":action,@"stage":@"dpkg",@"session_id":session,@"stage_id":stageID,@"package":package,@"rollback": @"remove package with system_package_remove; dpkg state is not blindly restored"}]; [result addEntriesFromDictionary:dpkg]; MROAudit(base,result,action); if(ok){unlink(path.fileSystemRepresentation);MROFsyncDir(path.stringByDeletingLastPathComponent,action);} MROEmit(result,ok?0:1);
}
static void MRORootCommand(NSDictionary *request) {
    NSString *action=@"root_command",*mode=MRORequired(request,@"mode",action),*operation=MRORequired(request,@"operation",action),*package=request[@"package"];
    if(![mode isEqualToString:@"limited"]&&![mode isEqualToString:@"expert"])MROFail(action,@"mode_invalid",@"Root operations require limited or expert mode.");
    char *argv[5]={0}; const char *program=NULL; BOOL expert=[mode isEqualToString:@"expert"];
    if([operation isEqualToString:@"dpkg_status"] && package && MRManagedLabel(package.UTF8String,expert)){program="/var/jb/usr/bin/dpkg";argv[0]=(char*)program;argv[1]=(char*)"--status";argv[2]=(char*)package.UTF8String;}
    else if([operation isEqualToString:@"springboard_reload"] && expert){program="/var/jb/usr/bin/sbreload";argv[0]=(char*)program;}
    else MROFail(action,@"operation_denied",@"Only fixed dpkg_status and expert springboard_reload operations are allowed; no shell.");
    MinisRootChildControl c;c.lock=(pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;c.pid=0;c.revoked=0;MROSetActiveChild(&c);MinisRootChildResult r=MRRunChild(program,argv,30000,&c);MROClearActiveChild(&c);
    NSString *out=r.out?([NSString stringWithUTF8String:r.out]?:@""): @"";NSString *err=r.err?([NSString stringWithUTF8String:r.err]?:@""): @"";BOOL ok=r.exitCode==0&&r.signal==0&&!r.timedOut;
    NSMutableDictionary *result=[MROIDs() mutableCopy];[result addEntriesFromDictionary:@{@"protocol":@3,@"ok":@(ok),@"action":action,@"stage":@"fixed_argv",@"operation":operation,@"exit_code":@(r.exitCode),@"signal":@(r.signal),@"timed_out":@(r.timedOut),@"output_truncated":@(r.truncated),@"stdout":out,@"stderr":err}];MRChildFree(&r);MROEmit(result,ok?0:1);
}
#endif
