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
#import <spawn.h>
#import <errno.h>
#import <sys/wait.h>

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

// Try the spawn the job actually asks for, and report exactly what the kernel
// says. Whether a sandboxed iOS app can create a process from an arbitrary
// binary has been an assumption in this project so far; posix_spawn returns an
// errno, so it can be a measurement instead. CoreSimulator itself imports the
// whole posix_spawn family, so this is the same mechanism it would use.
//
// The Program entry (simulator-trampoline) is a macOS path that does not exist
// here, but the arguments after it are real files in the downloaded
// RuntimeRoot, so each candidate is checked for existence first and only the
// ones present are attempted.
static void smTrySpawn(NSArray *args, NSMutableString *dump) {
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSUInteger i = 0; i < args.count; i++) {
    NSString *candidate = args[i];
    if (![candidate isKindOfClass:[NSString class]] ||
        ![candidate hasPrefix:@"/"]) {
      continue;
    }
    BOOL exists = [fm fileExistsAtPath:candidate];
    [dump appendFormat:@"  argv[%lu] exists=%d  %@\n",
                       (unsigned long)i, exists, candidate];
    if (!exists) continue;

    // Pass the remaining arguments through, exactly as launchd would.
    NSArray *rest = [args subarrayWithRange:
        NSMakeRange(i, args.count - i)];
    char **argv = calloc(rest.count + 1, sizeof(char *));
    for (NSUInteger j = 0; j < rest.count; j++) {
      argv[j] = strdup([rest[j] description].fileSystemRepresentation ?: "");
    }

    pid_t pid = 0;
    errno = 0;
    int rc = posix_spawn(&pid, candidate.fileSystemRepresentation, NULL, NULL,
                         argv, NULL);
    int savedErrno = errno;
    [dump appendFormat:
        @"    posix_spawn -> rc=%d pid=%d errno=%d (%s)\n",
        rc, pid, savedErrno, strerror(rc ? rc : savedErrno)];

    if (rc == 0 && pid > 0) {
      // If it really started, find out whether it stayed alive.
      int status = 0;
      pid_t w = waitpid(pid, &status, WNOHANG);
      [dump appendFormat:
          @"    *** PROCESS CREATED *** waitpid -> %d status=0x%x\n", w, status];
    }

    for (NSUInteger j = 0; j < rest.count; j++) free(argv[j]);
    free(argv);
  }
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
    // Measure the spawn rather than assume it. Program is the macOS
    // trampoline path; ProgramArguments carries the real launchd_sim chain.
    [dump appendString:@"\n  --- attempting the spawn this job asks for ---\n"];
    NSMutableArray *candidates = [NSMutableArray array];
    id program = job[@"Program"];
    if ([program isKindOfClass:[NSString class]]) [candidates addObject:program];
    id programArgs = job[@"ProgramArguments"];
    if ([programArgs isKindOfClass:[NSArray class]]) {
      [candidates addObjectsFromArray:programArgs];
    }
    smTrySpawn(candidates, dump);

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
            @"SMJobSubmit is not implemented: no launchd on iOS to submit the "
            @"job to. The job dictionary and the result of attempting the "
            @"spawn directly were captured to Documents/launchd-job.txt.",
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
