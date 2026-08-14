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
const char *sim_host_arch(void) { return "arm64e"; }

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
