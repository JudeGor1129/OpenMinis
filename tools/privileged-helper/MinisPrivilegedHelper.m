#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include "HelperLease.h"

#define READ_LIMIT (256u * 1024u)
#define CONTENT_LIMIT (1024u * 1024u)
#define BACKUP_LIMIT (2u * 1024u * 1024u)
#define PROTOCOL_VERSION 2

static NSString *ExecutionStage = @"startup";
static NSDictionary *IdentityFields(void) {
    return @{@"uid": @(getuid()), @"euid": @(geteuid()),
             @"gid": @(getgid()), @"egid": @(getegid()),
             @"root_verified": @(getuid() == 0 && geteuid() == 0 && getgid() == 0 && getegid() == 0)};
}

static void Emit(NSDictionary *object, int code) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (!data) _exit(74);
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining) {
        ssize_t count = write(STDOUT_FILENO, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) _exit(74);
        bytes += count;
        remaining -= (size_t)count;
    }
    (void)write(STDOUT_FILENO, "\n", 1);
    _exit(code);
}

static void Fail(NSString *action, NSString *code, NSString *message) {
    NSMutableDictionary *result = [IdentityFields() mutableCopy];
    [result addEntriesFromDictionary:@{@"protocol": @PROTOCOL_VERSION, @"ok": @NO,
           @"action": action ?: @"unknown", @"code": code ?: @"error",
           @"stage": ExecutionStage ?: @"unknown",
           @"error": message ?: @"Request failed."}];
    Emit(result, 1);
}

static NSString *StateBase(NSString *action) {
    // Audit/backup state lives in one fixed directory under the active
    // rootless bootstrap. The helper resolves it itself instead of trusting a
    // path from the GUI, and refuses symlinked components or loose modes.
    char bootstrap[PATH_MAX];
    if (!realpath("/var/jb", bootstrap))
        Fail(action, @"state_directory_invalid", @"Active rootless bootstrap cannot be resolved.");
    NSString *expected = [[NSString stringWithUTF8String:bootstrap]
        stringByAppendingPathComponent:@"var/tmp/MinisSystemAccess"];
    char resolved[PATH_MAX];
    if (!realpath(expected.fileSystemRepresentation, resolved) ||
        ![[NSString stringWithUTF8String:resolved] isEqualToString:expected])
        Fail(action, @"state_directory_invalid", @"System-access state directory is missing or not canonical.");
    struct stat st;
    if (lstat(expected.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) ||
        (st.st_uid != 0 && st.st_uid != 501) || (st.st_mode & 077) != 0)
        Fail(action, @"state_directory_invalid", @"System-access state directory owner or permissions are unsafe.");
    return expected;
}

static NSString *HexSHA(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    static const char hex[] = "0123456789abcdef";
    char out[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        out[i * 2] = hex[digest[i] >> 4]; out[i * 2 + 1] = hex[digest[i] & 15];
    }
    out[sizeof(out) - 1] = 0;
    return [NSString stringWithUTF8String:out];
}

static BOOL IsSHA(NSString *value) {
    if (value.length != 64) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL Under(NSString *path, NSString *prefix) {
    return [path isEqualToString:prefix] || [path hasPrefix:[prefix stringByAppendingString:@"/"]];
}

static NSArray<NSString *> *PermanentDenies(void) {
    return @[@"/var/Keychains", @"/private/var/Keychains",
             @"/var/mobile/Library/Keychains", @"/private/var/mobile/Library/Keychains",
             @"/var/db", @"/private/var/db", @"/dev", @"/private/dev",
             @"/var/jb/basebin", @"/var/jb/var/lib/dyld", @"/var/jb/System/Library/Caches/com.apple.dyld"];
}

static NSDictionary<NSString *, NSString *> *AllowedRoots(NSString *mode, BOOL writing) {
    if (!writing) {
        return @{
            @"/var/log": @"diagnostic-read",
            @"/var/mobile/Library/Logs": @"diagnostic-read",
            @"/var/jb/var/log": @"jailbreak-read",
            @"/var/jb/var/lib/dpkg": @"package-metadata-read",
            @"/var/jb/Library/PreferenceLoader": @"preferences-read",
            @"/var/jb/Library/PreferenceBundles": @"preferences-read",
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries": @"injection-read",
            @"/var/jb/etc/apt": @"package-config-read"
        };
    }
    NSMutableDictionary *roots = [@{
        @"/var/jb/var/tmp": @"limited",
        @"/var/jb/Library/PreferenceLoader": @"limited",
        @"/var/jb/Library/PreferenceBundles": @"limited",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries": @"limited",
        @"/var/jb/var/mobile/Library/Preferences": @"limited"
    } mutableCopy];
    if ([mode isEqualToString:@"expert"]) {
        roots[@"/var/jb/etc"] = @"expert";
        roots[@"/var/jb/usr/local"] = @"expert";
        roots[@"/var/jb/Library/LaunchDaemons"] = @"expert";
    }
    return roots;
}

typedef struct { __unsafe_unretained NSString *literal; __unsafe_unretained NSString *real; __unsafe_unretained NSString *tier; } SafePath;

static SafePath ValidateTarget(NSString *raw, BOOL mayNotExist, NSString *action, NSString *mode, BOOL writing) {
    if (![raw isKindOfClass:NSString.class] || !raw.isAbsolutePath || raw.length > PATH_MAX - 1 ||
        [raw containsString:@"//"] || [raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        Fail(action, @"path_invalid", @"Path must be a canonical absolute path.");
    for (NSString *part in raw.pathComponents)
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) Fail(action, @"path_invalid", @"Dot path components are forbidden.");
    if (![raw.stringByStandardizingPath isEqualToString:raw])
        Fail(action, @"path_invalid", @"Path must already be standardized.");
    for (NSString *deny in PermanentDenies()) if (Under(raw, deny))
        Fail(action, @"path_permanently_denied", @"Credential, launchd, trust/basebin paths are permanently denied.");
    if (Under(raw, @"/System") || Under(raw, @"/private/preboot") || Under(raw, @"/Applications") ||
        Under(raw, @"/bin") || Under(raw, @"/sbin") || Under(raw, @"/usr/bin") || Under(raw, @"/usr/sbin"))
        Fail(action, @"raw_os_path_denied", @"Raw OS, application, executable, and preboot paths are never writable.");
    NSDictionary<NSString *, NSString *> *roots = AllowedRoots(mode, writing);
    NSString *matchedRoot = nil, *tier = nil;
    for (NSString *root in roots) if (Under(raw, root) && (!matchedRoot || root.length > matchedRoot.length)) {
        matchedRoot = root; tier = roots[root];
    }
    if (!matchedRoot) Fail(action, @"path_outside_tiers", @"Path is outside the reviewed read/write tiers.");
    if (writing) {
        NSString *ext = raw.pathExtension.lowercaseString;
        NSSet *textExtensions = [NSSet setWithArray:@[@"plist", @"strings", @"json", @"txt", @"conf", @"cfg", @"list", @"sources", @"sh"]];
        if ([matchedRoot containsString:@"MobileSubstrate/DynamicLibraries"] && ![ext isEqualToString:@"plist"])
            Fail(action, @"extension_denied", @"DynamicLibraries writes are limited to companion plist files; dylib replacement is not supported.");
        if ([matchedRoot containsString:@"LaunchDaemons"] && ![ext isEqualToString:@"plist"])
            Fail(action, @"extension_denied", @"LaunchDaemons writes are limited to plist files.");
        if (ext.length && ![textExtensions containsObject:ext])
            Fail(action, @"extension_denied", @"Only reviewed text/config file extensions are writable.");
    }
    struct stat lst;
    BOOL exists = lstat(raw.fileSystemRepresentation, &lst) == 0;
    if (exists && S_ISLNK(lst.st_mode)) Fail(action, @"symlink_denied", @"Target symlinks are forbidden.");
    if (exists && !S_ISREG(lst.st_mode)) Fail(action, @"not_regular", @"Target must be a regular file.");
    if (!exists && (!mayNotExist || errno != ENOENT)) Fail(action, @"target_missing", @"Target does not exist.");
    NSString *probe = exists ? raw : raw.stringByDeletingLastPathComponent;
    char resolved[PATH_MAX];
    if (!realpath(probe.fileSystemRepresentation, resolved)) Fail(action, @"realpath_failed", @"Target parent cannot be resolved.");
    NSString *real = [NSString stringWithUTF8String:resolved];
    if (!exists) real = [real stringByAppendingPathComponent:raw.lastPathComponent];
    char resolvedRoot[PATH_MAX];
    if (!realpath(matchedRoot.fileSystemRepresentation, resolvedRoot))
        Fail(action, @"tier_unavailable", @"The selected path tier is not installed.");
    NSString *realRoot = [NSString stringWithUTF8String:resolvedRoot];
    if (!Under(real, realRoot)) Fail(action, @"realpath_outside_tier", @"Resolved path escapes its literal tier.");
    for (NSString *deny in PermanentDenies()) if (Under(real, deny))
        Fail(action, @"path_permanently_denied", @"Resolved path enters a permanent deny tier.");
    return (SafePath){ raw, real, tier };
}

static NSData *ReadRegular(NSString *path, NSUInteger limit, struct stat *snapshot, NSString *action) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) Fail(action, @"open_failed", [NSString stringWithFormat:@"Cannot open target: %s", strerror(errno)]);
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || (uint64_t)st.st_size > limit) {
        close(fd); Fail(action, @"size_or_type_denied", [NSString stringWithFormat:@"Regular file exceeds %lu-byte bound.", (unsigned long)limit]);
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *p = data.mutableBytes; size_t left = data.length;
    while (left) {
        ssize_t n = read(fd, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); Fail(action, @"read_failed", @"Target changed or could not be read completely."); }
        p += n; left -= (size_t)n;
    }
    close(fd); if (snapshot) *snapshot = st; return data;
}

static void MakeStateDirectories(NSString *base, NSString *action) {
    struct stat baseStat;
    if (lstat(base.fileSystemRepresentation, &baseStat) || !S_ISDIR(baseStat.st_mode) || S_ISLNK(baseStat.st_mode))
        Fail(action, @"state_directory_invalid", @"System-access state root is unsafe.");
    for (NSString *name in @[@"Backups", @"Audit"]) {
        NSString *path = [base stringByAppendingPathComponent:name];
        if (mkdir(path.fileSystemRepresentation, 0700) != 0 && errno != EEXIST)
            Fail(action, @"state_directory_failed", @"Cannot create helper state directory.");
        if (getuid() == 0) (void)chown(path.fileSystemRepresentation, baseStat.st_uid, baseStat.st_gid);
        (void)chmod(path.fileSystemRepresentation, 0700);
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) ||
            st.st_uid != baseStat.st_uid || st.st_gid != baseStat.st_gid)
            Fail(action, @"state_directory_invalid", @"Helper state directory owner is unsafe.");
    }
}

static void WriteAllOrFail(int fd, NSData *data, NSString *action) {
    const uint8_t *p = data.bytes; size_t left = data.length;
    while (left) {
        ssize_t n = write(fd, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) Fail(action, @"write_failed", [NSString stringWithFormat:@"Write failed: %s", strerror(errno)]);
        p += n; left -= (size_t)n;
    }
}

static void SyncDirectory(NSString *directory, NSString *action) {
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0 || fsync(fd) != 0) { if (fd >= 0) close(fd); Fail(action, @"directory_sync_failed", @"Parent directory fsync failed."); }
    close(fd);
}

static void AtomicData(NSData *data, NSString *path, mode_t mode, NSString *action) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSString *temp = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".minis-%@.tmp", NSUUID.UUID.UUIDString]];
    int fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode & 0777);
    if (fd < 0) Fail(action, @"temp_create_failed", @"Cannot create atomic temporary file.");
    WriteAllOrFail(fd, data, action);
    if (fsync(fd) != 0) { close(fd); unlink(temp.fileSystemRepresentation); Fail(action, @"file_sync_failed", @"Temporary file fsync failed."); }
    if (close(fd) != 0) { unlink(temp.fileSystemRepresentation); Fail(action, @"file_close_failed", @"Temporary file close failed."); }
    if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        unlink(temp.fileSystemRepresentation); Fail(action, @"rename_failed", [NSString stringWithFormat:@"Atomic rename failed: %s", strerror(errno)]);
    }
    SyncDirectory(directory, action);
}

static BOOL SameSnapshot(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
           a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec;
}

static void AppendAudit(NSString *base, NSDictionary *metadata, NSString *action) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:NULL];
    NSMutableData *line = [json mutableCopy]; [line appendBytes:"\n" length:1];
    NSString *path = [[base stringByAppendingPathComponent:@"Audit"] stringByAppendingPathComponent:@"system-access.jsonl"];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) Fail(action, @"audit_open_failed", @"Cannot open durable audit log.");
    struct stat baseStat;
    if (lstat(base.fileSystemRepresentation, &baseStat) == 0 && getuid() == 0)
        (void)fchown(fd, baseStat.st_uid, baseStat.st_gid);
    (void)fchmod(fd, 0600);
    WriteAllOrFail(fd, line, action);
    if (fsync(fd) != 0 || close(fd) != 0) Fail(action, @"audit_sync_failed", @"Durable audit sync failed.");
    SyncDirectory(path.stringByDeletingLastPathComponent, action);
}

static NSDictionary *CommonResult(NSString *action) {
    NSMutableDictionary *result = [IdentityFields() mutableCopy];
    [result addEntriesFromDictionary:@{@"protocol": @PROTOCOL_VERSION, @"ok": @YES,
        @"action": action, @"stage": ExecutionStage ?: @"unknown"}];
    return result;
}

static NSDictionary *MutableCommon(NSString *action) { return [CommonResult(action) mutableCopy]; }

static NSString *RequiredString(NSDictionary *request, NSString *key, NSString *action) {
    id value = request[key];
    if (![value isKindOfClass:NSString.class] || ![(NSString *)value length])
        Fail(action, @"invalid_request", [NSString stringWithFormat:@"Missing string field %@.", key]);
    return value;
}

static NSString *RequiredMode(NSDictionary *request, NSString *action, BOOL writing) {
    NSString *mode = RequiredString(request, @"mode", action);
    if (![@[@"readonly", @"limited", @"expert"] containsObject:mode])
        Fail(action, @"mode_invalid", @"mode must be readonly, limited, or expert.");
    if (writing && [mode isEqualToString:@"readonly"])
        Fail(action, @"write_mode_required", @"Write and rollback require limited or expert mode.");
    return mode;
}

static void DoIdentity(NSString *action) {
    NSMutableDictionary *result = [MutableCommon(action) mutableCopy];
    result[@"helper_version"] = @"2.1";
    result[@"capabilities"] = @[@"bounded_utf8_read", @"atomic_utf8_write", @"rollback"];
    BOOL root = [result[@"root_verified"] boolValue];
    result[@"ok"] = @(root);
    if (!root) {
        result[@"code"] = @"root_not_verified";
        result[@"error"] = @"Helper launched but did not receive real uid/euid/gid/egid 0.";
    }
    Emit(result, root ? 0 : 77);
}

static void DoRead(NSDictionary *request, NSString *action) {
    NSString *mode = RequiredMode(request, action, NO);
    SafePath safe = ValidateTarget(RequiredString(request, @"path", action), NO, action, mode, NO);
    NSUInteger asked = [request[@"max_bytes"] isKindOfClass:NSNumber.class] ? [request[@"max_bytes"] unsignedIntegerValue] : 131072;
    if (asked == 0 || asked > READ_LIMIT) Fail(action, @"read_bound_invalid", @"max_bytes must be 1...262144.");
    NSData *data = ReadRegular(safe.literal, asked, NULL, action);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) Fail(action, @"not_utf8", @"Target is not valid UTF-8.");
    NSMutableDictionary *result = [MutableCommon(action) mutableCopy];
    [result addEntriesFromDictionary:@{@"path": safe.literal, @"real_path": safe.real, @"tier": safe.tier,
        @"bytes": @(data.length), @"sha256": HexSHA(data), @"content": text}];
    Emit(result, 0);
}

static void StoreBackup(NSString *base, NSString *auditID, NSData *oldData, NSDictionary *meta, NSString *action) {
    MakeStateDirectories(base, action);
    NSString *dir = [base stringByAppendingPathComponent:@"Backups"];
    if (oldData) AtomicData(oldData, [dir stringByAppendingPathComponent:[auditID stringByAppendingString:@".data"]], 0600, action);
    NSData *json = [NSJSONSerialization dataWithJSONObject:meta options:0 error:NULL];
    AtomicData(json, [dir stringByAppendingPathComponent:[auditID stringByAppendingString:@".json"]], 0600, action);
}

static NSDictionary *LoadBackup(NSString *base, NSString *auditID, NSString *action) {
    if (![[NSUUID alloc] initWithUUIDString:auditID]) Fail(action, @"invalid_audit_id", @"audit_id must be a UUID.");
    NSString *path = [[[base stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:auditID] stringByAppendingString:@".json"];
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if (!data || data.length > 65536) Fail(action, @"backup_missing", @"Rollback metadata is missing.");
    NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![meta isKindOfClass:NSDictionary.class] || ![meta[@"audit_id"] isEqual:auditID])
        Fail(action, @"backup_invalid", @"Rollback metadata is invalid.");
    return meta;
}

static void DoWrite(NSDictionary *request, NSString *base, NSString *action) {
    NSString *mode = RequiredMode(request, action, YES);
    NSString *path = RequiredString(request, @"path", action);
    NSString *content = RequiredString(request, @"content", action);
    NSString *expected = RequiredString(request, @"expected_sha256", action).lowercaseString;
    NSString *auditID = RequiredString(request, @"audit_id", action);
    if (![[NSUUID alloc] initWithUUIDString:auditID]) Fail(action, @"invalid_audit_id", @"audit_id must be a UUID.");
    if (![expected isEqualToString:@"missing"] && !IsSHA(expected)) Fail(action, @"expected_sha_invalid", @"expected_sha256 must be lowercase SHA-256 or missing.");
    NSData *newData = [content dataUsingEncoding:NSUTF8StringEncoding];
    if (!newData || newData.length > CONTENT_LIMIT) Fail(action, @"content_too_large", @"UTF-8 content exceeds 1 MiB.");
    SafePath safe = ValidateTarget(path, YES, action, mode, YES);
    struct stat originalStat = {0};
    BOOL existed = lstat(path.fileSystemRepresentation, &originalStat) == 0;
    NSData *oldData = nil; NSString *beforeSHA = nil;
    if (existed) {
        oldData = ReadRegular(path, BACKUP_LIMIT, &originalStat, action); beforeSHA = HexSHA(oldData);
        if (![expected isEqualToString:beforeSHA]) Fail(action, @"expected_sha_mismatch", @"Target changed since it was read; no write occurred.");
    } else if (![expected isEqualToString:@"missing"]) {
        Fail(action, @"expected_sha_mismatch", @"Target is missing but expected_sha256 did not say missing.");
    }
    NSString *afterSHA = HexSHA(newData);
    NSDictionary *backup = @{@"state_version": @1, @"audit_id": auditID, @"path": safe.literal,
        @"real_path": safe.real, @"tier": safe.tier, @"original_exists": @(existed),
        @"before_sha256": beforeSHA ?: (id)NSNull.null, @"after_sha256": afterSHA,
        @"before_mode": @(existed ? (originalStat.st_mode & 0777) : 0),
        @"created_at": @([[NSDate date] timeIntervalSince1970])};
    StoreBackup(base, auditID, oldData, backup, action);
    // Re-check immediately before rename. Both content and inode/timestamp snapshot
    // must still match the caller's expected state.
    if (existed) {
        struct stat currentStat; NSData *current = ReadRegular(path, BACKUP_LIMIT, &currentStat, action);
        if (!SameSnapshot(originalStat, currentStat) || ![HexSHA(current) isEqualToString:expected])
            Fail(action, @"expected_sha_race", @"Target raced after backup; no write occurred.");
    } else {
        struct stat check; if (lstat(path.fileSystemRepresentation, &check) == 0 || errno != ENOENT)
            Fail(action, @"expected_sha_race", @"Target appeared before atomic rename; no write occurred.");
    }
    AtomicData(newData, path, existed ? (originalStat.st_mode & 0777) : 0644, action);
    NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:@{
        @"audit_id": auditID, @"action": action, @"path": safe.literal, @"real_path": safe.real,
        @"tier": safe.tier, @"before_sha256": beforeSHA ?: (id)NSNull.null, @"after_sha256": afterSHA,
        @"bytes_before": @(oldData.length), @"bytes_after": @(newData.length),
        @"backup_available": @YES, @"at": @([[NSDate date] timeIntervalSince1970]),
        @"uid": @(getuid()), @"euid": @(geteuid())}];
    AppendAudit(base, metadata, action);
    NSMutableDictionary *result = [MutableCommon(action) mutableCopy]; [result addEntriesFromDictionary:metadata];
    Emit(result, 0);
}

static void DoRollback(NSDictionary *request, NSString *base, NSString *action) {
    NSString *mode = RequiredMode(request, action, YES);
    NSString *sourceID = RequiredString(request, @"rollback_audit_id", action);
    NSString *newAuditID = RequiredString(request, @"audit_id", action);
    if (![[NSUUID alloc] initWithUUIDString:newAuditID]) Fail(action, @"invalid_audit_id", @"audit_id must be a UUID.");
    NSDictionary *backup = LoadBackup(base, sourceID, action);
    NSString *path = RequiredString(backup, @"path", action);
    NSString *afterSHA = RequiredString(backup, @"after_sha256", action);
    SafePath safe = ValidateTarget(path, NO, action, mode, YES);
    struct stat currentStat; NSData *current = ReadRegular(path, BACKUP_LIMIT, &currentStat, action);
    if (![HexSHA(current) isEqualToString:afterSHA])
        Fail(action, @"rollback_race", @"Current file no longer matches the audited write; rollback refused.");
    BOOL originalExists = [backup[@"original_exists"] boolValue];
    NSString *restoredSHA = nil; NSUInteger restoredBytes = 0;
    if (originalExists) {
        NSString *dataPath = [[[[base stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:sourceID] stringByAppendingString:@".data"] copy];
        NSData *old = [NSData dataWithContentsOfFile:dataPath options:NSDataReadingMappedIfSafe error:NULL];
        NSString *expectedBefore = [backup[@"before_sha256"] isKindOfClass:NSString.class] ? backup[@"before_sha256"] : nil;
        if (!old || old.length > BACKUP_LIMIT || !expectedBefore || ![HexSHA(old) isEqualToString:expectedBefore])
            Fail(action, @"backup_corrupt", @"Rollback backup content failed integrity validation.");
        // One last snapshot check closes the normal read/confirm/write race.
        struct stat latest; NSData *latestData = ReadRegular(path, BACKUP_LIMIT, &latest, action);
        if (!SameSnapshot(currentStat, latest) || ![HexSHA(latestData) isEqualToString:afterSHA])
            Fail(action, @"rollback_race", @"Current file changed before rollback rename.");
        mode_t mode = [backup[@"before_mode"] unsignedShortValue] & 0777;
        AtomicData(old, path, mode ?: 0644, action); restoredSHA = HexSHA(old); restoredBytes = old.length;
    } else {
        struct stat latest; NSData *latestData = ReadRegular(path, BACKUP_LIMIT, &latest, action);
        if (!SameSnapshot(currentStat, latest) || ![HexSHA(latestData) isEqualToString:afterSHA])
            Fail(action, @"rollback_race", @"Current file changed before creation rollback.");
        if (unlink(path.fileSystemRepresentation) != 0) Fail(action, @"rollback_unlink_failed", @"Cannot remove the file created by the audited write.");
        SyncDirectory(path.stringByDeletingLastPathComponent, action);
    }
    NSDictionary *metadata = @{@"audit_id": newAuditID, @"action": action, @"rollback_of": sourceID,
        @"path": safe.literal, @"real_path": safe.real, @"tier": safe.tier,
        @"before_sha256": afterSHA, @"after_sha256": restoredSHA ?: (id)NSNull.null,
        @"bytes_before": @(current.length), @"bytes_after": @(restoredBytes), @"backup_available": @NO,
        @"at": @([[NSDate date] timeIntervalSince1970]), @"uid": @(getuid()), @"euid": @(geteuid())};
    MakeStateDirectories(base, action); AppendAudit(base, metadata, action);
    NSMutableDictionary *result = [MutableCommon(action) mutableCopy]; [result addEntriesFromDictionary:metadata];
    Emit(result, 0);
}

static void *LeaseMonitor(void *unused) { (void)unused; MinisHelperWaitForRevocation(STDIN_FILENO); return NULL; }

static NSData *ConsumeFramedRequest(NSString *action) {
    unsigned char *bytes = NULL; size_t size = 0;
    int error = MinisHelperReadRequestFrame(MINIS_HELPER_REQUEST_FD, &bytes, &size);
    if (error != 0) {
        Fail(action, error == EOVERFLOW ? @"request_too_large" : @"request_pipe_failed",
             [NSString stringWithFormat:@"Request pipe failed: %s", strerror(error)]);
    }
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
    NSError *parseError = nil;
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (![object isKindOfClass:NSDictionary.class]) Fail(action, @"invalid_json", @"Request frame is not a JSON object.");
    return data;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // argv carries only the allowlisted verb; the request body arrives on FD 3.
        if (argc != 2 || !argv[1]) return 64;
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        NSSet *allowed = [NSSet setWithArray:@[@"identity", @"read", @"write", @"rollback"]];
        if (![allowed containsObject:action]) Fail(action, @"action_denied", @"Action is not allowlisted.");
        if (!MinisHelperAwaitLaunchPermit(STDIN_FILENO)) return 125;
        alarm(20);
        pthread_t monitor;
        if (pthread_create(&monitor, NULL, LeaseMonitor, NULL) != 0) Fail(action, @"lease_failed", @"Cannot monitor parent lease.");
        pthread_detach(monitor);
        // Identity is a read-only process probe. It must not depend on request
        // path/owner/JSON checks, otherwise a staging error masquerades as a
        // persona failure. File verbs still require every request check below.
        ExecutionStage = @"identity";
        if ([action isEqualToString:@"identity"]) DoIdentity(action);
        ExecutionStage = @"request_validation";
        NSData *body = ConsumeFramedRequest(action);
        NSError *error = nil;
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:body options:0 error:&error];
        if (![request isKindOfClass:NSDictionary.class]) Fail(action, @"invalid_json", @"Request is not a JSON object.");
        if (![request[@"protocol"] isEqual:@PROTOCOL_VERSION] || ![request[@"action"] isEqual:action])
            Fail(action, @"protocol_mismatch", @"Request protocol/action mismatch.");
        ExecutionStage = @"root_validation";
        if (getuid() != 0 || geteuid() != 0 || getgid() != 0 || getegid() != 0)
            Fail(action, @"root_not_verified", @"Helper did not receive real root identity.");
        ExecutionStage = action;
        if ([action isEqualToString:@"read"]) DoRead(request, action);
        if ([action isEqualToString:@"write"]) DoWrite(request, StateBase(action), action);
        if ([action isEqualToString:@"rollback"]) DoRollback(request, StateBase(action), action);
        Fail(action, @"action_denied", @"Action is not implemented.");
    }
}
