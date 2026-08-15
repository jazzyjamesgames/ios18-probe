// Private, undocumented framework -- the biggest stub so far (66 symbols),
// full list known from re-running the existing symbol-recon step, same as
// CoreSimDeviceIO. Several distinct symbol families, each treated
// differently:
//
// 1. Three Objective-C classes whose mangled names
//    (_OBJC_CLASS_$__TtC22CoreSimulatorUtilities...) are the legacy Swift
//    ObjC-interop encoding for a class named X in a module literally named
//    "CoreSimulatorUtilities" (22 chars, matches the length prefix). Since
//    ObjC class symbols are just "_OBJC_CLASS_$_" + the literal class name
//    string, declaring an ObjC class whose *name* is the exact mangled
//    string (leading underscore and all) reproduces the same exported
//    symbol without needing real Swift metadata layout. Empty bodies, same
//    as SimDeviceIOPort/SimMachPort before -- fine unless CoreSimulator
//    actually message-sends real Swift-only behavor into them, which would
//    crash, the next signal if wrong.
//
// 2. SimPrefKey*/SimPerfKey* (42 symbols): string-constant keys, same
//    established pattern as kDADiskDescription*/kMAOptionsBAA*/SimFeature*
//    in earlier stubs -- named identically to their string value.
//
// 3. Real, derivable-from-name boolean answers (isAppleInternal, isBaaS,
//    isOSBuild, isXBS, isXBSChroot, isAppleInternalSecure,
//    currentHostHasSEP, currentHostSupportsMetal): none of these apply to
//    our patched user-space process, so false/0 is the actual correct
//    answer, not a placeholder guess -- same category as
//    DeviceIdentityIsSupported=0 before.
//
// 4. Real, sensible implementations where the name makes intent
//    unambiguous: SimStrError wraps strerror(); xpc_dictionary_get_nsdata/
//    nsstring wrap the public xpc_dictionary_get_data/get_string and box
//    the result, a well-known private-helper pattern.
//
// 5. Everything else (cryptex/personalization plumbing, simservice XPC
//    transport, the os_assumes-style assertion pair, sim_host_arch): no
//    real backing subsystem exists in this environment (no simctl daemon,
//    no cryptex infra), so these are safe inert no-ops/NULL returns.
//    Signatures are reasoned guesses from naming convention and Apple's
//    known os_assumes idiom, not verified -- a crash from a mismatched
//    signature is the next signal, same as everywhere else in this
//    project.
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <os/log.h>
#import <stdlib.h>
#import <limits.h>

// --- family 0: Objective-C categories ---
// Invisible to the nm-based symbol recon that found every other dependency
// in this file: category methods aren't linker symbols, they're just
// selectors passed to objc_msgSend. Discovered only by running the code --
// -[SimServiceContext initWithDeveloperDir:connectionType:error:] called
// -[NSString sim_realPath] and threw "Failed to get realpath for developer
// directory" when it came back nil.
//
// Real implementation, not a stub: the name, the caller's error message,
// and the sim_ prefix together make this unambiguously a realpath(3)
// wrapper. Returning nil for a nonexistent path is the correct behavior
// (it's exactly what the caller checks for), not a failure mode.
@interface NSString (CoreSimulatorUtilities)
- (NSString *)sim_realPath;
@end

@implementation NSString (CoreSimulatorUtilities)
- (NSString *)sim_realPath {
  char resolved[PATH_MAX];
  if (realpath([self fileSystemRepresentation], resolved) != NULL) {
    return [NSString stringWithUTF8String:resolved];
  }
  return nil;
}
@end

// Second category found the same way (runtime discovery, invisible to nm).
// CoreSimulator hit this inside loadValidCoreSimulatorService -- it had
// already failed to reach the CoreSimulatorService daemon and was building
// the NSError to describe that failure when the missing factory method
// aborted the process. So this isn't on a success path: implementing it is
// what lets the connect failure be *reported* instead of crashing.
//
// Domain string is the one CoreSimulator/simctl really uses. errno-style
// code and a caller-supplied description map onto NSError directly, so this
// is a real implementation rather than a stub.
@interface NSError (CoreSimulatorUtilities)
+ (NSError *)errorWithSimErrno:(int)simErrno
          localizedDescription:(NSString *)localizedDescription;
+ (NSError *)errorWithPOSIXError:(int)posixError
                   failureReason:(NSString *)failureReason;
+ (NSError *)errorWithSimErrno:(int)simErrno userInfo:(NSDictionary *)userInfo;
@end

@implementation NSError (CoreSimulatorUtilities)
+ (NSError *)errorWithSimErrno:(int)simErrno
          localizedDescription:(NSString *)localizedDescription {
  NSDictionary *userInfo = localizedDescription
      ? @{NSLocalizedDescriptionKey : localizedDescription}
      : nil;
  return [NSError errorWithDomain:@"com.apple.CoreSimulator.SimError"
                             code:simErrno
                         userInfo:userInfo];
}

// Sibling factory, found the same way: once the RuntimeRoot directory
// existed, SimRuntime got past the 401 check and hit THIS on its next error
// path -- so whatever fails after RuntimeRoot exists is a POSIX-level
// failure (a stat/open of something inside it). Real implementation:
// NSPOSIXErrorDomain plus the caller's reason, so strerror-style diagnosis
// survives into the log and tells us which file it actually wanted.
+ (NSError *)errorWithPOSIXError:(int)posixError
                   failureReason:(NSString *)failureReason {
  NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
  const char *desc = strerror(posixError);
  if (desc) {
    userInfo[NSLocalizedDescriptionKey] = @(desc);
  }
  if (failureReason) {
    userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
  }
  return [NSError errorWithDomain:NSPOSIXErrorDomain
                             code:posixError
                         userInfo:userInfo];
}

// Third variant of the same family (userInfo: rather than
// localizedDescription:). This is the one -[SimRuntime isAvailableWithError:]
// uses, so without it the actual reason a runtime is unavailable never
// surfaces -- the probe's generic placeholder stood in and hid it. Same
// domain as the other SimErrno factory; the caller supplies userInfo whole.
+ (NSError *)errorWithSimErrno:(int)simErrno userInfo:(NSDictionary *)userInfo {
  return [NSError errorWithDomain:@"com.apple.CoreSimulator.SimError"
                             code:simErrno
                         userInfo:userInfo];
}
@end

// These two are transcribed from the REAL implementations, disassembled out
// of Apple's CoreSimulatorUtilities on the CI runner -- not inferred. They
// matter more than they look: both were being stubbed to nil by the probe's
// sim_ heuristic, so when CoreSimulator parsed a genuine Apple
// .simdevicetype it asked "16.1" for its packed version and "arm64" for its
// cpu type, got nothing back, and silently registered no device types at
// all. Guessing the arithmetic wasn't safe because these values get compared
// against each other and against compiled-in constants.
//
// -[NSString(SIMPackedVersion) sim_packedVersion], verbatim from the
// disassembly: split on ".", then
//   (major << 16) | ((minor & 0xFF) << 8) | (patch & 0xFF)
// with missing components treated as 0. So "16.1" -> 0x100100.
@interface NSString (SIMPackedVersion)
- (unsigned int)sim_packedVersion;
@end

@implementation NSString (SIMPackedVersion)
- (unsigned int)sim_packedVersion {
  NSArray<NSString *> *components = [self componentsSeparatedByString:@"."];
  unsigned int major = components.count >= 1 ? (unsigned int)[components[0] intValue] : 0;
  unsigned int minor = components.count >= 2 ? (unsigned int)[components[1] intValue] : 0;
  unsigned int patch = components.count >= 3 ? (unsigned int)[components[2] intValue] : 0;
  return (major << 16) | ((minor & 0xFF) << 8) | (patch & 0xFF);
}
@end

// -[NSString(SIMCPUType) sim_cpuType]: a string compare chain returning the
// standard mach/machine.h constants. The disassembly computes the arm64 case
// as x86_64's value plus 5 (7 -> 12), which is just CPU_TYPE_X86_64 ->
// CPU_TYPE_ARM64 with the ABI64 bit already set.
// Reached during actual device creation. -[SimRuntime
// createInitialContentPath:error:] disassembles to: check the destination
// doesn't already exist, get sampleContentPath, then
//     [fileManager sim_copyItemAtPath:sample toCreatedPath:dest error:&err]
// and NSAssert on the result. Stubbed to nil that read as failure, and the
// assertion aborted the process uncatchably -- which is as far as device
// creation got. Real implementation: create the destination's parent chain,
// clear any stale destination, then copy.
@interface NSFileManager (CoreSimulatorUtilities)
- (BOOL)sim_copyItemAtPath:(NSString *)srcPath
             toCreatedPath:(NSString *)dstPath
                     error:(NSError **)error;
@end

@implementation NSFileManager (CoreSimulatorUtilities)
- (BOOL)sim_copyItemAtPath:(NSString *)srcPath
             toCreatedPath:(NSString *)dstPath
                     error:(NSError **)error {
  if (!srcPath || !dstPath) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.apple.CoreSimulator.SimError"
                                   code:EINVAL
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"sim_copyItemAtPath: nil source or destination"
                               }];
    }
    return NO;
  }
  NSString *parent = [dstPath stringByDeletingLastPathComponent];
  [self createDirectoryAtPath:parent
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
  // "toCreatedPath" implies the destination is freshly made, so clear any
  // leftover -- copyItemAtPath: fails outright if the destination exists.
  [self removeItemAtPath:dstPath error:NULL];
  return [self copyItemAtPath:srcPath toPath:dstPath error:error];
}
@end

// Seen in the missing-selector list alongside the above. Same family as
// sim_realPath: compare paths after resolving them, so symlinks and /private
// prefixes don't produce false negatives.
@interface NSString (SIMRealPathPrefix)
- (BOOL)sim_realPathHasPrefix:(NSString *)prefix;
@end

@implementation NSString (SIMRealPathPrefix)
- (BOOL)sim_realPathHasPrefix:(NSString *)prefix {
  if (!prefix) return NO;
  char selfResolved[PATH_MAX];
  char prefixResolved[PATH_MAX];
  const char *s = realpath([self fileSystemRepresentation], selfResolved)
                      ? selfResolved
                      : [self fileSystemRepresentation];
  const char *p = realpath([prefix fileSystemRepresentation], prefixResolved)
                      ? prefixResolved
                      : [prefix fileSystemRepresentation];
  if (!s || !p) return NO;
  return strncmp(s, p, strlen(p)) == 0;
}
@end

@interface NSString (SIMCPUType)
- (int)sim_cpuType;
@end

@implementation NSString (SIMCPUType)
- (int)sim_cpuType {
  if ([self isEqualToString:@"i386"]) return 7;                 // CPU_TYPE_X86
  if ([self isEqualToString:@"x86_64"]) return 7 | 0x01000000;  // CPU_TYPE_X86_64
  if ([self isEqualToString:@"arm64"] || [self isEqualToString:@"arm64e"]) {
    return 12 | 0x01000000;                                     // CPU_TYPE_ARM64
  }
  return 0;
}
@end

// Third real category, and the most interesting one yet: it was reached only
// via serviceContextForDeveloperDir:connectionType:error: with connectionType
// 1, 2 or 3. Types 0 and standaloneConnectionWithError: both die on the
// daemon version handshake (SimError 61), but 1-3 get PAST that and ask for
// simulator preferences instead -- the first evidence of a code path not
// gated on the missing CoreSimulatorService.
//
// Real implementation: a defaults object scoped to CoreSimulator's own
// preference domain, which is what the name says and what the caller will
// read settings from. Falls back to standardUserDefaults if the suite can't
// be created, since returning nil here would just move the failure.
@interface NSUserDefaults (CoreSimulatorUtilities)
+ (NSUserDefaults *)simulatorDefaults;
@end

@implementation NSUserDefaults (CoreSimulatorUtilities)
+ (NSUserDefaults *)simulatorDefaults {
  static NSUserDefaults *simulatorDefaults;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    simulatorDefaults =
        [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.CoreSimulator"];
    if (!simulatorDefaults) {
      simulatorDefaults = [NSUserDefaults standardUserDefaults];
    }
  });
  return simulatorDefaults;
}
@end

// NOTE: there is deliberately no +bundleForClass here. It was implemented
// once, as +[NSObject bundleForClass] returning +[NSBundle bundleForClass:],
// on the theory that it was a third CoreSimulator category. That was wrong
// twice over, and the device proved it: "Thread stack size exceeded due to
// excessive recursion", 12671 frames deep, alternating between the two.
//
// bundleForClass (no colon) is a FOUNDATION hook -- +[NSBundle
// bundleForClass:] asks the class whether it supplies its own bundle. So
// implementing it (a) called straight back into the caller, and (b) put a
// hook on NSObject that hijacked bundle lookup for every class in the
// process, not just CoreSimulator's. It belongs unresolved, exactly like
// encodeWithOSLogCoder:options:maxLength:, and the probe's selector
// heuristic now leaves it alone.

// --- family 1: Swift-mangled classes (legacy _TtC ObjC-interop names) ---
@interface _TtC22CoreSimulatorUtilities20SimCryptexDiskHelper : NSObject
@end
@implementation _TtC22CoreSimulatorUtilities20SimCryptexDiskHelper
@end

@interface _TtC22CoreSimulatorUtilities21SimCryptexVolumePaths : NSObject
@end
@implementation _TtC22CoreSimulatorUtilities21SimCryptexVolumePaths
@end

@interface _TtC22CoreSimulatorUtilities26SimCryptexBundleInfoResult : NSObject
@end
@implementation _TtC22CoreSimulatorUtilities26SimCryptexBundleInfoResult
@end

// --- family 2: SimPerfKey*/SimPrefKey* string constants ---
CFStringRef SimPerfKeyAllowUnsupportedVisionOSHost = CFSTR("AllowUnsupportedVisionOSHost");
CFStringRef SimPerfKeyCryptex1BundleDiskImageMode = CFSTR("Cryptex1BundleDiskImageMode");
CFStringRef SimPerfKeyMarkDeletedAsPurgeableByCacheDelete = CFSTR("MarkDeletedAsPurgeableByCacheDelete");
CFStringRef SimPerfKeyPersonalizationManifestCachePath = CFSTR("PersonalizationManifestCachePath");
CFStringRef SimPerfKeyPrefersCryptexPersonalization2 = CFSTR("PrefersCryptexPersonalization2");
CFStringRef SimPerfKeyPurgeMobileAssetSimRuntimes = CFSTR("PurgeMobileAssetSimRuntimes");
CFStringRef SimPrefKeyAlwaysExpandRuntimeImages = CFSTR("AlwaysExpandRuntimeImages");
CFStringRef SimPrefKeyAlwaysUseFramebufferServer = CFSTR("AlwaysUseFramebufferServer");
CFStringRef SimPrefKeyAutomaticallyGenerateDyldShareCache = CFSTR("AutomaticallyGenerateDyldShareCache");
CFStringRef SimPrefKeyDebugBootStatusCheckFrequency = CFSTR("DebugBootStatusCheckFrequency");
CFStringRef SimPrefKeyDebugCA = CFSTR("DebugCA");
CFStringRef SimPrefKeyDebugDYLD = CFSTR("DebugDYLD");
CFStringRef SimPrefKeyDebugGuardMalloc = CFSTR("DebugGuardMalloc");
CFStringRef SimPrefKeyDebugLaunchdDisableExtensionWatchdog = CFSTR("DebugLaunchdDisableExtensionWatchdog");
CFStringRef SimPrefKeyDebugLaunchdGuardMalloc = CFSTR("DebugLaunchdGuardMalloc");
CFStringRef SimPrefKeyDebugLaunchdLaunchReasons = CFSTR("DebugLaunchdLaunchReasons");
CFStringRef SimPrefKeyDebugLaunchdQOSUtility = CFSTR("DebugLaunchdQOSUtility");
CFStringRef SimPrefKeyDebugLaunchdStartSuspended = CFSTR("DebugLaunchdStartSuspended");
CFStringRef SimPrefKeyDebugLaunchdTrampolineStandardError = CFSTR("DebugLaunchdTrampolineStandardError");
CFStringRef SimPrefKeyDebugLaunchdTrampolineStandardOutput = CFSTR("DebugLaunchdTrampolineStandardOutput");
CFStringRef SimPrefKeyDebugLaunchdVariant = CFSTR("DebugLaunchdVariant");
CFStringRef SimPrefKeyDebugLaunchdWatchdogTimeout = CFSTR("DebugLaunchdWatchdogTimeout");
CFStringRef SimPrefKeyDebugLogging = CFSTR("DebugLogging");
CFStringRef SimPrefKeyDebugMallocStackLogging = CFSTR("DebugMallocStackLogging");
CFStringRef SimPrefKeyDebugZombies = CFSTR("DebugZombies");
CFStringRef SimPrefKeyDefaultSAKSmTLSCertAuth = CFSTR("DefaultSAKSmTLSCertAuth");
CFStringRef SimPrefKeyDefaultSAKSmTLSCertPath = CFSTR("DefaultSAKSmTLSCertPath");
CFStringRef SimPrefKeyDisableRuntimeDiskImages = CFSTR("DisableRuntimeDiskImages");
CFStringRef SimPrefKeyDyldSharedCachePath = CFSTR("DyldSharedCachePath");
CFStringRef SimPrefKeyEnableDefaultSetCreation = CFSTR("EnableDefaultSetCreation");
CFStringRef SimPrefKeyEnableVolumeManager = CFSTR("EnableVolumeManager");
CFStringRef SimPrefKeyEnvironment = CFSTR("Environment");
CFStringRef SimPrefKeyJobEnvironment = CFSTR("JobEnvironment");
CFStringRef SimPrefKeyLaunchdCrashOnSIGTERMTimeout = CFSTR("LaunchdCrashOnSIGTERMTimeout");
CFStringRef SimPrefKeyLaunchdEnvironment = CFSTR("LaunchdEnvironment");
CFStringRef SimPrefKeyLaunchdSIGTERMTimeout = CFSTR("LaunchdSIGTERMTimeout");
CFStringRef SimPrefKeyLogDiscoveredProfiles = CFSTR("LogDiscoveredProfiles");
CFStringRef SimPrefKeyPR_31199278Timeout = CFSTR("PR_31199278Timeout");
CFStringRef SimPrefKeyRuntimeEnforceHostVersionRequirements = CFSTR("RuntimeEnforceHostVersionRequirements");
CFStringRef SimPrefKeyRuntimeEnforceLibLaunchHostCanLoad = CFSTR("RuntimeEnforceLibLaunchHostCanLoad");
CFStringRef SimPrefKeyUseDyldSharedCacheIfExists = CFSTR("UseDyldSharedCacheIfExists");
CFStringRef SimPrefKeyVerifyCodeSigningForInternal = CFSTR("VerifyCodeSigningForInternal");

// --- family 3: real correct answers for this environment ---
int isAppleInternal(void) { return 0; }
int isAppleInternalSecure(void) { return 0; }
int isBaaS(void) { return 0; }
int isOSBuild(void) { return 0; }
int isXBS(void) { return 0; }
int isXBSChroot(void) { return 0; }
int currentHostHasSEP(void) { return 0; }
int currentHostSupportsMetal(void) { return 0; }

// --- family 4: unambiguous real implementations ---
const char *SimStrError(int err) { return strerror(err); }

NSData *xpc_dictionary_get_nsdata(xpc_object_t dict, const char *key) {
  size_t len = 0;
  const void *bytes = xpc_dictionary_get_data(dict, key, &len);
  return bytes ? [NSData dataWithBytes:bytes length:len] : nil;
}

NSString *xpc_dictionary_get_nsstring(xpc_object_t dict, const char *key) {
  const char *str = xpc_dictionary_get_string(dict, key);
  return str ? [NSString stringWithUTF8String:str] : nil;
}

// --- family 5: guessed signatures, inert bodies ---
// Returns cpu_type_t, NOT a string. This was originally stubbed as
// `const char *sim_host_arch(void) { return "arm64e"; }`, and that single
// wrong return type is what made every registered runtime report
// "The runtime is corrupt or missing required files."
//
// -[SimRuntime isAvailableWithError:] disassembles to:
//     bl  _sim_host_arch
//     mov w8, #0x7  ; movk w8, #0x100, lsl #16   -> 0x01000007 CPU_TYPE_X86_64
//     cmp w0, w8
//     mov w8, #0xc  ; movk w8, #0x100, lsl #16   -> 0x0100000C CPU_TYPE_ARM64
//     cmp w0, w8
//     b.ne <unavailable>
// It compares the return value against cpu_type_t constants. A char* is a
// pointer and matches neither, so the arch check failed and the generic
// "corrupt or missing files" error came out -- nothing to do with files.
int sim_host_arch(void) { return 12 | 0x01000000; }  // CPU_TYPE_ARM64

CFStringRef currentHostVersion(void) { return CFSTR("1.0"); }

// Mirrors Apple's known os_assumes(long value, const char *, ...) idiom --
// _SimAssumesLogHandle is almost certainly the os_log_t handle that macro
// logs through, not a function; given a real handle here (rather than NULL)
// so any os_log call using it doesn't need a NULL-safety guarantee we can't
// verify.
os_log_t _SimAssumesLogHandle;
__attribute__((constructor))
static void init_sim_assumes_log(void) {
  _SimAssumesLogHandle = os_log_create("com.apple.coresimulator", "assumes");
}

long _SimAssumesFailure(long value, const char *fmt, ...) { return value; }

void SimSetPrefersPersonalization2(int prefers) {}

void SimSimulateCrash(void) {}

CFStringRef SimGetPersonalizationManifestPathFromCryptexInfo(CFDictionaryRef cryptexInfo) {
  return NULL;
}

// Weak-imported by CoreSimulator (missing is tolerated), implemented anyway
// since the guess is cheap: 0 as a plain success/no-error return.
int SimPersonalizeCryptexWithDefaultAttributesAtFilePath(CFStringRef path) {
  return 0;
}

void *simservice_send_request_sync(xpc_connection_t connection, xpc_object_t request) {
  return NULL;
}

xpc_object_t simservice_reply_error(int code, CFStringRef description) {
  return NULL;
}
