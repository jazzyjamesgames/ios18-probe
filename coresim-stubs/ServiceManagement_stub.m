// Unlike the CoreSimulator-private symbols elsewhere in this directory,
// SMJobSubmit/SMJobRemove/SMJobCopyDictionary are real, documented (if
// deprecated) public Apple API -- their signatures are known for certain, not
// guessed. SMJobRemove/SMJobCopyDictionary are pure bookkeeping, so a safe
// no-op is honestly correct.
//
// SMJobSubmit is different, and boot has now arrived at it.
//
// -[SimDevice createLaunchdJobWithBinpref:extraEnvironment:disabledJobs:error:]
// builds a launchd job dictionary and hands it to
//
//     SMJobSubmit(kSMDomainUserLaunchd, jobDict, NULL, &error)
//
// which on macOS asks the per-user launchd to spawn launchd_sim as a real,
// separate process. That is the whole point of the call: everything before it
// is in-process setup, and this is where CoreSimulator asks the OS to create a
// process. So this is the multi-process boundary, arrived at for real rather
// than predicted.
//
// The previous version returned false with *outError = NULL. CoreSimulator
// faithfully stored that nil, so its caller returned nil with no error, and
// -[SimDevice _onBootstrapQueue_bootWithOptions:deathMonitorPort:error:]
// asserted "failed, but it did not return an error" and aborted the process --
// an abort through libdispatch frames that no @catch can intercept.
//
// Two changes here, neither of which pretends to spawn anything:
//
//   1. The job dictionary is written out. It is the complete specification of
//      the process CoreSimulator wants: Program, ProgramArguments,
//      EnvironmentVariables, MachServices, POSIXSpawnType and the rest. Any
//      real implementation -- an NSExtension host process, a JIT-loaded
//      launchd_sim, anything else -- has to satisfy exactly this, so it is
//      worth having in hand before choosing between them.
//
//   2. It fails with a real CFError instead of a silent one, so the failure is
//      reported through CoreSimulator's normal error path rather than killing
//      the process. A truthful error keeps boot's own diagnostics working;
//      returning true would be a lie that breaks further along, where the
//      cause would be much harder to see.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

CFStringRef kSMDomainUserLaunchd = CFSTR("com.apple.launchd.peruser.stub");

// Appends to the same file the probe reads back on the next launch, so this
// lands in the log next to the boot trace without any extra plumbing. Opened
// and flushed per call because the process may abort at any point.
static void smAppendToBootTrace(NSString *text) {
  NSString *path = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Documents/boot-trace.txt"];
  FILE *f = fopen(path.fileSystemRepresentation, "a");
  if (!f) return;
  fprintf(f, "%s\n", text.UTF8String ?: "?");
  fflush(f);
  fclose(f);
}

Boolean SMJobSubmit(CFStringRef domain, CFDictionaryRef jobDict,
                    void *auth, CFErrorRef *outError) {
  @autoreleasepool {
    NSDictionary *job = (__bridge NSDictionary *)jobDict;

    NSMutableString *dump = [NSMutableString string];
    [dump appendString:@"\n*** SMJobSubmit REACHED -- this is the spawn point ***\n"];
    [dump appendFormat:@"  domain: %@\n", (__bridge NSString *)domain];
    [dump appendFormat:@"  job keys: %lu\n", (unsigned long)job.count];

    // Sorted so successive runs can be diffed against each other.
    for (id key in [[job allKeys] sortedArrayUsingComparator:^(id a, id b) {
           return [[a description] compare:[b description]];
         }]) {
      id value = job[key];
      [dump appendFormat:@"  %@ = %@\n", key, value];
    }
    smAppendToBootTrace(dump);

    // Also keep it on its own, unabridged: the log is read through a clipboard
    // copy and this dictionary is the reference for whatever comes next.
    NSString *jobPath = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/launchd-job.txt"];
    [dump writeToFile:jobPath
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:NULL];

    if (outError) {
      NSDictionary *info = @{
        (__bridge NSString *)kCFErrorLocalizedDescriptionKey:
            @"SMJobSubmit is not implemented on iOS: launchd_sim cannot be "
            @"spawned as a separate process by a sandboxed app. The job "
            @"dictionary was captured to Documents/launchd-job.txt.",
      };
      CFErrorRef err = CFErrorCreate(kCFAllocatorDefault,
                                     CFSTR("com.apple.CoreSimulator.SimError"),
                                     405, (__bridge CFDictionaryRef)info);
      *outError = (CFErrorRef)CFAutorelease(err);
    }
    return false;
  }
}

Boolean SMJobRemove(CFStringRef domain, CFStringRef jobLabel, void *auth,
                    Boolean wait, CFErrorRef *outError) {
  if (outError) {
    *outError = NULL;
  }
  return true;
}

CFDictionaryRef SMJobCopyDictionary(CFStringRef domain, CFStringRef jobLabel) {
  return NULL;
}
