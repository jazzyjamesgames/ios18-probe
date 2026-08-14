// Private, undocumented framework. Full 16-symbol list known from symbol
// recon (nm -m against the real CoreSimulator binary, "(from CoreSimDeviceIO)"
// bucket) even though this dependency itself was only discovered late, via
// LC_REEXPORT_DYLIB -- so unlike DiskArbitration/DeviceIdentity, the recon
// that produced this list came from a re-run of the same existing CI step,
// not a fresh one.
//
// Two symbols are Objective-C classes (_OBJC_CLASS_$_...), not C functions --
// CoreSimulator references these by class object (e.g. [SimDeviceIOPort ...]
// or a class check), so they need to actually exist as loadable classes,
// empty bodies are enough to satisfy eager linking and any isKindOfClass-
// style check.
//
// The 14 SimFeature* symbols follow the same naming pattern as this
// project's other private-framework stubs (kDADiskDescription*, kMAOptions*):
// externed string constants used as dictionary/set keys, named identically
// to their string value.
#import <Foundation/Foundation.h>

@interface SimDeviceIOPort : NSObject
@end
@implementation SimDeviceIOPort
@end

@interface SimMachPort : NSObject
@end
@implementation SimMachPort
@end

CFStringRef SimFeatureCarPlay = CFSTR("CarPlay");
CFStringRef SimFeatureDeviceIdentity = CFSTR("DeviceIdentity");
CFStringRef SimFeatureExternalDisplay = CFSTR("ExternalDisplay");
CFStringRef SimFeatureFallDetection = CFSTR("FallDetection");
CFStringRef SimFeatureFramebufferServer = CFSTR("FramebufferServer");
CFStringRef SimFeatureInternalDisplay = CFSTR("InternalDisplay");
CFStringRef SimFeatureNearbyInteraction = CFSTR("NearbyInteraction");
CFStringRef SimFeaturePairing = CFSTR("Pairing");
CFStringRef SimFeaturePasteboard = CFSTR("Pasteboard");
CFStringRef SimFeatureRoutableAudio = CFSTR("RoutableAudio");
CFStringRef SimFeatureTouchPressure = CFSTR("TouchPressure");
CFStringRef SimFeatureWatchPairingCompanion = CFSTR("WatchPairingCompanion");
CFStringRef SimFeatureWatchPairingQWS = CFSTR("WatchPairingQWS");

// Signature is a guess (private API, "GetDescription" suffix strongly
// suggests an enum-in/CFStringRef-out description lookup, same pattern as
// Apple's other *GetDescription private-framework functions) -- if this is
// ever actually called with a mismatched signature, the crash itself is the
// next signal, same as everywhere else in this project.
CFStringRef SimDeviceIOBundleRecoveryStrategyGetDescription(int strategy) {
  return CFSTR("");
}
