// Private, undocumented framework, but the naming is unambiguous: a set of
// NSArray/NSDictionary/NSError/NSUUID <-> xpc_object_t conversion helpers.
// Implemented for real against the public XPC API (xpc_array_*,
// xpc_dictionary_*, xpc_uuid_create) rather than stubbed as no-ops, same
// category as xpc_dictionary_get_nsdata/nsstring in the CoreSimulatorUtilities
// stub -- the intent is obvious enough from the name that a real
// implementation is more useful (and no less safe) than a guess-free no-op.
// Value coverage is deliberately partial (string/number/dictionary/array/
// data), matching what these helpers plausibly need to round-trip
// CoreSimulator's own preference/session dictionaries -- not attempting
// every possible XPC/Foundation type.
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

@interface ROCKSessionManager : NSObject
@end
@implementation ROCKSessionManager
@end

// Value is a guess (private, single symbol -- no sibling constants to infer
// a shared naming convention from, unlike the SimPrefKey/SimPerfKey
// families). Only matters if something depends on the literal string value
// matching Apple's real one, which a private in-process dictionary key is
// unlikely to.
CFStringRef kROCKDictionaryTypeEntryKey = CFSTR("TypeEntry");

xpc_object_t rock_NSDictionaryToXPCObject(NSDictionary *dict);
xpc_object_t rock_NSArrayToXPCObject(NSArray *array);
NSDictionary *rock_XPCObjectToNSDictionary(xpc_object_t obj);

xpc_object_t rock_NSArrayToXPCObject(NSArray *array) {
  xpc_object_t xarr = xpc_array_create(NULL, 0);
  for (id value in array) {
    if ([value isKindOfClass:[NSString class]]) {
      xpc_array_set_string(xarr, XPC_ARRAY_APPEND, [(NSString *)value UTF8String]);
    } else if ([value isKindOfClass:[NSNumber class]]) {
      xpc_array_set_int64(xarr, XPC_ARRAY_APPEND, [(NSNumber *)value longLongValue]);
    } else if ([value isKindOfClass:[NSDictionary class]]) {
      xpc_array_set_value(xarr, XPC_ARRAY_APPEND, rock_NSDictionaryToXPCObject(value));
    } else if ([value isKindOfClass:[NSArray class]]) {
      xpc_array_set_value(xarr, XPC_ARRAY_APPEND, rock_NSArrayToXPCObject(value));
    } else if ([value isKindOfClass:[NSData class]]) {
      NSData *d = value;
      xpc_array_set_data(xarr, XPC_ARRAY_APPEND, d.bytes, d.length);
    }
  }
  return xarr;
}

xpc_object_t rock_NSDictionaryToXPCObject(NSDictionary *dict) {
  xpc_object_t xdict = xpc_dictionary_create(NULL, NULL, 0);
  for (NSString *key in dict) {
    id value = dict[key];
    const char *k = [key UTF8String];
    if ([value isKindOfClass:[NSString class]]) {
      xpc_dictionary_set_string(xdict, k, [(NSString *)value UTF8String]);
    } else if ([value isKindOfClass:[NSNumber class]]) {
      xpc_dictionary_set_int64(xdict, k, [(NSNumber *)value longLongValue]);
    } else if ([value isKindOfClass:[NSDictionary class]]) {
      xpc_dictionary_set_value(xdict, k, rock_NSDictionaryToXPCObject(value));
    } else if ([value isKindOfClass:[NSArray class]]) {
      xpc_dictionary_set_value(xdict, k, rock_NSArrayToXPCObject(value));
    } else if ([value isKindOfClass:[NSData class]]) {
      NSData *d = value;
      xpc_dictionary_set_data(xdict, k, d.bytes, d.length);
    }
  }
  return xdict;
}

xpc_object_t rock_NSUUIDToXPCObject(NSUUID *uuid) {
  uuid_t bytes;
  [uuid getUUIDBytes:bytes];
  return xpc_uuid_create(bytes);
}

xpc_object_t rock_NSErrorToXPCObject(NSError *error) {
  xpc_object_t xdict = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(xdict, "domain", [error.domain UTF8String]);
  xpc_dictionary_set_int64(xdict, "code", error.code);
  if (error.userInfo.count) {
    xpc_dictionary_set_value(xdict, "userInfo", rock_NSDictionaryToXPCObject(error.userInfo));
  }
  return xdict;
}

NSDictionary *rock_XPCObjectToNSDictionary(xpc_object_t obj) {
  if (!obj || xpc_get_type(obj) != XPC_TYPE_DICTIONARY) return nil;
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  xpc_dictionary_apply(obj, ^bool(const char *key, xpc_object_t value) {
    NSString *nsKey = [NSString stringWithUTF8String:key];
    xpc_type_t type = xpc_get_type(value);
    if (type == XPC_TYPE_STRING) {
      result[nsKey] = [NSString stringWithUTF8String:xpc_string_get_string_ptr(value)];
    } else if (type == XPC_TYPE_INT64) {
      result[nsKey] = @(xpc_int64_get_value(value));
    } else if (type == XPC_TYPE_DOUBLE) {
      result[nsKey] = @(xpc_double_get_value(value));
    } else if (type == XPC_TYPE_DICTIONARY) {
      result[nsKey] = rock_XPCObjectToNSDictionary(value);
    } else if (type == XPC_TYPE_DATA) {
      size_t len = xpc_data_get_length(value);
      result[nsKey] = [NSData dataWithBytes:xpc_data_get_bytes_ptr(value) length:len];
    }
    return true;
  });
  return result;
}

NSError *rock_XPCObjectToNSError(xpc_object_t obj) {
  if (!obj || xpc_get_type(obj) != XPC_TYPE_DICTIONARY) return nil;
  const char *domain = xpc_dictionary_get_string(obj, "domain");
  int64_t code = xpc_dictionary_get_int64(obj, "code");
  NSDictionary *userInfo = nil;
  xpc_object_t ui = xpc_dictionary_get_value(obj, "userInfo");
  if (ui) userInfo = rock_XPCObjectToNSDictionary(ui);
  return [NSError errorWithDomain:domain ? [NSString stringWithUTF8String:domain] : @"ROCKit"
                              code:(NSInteger)code
                          userInfo:userInfo];
}
