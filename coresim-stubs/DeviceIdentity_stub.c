// Private, undocumented framework -- unlike DiskArbitration/ServiceManagement,
// exact function signatures aren't publicly known, only names (from symbol
// recon done earlier). DeviceIdentityIsSupported() returning false is a
// real correct answer, not a guess standing in for unknown behavior: this
// is Apple's BAA (device attestation) framework, and there's no SEP-backed
// attestation available in our stub context. If CoreSimulator's real code
// checks supportedness before touching anything else here (the sensible,
// likely pattern given the name), that one answer should mean the other
// symbols never actually get called -- they just need to exist to satisfy
// eager linking.
#import <CoreFoundation/CoreFoundation.h>

int DeviceIdentityIsSupported(void) { return 0; }

// Signature is a guess (private API, "WithCompletion" suggests a block-based
// async completion handler) -- if this is ever actually called with a
// mismatched signature, that's a crash, and the crash itself is the next
// signal, same as everywhere else in this project.
void DeviceIdentityIssueClientCertificateWithCompletion(
    CFDictionaryRef options, void (^completion)(CFTypeRef result, CFErrorRef error)) {
  if (completion) {
    completion(NULL, NULL);
  }
}

CFStringRef kMAOptionsBAAAccessControls = CFSTR("BAAAccessControls");
CFStringRef kMAOptionsBAADeleteExistingKeysAndCerts = CFSTR("BAADeleteExistingKeysAndCerts");
CFStringRef kMAOptionsBAAIgnoreExistingKeychainItems = CFSTR("BAAIgnoreExistingKeychainItems");
CFStringRef kMAOptionsBAAKeychainAccessGroup = CFSTR("BAAKeychainAccessGroup");
CFStringRef kMAOptionsBAAKeychainLabel = CFSTR("BAAKeychainLabel");
CFStringRef kMAOptionsBAANetworkTimeoutInterval = CFSTR("BAANetworkTimeoutInterval");
CFStringRef kMAOptionsBAAOIDAccessControls = CFSTR("BAAOIDAccessControls");
CFStringRef kMAOptionsBAAOIDDeviceOSInformation = CFSTR("BAAOIDDeviceOSInformation");
CFStringRef kMAOptionsBAAOIDHardwareProperties = CFSTR("BAAOIDHardwareProperties");
CFStringRef kMAOptionsBAAOIDKeyUsageProperties = CFSTR("BAAOIDKeyUsageProperties");
CFStringRef kMAOptionsBAAOIDSToInclude = CFSTR("BAAOIDSToInclude");
CFStringRef kMAOptionsBAASCRTAttestation = CFSTR("BAASCRTAttestation");
CFStringRef kMAOptionsBAAValidity = CFSTR("BAAValidity");
CFStringRef kMAOptionsResuseExistingKey = CFSTR("BAAResuseExistingKey");
