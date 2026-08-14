// Unlike the CoreSimulator-private symbols elsewhere in this directory,
// SMJobSubmit/SMJobRemove/SMJobCopyDictionary are real, documented (if
// deprecated) public Apple API -- their signatures are known for certain,
// not guessed. Bodies are wave-1 stubs: SMJobRemove/SMJobCopyDictionary are
// pure bookkeeping so a safe no-op is honestly correct. SMJobSubmit's real
// job is spawning a supervised process -- that's the LaunchHelper mechanism
// this whole project proved works, but wiring it in here is a deliberate
// follow-up, not wave 1. For now it just reports failure cleanly rather
// than silently pretending to succeed.
#import <CoreFoundation/CoreFoundation.h>

CFStringRef kSMDomainUserLaunchd = CFSTR("com.apple.launchd.peruser.stub");

Boolean SMJobSubmit(CFDictionaryRef domain, CFDictionaryRef jobDict,
                     CFDictionaryRef auth, CFDictionaryRef *outError) {
  if (outError) {
    *outError = NULL;
  }
  return false;
}

Boolean SMJobRemove(CFDictionaryRef domain, CFStringRef jobLabel,
                     CFDictionaryRef auth, Boolean wait, CFErrorRef *outError) {
  if (outError) {
    *outError = NULL;
  }
  return true;
}

CFDictionaryRef SMJobCopyDictionary(CFDictionaryRef domain, CFStringRef jobLabel) {
  return NULL;
}
