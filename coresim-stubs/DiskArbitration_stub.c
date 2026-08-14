// Real, public, documented Apple API (unlike the CoreSimulator-private
// stuff elsewhere in this directory) -- signatures known for certain from
// Apple's own DiskArbitration.framework headers, not guessed. All 16
// symbols implemented at once since the full list was already known from
// symbol recon done earlier in this project, rather than discovering them
// one at a time via 16 separate dlopen round trips.
//
// Bodies are wave-1 stubs: DASessionCreate/DADissenterCreate return real,
// valid (if inert) objects since callers may dereference them; the
// Register*Callback functions are safe no-ops (nothing will ever actually
// fire, consistent with item 3's original plan -- CoreSimulator would need
// a real "unpack the disk image into a directory" implementation behind
// these to ever get real functionality, not attempted in wave 1).
#import <CoreFoundation/CoreFoundation.h>

typedef const struct __DASession *DASessionRef;
typedef const struct __DADisk *DADiskRef;
typedef const struct __DADissenter *DADissenterRef;

CFStringRef kDADiskDescriptionMediaLeafKey = CFSTR("DAMediaLeaf");
CFStringRef kDADiskDescriptionVolumeKindKey = CFSTR("DAVolumeKind");
CFStringRef kDADiskDescriptionVolumeMountableKey = CFSTR("DAVolumeMountable");
CFStringRef kDADiskDescriptionVolumeNameKey = CFSTR("DAVolumeName");
CFStringRef kDADiskDescriptionVolumeNetworkKey = CFSTR("DAVolumeNetwork");
CFStringRef kDADiskDescriptionVolumePathKey = CFSTR("DAVolumePath");

DASessionRef DASessionCreate(CFAllocatorRef allocator) {
  return (DASessionRef)CFDictionaryCreate(allocator, NULL, NULL, 0, NULL, NULL);
}

void DASessionSetDispatchQueue(DASessionRef session, dispatch_queue_t queue) {}

CFDictionaryRef DADiskCopyDescription(DADiskRef disk) {
  return CFDictionaryCreate(NULL, NULL, NULL, 0, NULL, NULL);
}

const char *DADiskGetBSDName(DADiskRef disk) { return NULL; }

DADissenterRef DADissenterCreate(CFAllocatorRef allocator, int status,
                                  CFStringRef statusString) {
  return (DADissenterRef)CFDictionaryCreate(allocator, NULL, NULL, 0, NULL, NULL);
}

void DARegisterDiskAppearedCallback(DASessionRef session, CFDictionaryRef match,
                                     void *callback, void *context) {}
void DARegisterDiskDescriptionChangedCallback(DASessionRef session,
                                               CFDictionaryRef match,
                                               CFArrayRef watch, void *callback,
                                               void *context) {}
void DARegisterDiskDisappearedCallback(DASessionRef session, CFDictionaryRef match,
                                        void *callback, void *context) {}
void DARegisterDiskUnmountApprovalCallback(DASessionRef session,
                                            CFDictionaryRef match,
                                            void *callback, void *context) {}
void DAUnregisterApprovalCallback(DASessionRef session, void *callback,
                                   void *context) {}
void DAUnregisterCallback(DASessionRef session, void *callback, void *context) {}
