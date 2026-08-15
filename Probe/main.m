// Minimal probe app. On launch it dlopen()s the patched target dylib with
// RTLD_NOW (so *all* referenced symbols resolve immediately instead of
// trickling in as lazy-bound calls are hit), then dlsym()s and calls
// probe_run() -- whatever dlerror() says, or wherever it stops, is the
// actual spec for what to build next.
//
// It then also triggers LaunchHelper -- a bundled app-extension -- as a
// genuinely separate OS process, to test real process isolation (as
// opposed to everything above, which runs in-process). NSExtension itself
// is a real but undocumented Foundation class; this forward declaration is
// adapted directly from LiveContainer's own FoundationPrivate.h, which is
// how their shipping code uses it too.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <objc/objc-exception.h>
#import <unistd.h>
#import <sys/syslimits.h>
#import <sys/mman.h>
#import "RuntimeFetcher.h"

@interface NSExtension : NSObject
@property(nonatomic, strong, readwrite) NSArray *preferredLanguages;
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *uuid, NSError *error))callback;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))callback;
@end

// Darwin notification checkpoints from LaunchHelper. Set on whatever thread
// CFNotificationCenter delivers on; read back only after explicitly pumping
// the run loop below, since a plain dispatch_semaphore_wait/NSThread sleep
// does NOT spin the run loop and would otherwise never let these callbacks
// fire at all.
static BOOL gStarted = NO, gDlopenDone = NO, gProbeRunDone = NO, gReachedEnd = NO;

static void darwinCallback(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
  NSString *n = (__bridge NSString *)name;
  if ([n hasSuffix:@"started"])
    gStarted = YES;
  else if ([n hasSuffix:@"dlopenDone"])
    gDlopenDone = YES;
  else if ([n hasSuffix:@"probeRunDone"])
    gProbeRunDone = YES;
  else if ([n hasSuffix:@"reachedEnd"])
    gReachedEnd = YES;
}

// Missing-selector discovery. The last device test died on the FIRST
// unrecognized selector CoreSimulator sent to an NSString constant. Since
// each round trip here costs a manual install, this catches the whole set
// in one run instead: +resolveInstanceMethod: is the runtime's last chance
// to supply a method before it raises, so hooking it lets us log the
// selector AND install a stub so execution continues to the next one.
//
// Each discovery is written to disk immediately rather than at the end --
// if a later stub's nil return causes a hard (non-ObjC, uncatchable) crash,
// everything found up to that point still survives on disk.
//
// The stub returns nil/0, which is correct-shaped for object, BOOL and
// integer returns on arm64 but NOT for double/struct returns; a garbled
// value there would be its own signal.
static NSMutableArray<NSString *> *gMissingSelectors;
static NSString *gMissingSelectorsPath;

static id probeMissingSelectorStub(id self, SEL _cmd) { return nil; }

// For unknown +[NSError errorWith...] factories specifically. Returning nil
// from an error constructor tends to turn a diagnosable failure into a crash
// downstream, and an unrecognized one aborts the run outright -- which is how
// a single missing errorWithPOSIXError:failureReason: ended an entire
// progressive-construction pass. A real (if generic) NSError keeps the run
// alive and still shows up in the log as an obvious placeholder.
static id probeGenericErrorStub(id self, SEL _cmd) {
  // Names the selector it stood in for. The first version returned a fixed
  // string, and when isAvailableWithError: went through an unimplemented
  // factory the placeholder replaced the real reason with no clue as to
  // WHICH factory to implement -- costing a whole device round trip. _cmd is
  // right there, so say it. Built with stringWithUTF8String/sel_getName
  // rather than %@ formatting, since this can run inside selector resolution
  // (see probeDescribeSelector).
  char buf[256];
  snprintf(buf, sizeof(buf),
           "placeholder from unimplemented NSError factory +[NSError %s]",
           sel_getName(_cmd));
  NSString *desc = [NSString stringWithUTF8String:buf] ?: @"placeholder error";
  return [NSError errorWithDomain:@"ProbeStubbedErrorFactory"
                             code:-1
                         userInfo:@{NSLocalizedDescriptionKey : desc}];
}

// Writes each discovery straight to the pasteboard as it happens. The last
// failure terminated via std::terminate inside _dispatch_client_callout --
// libdispatch is built without exception unwinding, so an ObjC exception
// thrown inside a dispatch_sync barrier can't unwind back to our @try and
// aborts the process instead. Nothing that runs at the end of launch (the
// clipboard copy, the log write) gets a chance to run in that case, and the
// Files app can't reach the on-disk log on this install -- so the only way
// a discovery survives is to publish it the moment it's found.
// The whole log, not just the selector list, gets republished on every
// update. Previous runs put ONLY the missing-selector list on the clipboard,
// so when the process aborted mid-launch everything the log had already
// established was lost with it.
static NSMutableString *gLog;
static NSString *gLogPath;
static UITextView *gTextView;
static NSString *gLastPublished;

// Filesystem-check tracing. isAvailableWithError: reports a deliberately
// generic "runtime is corrupt or missing required files" that names nothing,
// and two rounds of inferring from it (SystemVersion.plist, dyld/liblaunch
// stubs, the sim_host_arch cpu_type fix) failed to move it. Rather than keep
// guessing, swizzle NSFileManager's existence checks and record every path
// CoreSimulator probes, with the answer it got -- the failing ones ARE the
// requirement list.
static NSMutableArray<NSString *> *gFileTrace;
static BOOL gTracingFiles;
static IMP gOrigFileExists;
static IMP gOrigFileExistsIsDir;

// Guards the missing-selector list, which the process-wide selector hooks
// touch from whatever thread hits an unresolved selector.
static NSLock *probeLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}

// Called only from the probe thread, which is the sole owner of gLog. The
// missing-selector list is shared with the hooks, so it's snapshotted under
// the lock rather than read live.
static void probePublish(void) {
  NSLock *lock = probeLock();
  [lock lock];
  NSArray *missingSnapshot = [gMissingSelectors copy];
  [lock unlock];

  NSMutableString *out = [NSMutableString string];
  if (gLog) [out appendString:gLog];
  if (missingSnapshot.count) {
    [out appendFormat:@"\n\n--- missing selectors seen so far (%lu) ---\n%@\n",
                      (unsigned long)missingSnapshot.count,
                      [missingSnapshot componentsJoinedByString:@"\n"]];
  }
  if (gLogPath) {
    [out writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  gLastPublished = [out copy];
  // The probe now runs off the main thread, so UIKit and the pasteboard have
  // to be touched back on it. Updating the text view here (rather than once
  // at the end) means a call that never returns still leaves everything
  // learned up to that point on screen and on the clipboard.
  NSString *snapshot = gLastPublished;
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIPasteboard generalPasteboard].string = snapshot;
    gTextView.text = snapshot;
  });
}

// Its OWN lock, deliberately not probeLock(). The first version formatted
// with %@ while holding probeLock, and %@ probes its argument for description
// selectors -> selector resolution -> probeRecordMissing -> probeLock again.
// NSLock isn't recursive, so that thread deadlocked while holding the lock,
// and every later flush() blocked on it forever: output just stopped mid-run
// with no crash. It survived one earlier run purely because those selectors
// happened to be resolved and cached already -- a race, not a fix.
//
// Now: no %@ anywhere (C formatting, same reasoning as probeDescribeSelector),
// the string is built BEFORE any lock is taken, and the trace has a separate
// lock so it can never contend with selector resolution at all.
static NSLock *probeFileTraceLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}

static void probeRecordFileCheck(NSString *path, BOOL existed) {
  if (!gTracingFiles || !path) return;
  const char *p = [path UTF8String];
  char buf[1200];
  snprintf(buf, sizeof(buf), "%s %s", existed ? "  ok" : "MISS", p ? p : "(null path)");
  NSString *entry = [NSString stringWithUTF8String:buf] ?: @"(unprintable path)";
  NSLock *lock = probeFileTraceLock();
  [lock lock];
  [gFileTrace addObject:entry];
  [lock unlock];
}

static BOOL probeFileExists(id self, SEL _cmd, NSString *path) {
  BOOL r = ((BOOL (*)(id, SEL, NSString *))gOrigFileExists)(self, _cmd, path);
  probeRecordFileCheck(path, r);
  return r;
}

static BOOL probeFileExistsIsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
  BOOL r = ((BOOL (*)(id, SEL, NSString *, BOOL *))gOrigFileExistsIsDir)(self, _cmd, path, isDir);
  probeRecordFileCheck(path, r);
  return r;
}

// Captures NSAssert failures. Device creation dies inside an assertion on
// CoreSimulator's own bootstrap queue: an uncatchable abort that the log
// can't reach and that no longer even produces a fresh crash report. But
// NSAssert routes through NSAssertionHandler first, so intercepting that
// yields the function, file, line and message -- everything the crash
// report would have told us -- while the process is still alive.
//
// Publishes SYNCHRONOUSLY: the usual dispatch_async to the main thread would
// never run, because abort() follows immediately.
// NSSetUncaughtExceptionHandler rather than swizzling NSAssertionHandler.
// The swizzle was a bad idea twice over: its fixed-arity replacement stood in
// for a VARIADIC method (handleFailureInFunction:...description:, ...), and
// it wrote to UIPasteboard synchronously from a background thread -- the
// pasteboard lives in another process, so that call can block, and a blocked
// background thread during abort meant nothing got published at all.
//
// This handler is the supported hook for exactly this: an NSAssert raises an
// NSException, and libobjc runs the uncaught handler before aborting, even on
// a dispatch queue. It gets the reason AND the call stack.
//
// Writes to DISK first (cheap, local, cannot block on another process), and
// only then attempts the pasteboard -- so a slow pasteboard can't cost us the
// findings.
// Where a captured exception is parked for the NEXT launch to publish.
// Writing it straight to the pasteboard from the handler is what failed
// before: the pasteboard is served by another process, that call can block,
// and abort() follows immediately -- so nothing ever landed. A local file
// write can't block on anyone else.
static NSString *gExceptionCrumbPath;
// Held so the boot step can use the device created a step earlier.
static id gCreatedDevice;

// Boot's pre-flight check reads process limits via
// sysctlbyname("kern.maxprocperuid") and proc_pidinfo, and inside an iOS app
// sandbox that returns 1 -- so -[SimHostResourceChecker isSafeToBootWithError:]
// refuses before ever attempting a spawn ("maxUserProcs: 1 ...
// enforcedProcBuffer: 100").
//
// These replacements report generous limits so the check passes and boot
// proceeds to what it actually does. That is the point: the verdict is a
// policy gate, and the interesting question is what happens BEHIND it. If
// spawning genuinely can't work here, the failure should come from the spawn
// itself, with a real error, not from a sysctl the sandbox answers oddly.
//
// Deliberately overriding the INPUTS rather than isSafeToBootWithError: --
// leaving the real decision logic intact means anything else it checks
// (memory, file descriptors) still gets a truthful answer.
static NSUInteger probeMaxUserProcs(id self, SEL _cmd) { return 2000; }
static NSUInteger probeRunningUserProcs(id self, SEL _cmd) { return 50; }
static NSUInteger probeMaxSystemProcs(id self, SEL _cmd) { return 4000; }
static NSUInteger probeRunningSystemProcs(id self, SEL _cmd) { return 100; }
static NSUInteger probeMaxFiles(id self, SEL _cmd) { return 100000; }
static NSUInteger probeOpenFiles(id self, SEL _cmd) { return 100; }

static void probeWriteExceptionCrumb(NSException *ex) {
  if (!gExceptionCrumbPath) return;
  NSMutableString *entry = [NSMutableString string];
  [entry appendString:@"\n*** UNCAUGHT EXCEPTION (from the previous run) ***\n"];
  [entry appendFormat:@"  name: %s\n", ex.name ? [ex.name UTF8String] : "?"];
  [entry appendFormat:@"  reason: %s\n", ex.reason ? [ex.reason UTF8String] : "?"];
  for (NSString *frame in ex.callStackSymbols) {
    [entry appendFormat:@"  %s\n", [frame UTF8String]];
  }
  [entry writeToFile:gExceptionCrumbPath
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
  NSLog(@"[PROBE] captured exception: %s",
        ex.reason ? [ex.reason UTF8String] : "?");
}

// --- boot tracing -----------------------------------------------------------
//
// Boot now dies inside -[SimDevice _onBootstrapQueue_bootWithOptions:...] with
//
//   -createLaunchdJobWithBinpref:extraEnvironment:disabledJobs:error: failed,
//    but it did not return an error.
//
// which is the worst kind of failure: CoreSimulator itself doesn't know why.
// Reading the disassembly narrowed it to an early `cbz w0` on the result of
// -createOverlayLaunchdPlistsWithError:, but every NO-returning path in that
// call chain looked like it sets an error, so the static read doesn't settle
// it. These wrappers report what actually happened.
//
// The exception unwinds through libdispatch's dispatch_sync frames, which have
// no unwind information, so it aborts via _objc_terminate instead of
// propagating -- @catch around bootWithOptions: can never see it (confirmed by
// the crash report). That's also why this writes to disk on every line and
// flushes: whatever reaches the file before the abort is what we get to read
// on the next launch.
static NSString *gBootTracePath;

static void probeBootLog(NSString *line) {
  if (!gBootTracePath) return;
  FILE *f = fopen(gBootTracePath.fileSystemRepresentation, "a");
  if (!f) return;
  fprintf(f, "%s\n", line.UTF8String ?: "?");
  fflush(f);
  fclose(f);
}

static IMP gOrigCreateJob, gOrigOverlay, gOrigOverlayDir, gOrigPlatformRes;
static IMP gOrigPortsToRegister, gOrigLaunchdJobName;

static id probeCreateJob(id self, SEL _cmd, id binpref, id env, id disabled,
                         NSError **error) {
  probeBootLog([NSString stringWithFormat:
      @"-> createLaunchdJobWithBinpref:%@ extraEnvironment:%@ disabledJobs:%@",
      binpref, env ? @"(dict)" : @"(nil)", disabled ? @"(obj)" : @"(nil)"]);
  NSError *local = nil;
  id result = ((id (*)(id, SEL, id, id, id, NSError **))gOrigCreateJob)(
      self, _cmd, binpref, env, disabled, &local);
  probeBootLog([NSString stringWithFormat:
      @"<- createLaunchdJobWithBinpref: result=%@ error=%@",
      result ? @"(job dict)" : @"NIL", local ?: @"(none)"]);
  if (error && local) *error = local;
  return result;
}

static BOOL probeOverlay(id self, SEL _cmd, NSError **error) {
  NSError *local = nil;
  BOOL ok = ((BOOL (*)(id, SEL, NSError **))gOrigOverlay)(self, _cmd, &local);
  probeBootLog([NSString stringWithFormat:
      @"   createOverlayLaunchdPlistsWithError: -> %d error=%@",
      ok, local ?: @"(none)"]);
  if (error && local) *error = local;
  return ok;
}

static BOOL probeOverlayDir(id self, SEL _cmd, NSString *dir, NSString *root,
                            NSError **error) {
  NSError *local = nil;
  BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))gOrigOverlayDir)(
      self, _cmd, dir, root, &local);
  probeBootLog([NSString stringWithFormat:
      @"   createOverlayLaunchdPlistsFromFilesInDirectory:%@\n"
       "                                    executableRoot:%@\n"
       "     -> %d error=%@",
      dir ?: @"(nil)", root ?: @"(nil)", ok, local ?: @"(none)"]);
  if (error && local) *error = local;
  return ok;
}

static id probePlatformRes(id self, SEL _cmd) {
  id result = ((id (*)(id, SEL))gOrigPlatformRes)(self, _cmd);
  probeBootLog([NSString stringWithFormat:
      @"   platformResourcesPath -> %@", result ?: @"(nil)"]);
  return result;
}

static id probePortsToRegister(id self, SEL _cmd) {
  id result = ((id (*)(id, SEL))gOrigPortsToRegister)(self, _cmd);
  probeBootLog([NSString stringWithFormat:
      @"   portsToRegisterWithLaunchd -> %@", result ?: @"(nil)"]);
  return result;
}

static id probeLaunchdJobName(id self, SEL _cmd) {
  id result = ((id (*)(id, SEL))gOrigLaunchdJobName)(self, _cmd);
  probeBootLog([NSString stringWithFormat:
      @"   launchdJobName -> %@", result ?: @"(nil)"]);
  return result;
}

// Swap in the wrappers above. Each returns the original's value untouched and
// forwards any error it produced, so this observes the boot without altering
// it.
static NSString *probeInstallBootTracing(void) {
  struct { const char *cls; const char *sel; IMP replacement; IMP *original; }
  hooks[] = {
    { "SimDevice", "createLaunchdJobWithBinpref:extraEnvironment:disabledJobs:error:",
      (IMP)probeCreateJob, &gOrigCreateJob },
    { "SimDevice", "createOverlayLaunchdPlistsWithError:",
      (IMP)probeOverlay, &gOrigOverlay },
    { "SimDevice", "createOverlayLaunchdPlistsFromFilesInDirectory:executableRoot:error:",
      (IMP)probeOverlayDir, &gOrigOverlayDir },
    { "SimRuntime", "platformResourcesPath",
      (IMP)probePlatformRes, &gOrigPlatformRes },
    { "SimDevice", "portsToRegisterWithLaunchd",
      (IMP)probePortsToRegister, &gOrigPortsToRegister },
    { "SimDevice", "launchdJobName",
      (IMP)probeLaunchdJobName, &gOrigLaunchdJobName },
  };
  NSMutableArray *installed = [NSMutableArray array];
  NSMutableArray *missing = [NSMutableArray array];
  for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
    Class cls = objc_getClass(hooks[i].cls);
    SEL sel = sel_registerName(hooks[i].sel);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) {
      [missing addObject:[NSString stringWithUTF8String:hooks[i].sel]];
      continue;
    }
    *(hooks[i].original) = method_setImplementation(m, hooks[i].replacement);
    [installed addObject:[NSString stringWithUTF8String:hooks[i].sel]];
  }
  return [NSString stringWithFormat:@"boot tracing on %lu method(s)%@",
                                    (unsigned long)installed.count,
                                    missing.count
                                        ? [@"; NOT FOUND: " stringByAppendingString:
                                              [missing componentsJoinedByString:@", "]]
                                        : @""];
}

// --- can launchd_sim's code be loaded at all? -------------------------------
//
// posix_spawn of the binaries the launchd job names returns EPERM, measured on
// device against the real files. So a separate process can only be one of our
// own app extensions, and launchd_sim would have to be LOADED into it rather
// than exec'd -- which is what LiveContainer does for iOS apps: flip
// MH_EXECUTE to MH_DYLIB and dlopen the result.
//
// Two things have to be true for that to be possible, and neither has been
// tested here. This measures both.
//
//   1. Unsigned code execution (JIT). A file in the data container carries no
//      signature dyld will accept, unless the process is CS_DEBUGGED -- what
//      SideStore's JIT does. csops reports that directly.
//   2. dlopen accepting the converted binary at all.
//
// The RWX page is deliberately NOT executed unless CS_DEBUGGED is set: jumping
// to unsigned pages without it is a hard kill, which would take the run down
// with it and teach nothing that the flag doesn't already say.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define PROBE_CS_OPS_STATUS 0
#define PROBE_CS_DEBUGGED 0x10000000
#define PROBE_CS_VALID 0x00000001
#define PROBE_CS_GET_TASK_ALLOW 0x00000004

static void probeTestCodeLoading(NSMutableString *log, NSString *runtimeRoot) {
  [log appendString:@"\n=== F. Can launchd_sim's code be loaded into a process? ===\n"];

  uint32_t flags = 0;
  int rc = csops(getpid(), PROBE_CS_OPS_STATUS, &flags, sizeof(flags));
  BOOL debugged = (flags & PROBE_CS_DEBUGGED) != 0;
  [log appendFormat:@"csops -> rc=%d flags=0x%08x  (CS_VALID=%d CS_DEBUGGED=%d "
                     "CS_GET_TASK_ALLOW=%d)\n",
                    rc, flags, (flags & PROBE_CS_VALID) != 0, debugged,
                    (flags & PROBE_CS_GET_TASK_ALLOW) != 0];
  [log appendFormat:@"  JIT / unsigned code execution: %@\n",
                    debugged ? @"AVAILABLE (CS_DEBUGGED is set)"
                             : @"NOT available -- launch via SideStore with JIT "
                                "enabled to change this"];

  // Whether the kernel will even hand out an executable mapping.
  void *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                    MAP_ANON | MAP_PRIVATE, -1, 0);
  if (page != MAP_FAILED) {
    uint32_t code[] = { 0xd2800540, 0xd65f03c0 };  // mov x0, #42 ; ret
    memcpy(page, code, sizeof(code));
    int mp = mprotect(page, 4096, PROT_READ | PROT_EXEC);
    [log appendFormat:@"  mprotect(R|X) -> %d%s\n", mp,
                      mp == 0 ? "" : " (errno above)"];
    if (mp == 0 && debugged) {
      int (*fn)(void) = (int (*)(void))page;
      [log appendFormat:@"  executed it -> %d (expected 42)\n", fn()];
    } else if (mp == 0) {
      [log appendString:@"  not executing it: without CS_DEBUGGED that is a "
                         "hard kill, and the flag already answers the question\n"];
    }
    munmap(page, 4096);
  }

  // Now the real subject: launchd_sim itself.
  NSString *src = [runtimeRoot stringByAppendingPathComponent:@"sbin/launchd_sim"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:src]) {
    [log appendFormat:@"launchd_sim not found at %@\n", src];
    return;
  }

  NSMutableData *bin = [NSMutableData dataWithContentsOfFile:src];
  [log appendFormat:@"launchd_sim: %lu bytes\n", (unsigned long)bin.length];
  if (bin.length < 32) return;

  uint32_t *hdr = (uint32_t *)bin.mutableBytes;
  [log appendFormat:@"  magic=0x%08x filetype=%u (2=MH_EXECUTE 6=MH_DYLIB)\n",
                    hdr[0], hdr[3]];

  // Flip MH_EXECUTE -> MH_DYLIB so dlopen will consider it at all, and record
  // the platform, since a simulator binary is built for platform 7 (iOS
  // Simulator) rather than 2 (iOS) and dyld checks that separately.
  if (hdr[3] == 2) {
    hdr[3] = 6;
    [log appendString:@"  patched filetype MH_EXECUTE -> MH_DYLIB\n"];
  }

  NSString *dst = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Documents/launchd_sim_as_dylib.dylib"];
  [fm removeItemAtPath:dst error:NULL];
  BOOL wrote = [bin writeToFile:dst atomically:YES];
  [log appendFormat:@"  wrote converted copy: %d -> %@\n", wrote, dst];
  if (!wrote) return;

  dlerror();
  void *h = dlopen(dst.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  const char *err = dlerror();
  [log appendFormat:@"  dlopen -> %s\n", h ? "SUCCESS" : "failed"];
  [log appendFormat:@"  dlerror: %s\n", err ?: "(none)"];
  if (h) dlclose(h);
}

// libobjc's hook, not Foundation's. The assertion is thrown on
// CoreSimulator's dispatch queue and dies via
//   objc_exception_throw -> __cxa_throw -> std::__terminate -> _objc_terminate
// _objc_terminate consults the handler set by objc_setUncaughtExceptionHandler.
// NSSetUncaughtExceptionHandler installs FOUNDATION's, which only runs off
// UIApplication's run loop -- so it never fired for this crash at all.
static void probeObjcUncaughtHandler(id exception) {
  if ([exception isKindOfClass:[NSException class]]) {
    probeWriteExceptionCrumb((NSException *)exception);
  }
}

static void probeUncaughtExceptionHandler(NSException *ex) {
  // Same disk-only treatment; no pasteboard from a dying process.
  probeWriteExceptionCrumb(ex);
}

// Runs work on another queue and gives up waiting after `seconds`. A hang
// inside CoreSimulator can't be cancelled, but it can be survived: the
// blocked thread is simply abandoned (fine for a probe) while the run
// continues and reports WHICH call hung. Without this, one blocking call
// takes the entire run with it and produces a black screen and an empty
// clipboard -- exactly what the last build did.
static BOOL probeRunWithTimeout(NSTimeInterval seconds, void (^work)(void)) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    work();
    dispatch_semaphore_signal(done);
  });
  return dispatch_semaphore_wait(
             done, dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

// Only selectors that look like CoreSimulator's own get stubbed. Everything
// else is logged and left unresolved, which is what Foundation expects.
//
// This replaces a blanket "stub everything unknown" policy that was actively
// harmful: Foundation uses unresolved selectors as OPTIONAL HOOKS, so
// answering them changes real behavior. Two separate runs proved it --
// stubbing encodeWithOSLogCoder:options:maxLength: corrupted string
// formatting ("%@NSCONTEXT" instead of real paths), and answering
// bundleForClass (a hook +[NSBundle bundleForClass:] consults) recursed
// 12671 frames until the stack died.
//
// "Sim" as the test covers both categories actually found so far --
// sim_realPath and errorWithSimErrno:localizedDescription: -- and matches
// none of the Foundation hooks seen in any run.
static BOOL probeLooksLikeCoreSimulator(NSString *name) {
  // "simulator" lowercase is here because the capitalized-"Sim" test alone
  // missed +[NSUserDefaults simulatorDefaults]. Still specific enough to
  // match no Foundation hook seen in any run -- deliberately narrower than
  // a case-insensitive "sim", which would catch ordinary words.
  return [name hasPrefix:@"sim_"] || [name containsString:@"Sim"] ||
         [name containsString:@"simulator"];
}

// The selector hooks are installed process-wide, so this runs on WHATEVER
// thread happens to hit an unresolved selector -- and once the probe moved
// off the main thread, CoreSimulator's own queues made that genuinely
// concurrent. The previous version mutated a shared NSMutableArray and
// (via probePublish) read the shared log string with no synchronization at
// all, which is what crashed the run right after the hooks went in.
static void probeRecordMissing(NSString *description) {
  NSLock *lock = probeLock();
  // tryLock, never lock. These hooks are process-wide, so this runs on the
  // MAIN thread too -- UIKit's own os_log paths hit unresolved selectors
  // constantly. Blocking here stalled the main thread behind a lock another
  // thread held, and iOS watchdog-killed the app with 0x8BADF00D ("failed to
  // terminate gracefully after 5.0s"). Losing an occasional duplicate record
  // is a fine trade for never stalling the UI thread.
  if (![lock tryLock]) return;
  BOOL isNew = ![gMissingSelectors containsObject:description];
  if (isNew) [gMissingSelectors addObject:description];
  [lock unlock];
  // Deliberately does NOT publish. Publishing reads gLog, which belongs to
  // the probe thread; touching it from arbitrary threads is exactly the race
  // being fixed. flush() runs often enough on the probe thread that findings
  // still reach the clipboard promptly.
  // %s not %@: an object argument makes os_log flatten it, which probes for
  // description selectors, which re-enters selector resolution -- the exact
  // path in the watchdog backtrace.
  if (isNew) NSLog(@"[PROBE] missing selector: %s", [description UTF8String]);
}

// Formats WITHOUT %@ on purpose. The previous version used
// +[NSString stringWithFormat:@"-[%@ %@]", ...], and %@ makes Foundation
// probe its argument for description selectors -- that probe goes through
// selector RESOLUTION, which re-enters this very hook, which formats another
// %@... The device died with an 86-deep recursion between
// probeResolveInstanceMethod and __CFStringAppendFormatCore. snprintf with
// %s is pure C and touches no Objective-C machinery.
static NSString *probeDescribeSelector(char kind, Class cls, SEL sel) {
  char buf[512];
  snprintf(buf, sizeof(buf), "%c[%s %s]", kind, class_getName(cls), sel_getName(sel));
  NSString *result = [NSString stringWithUTF8String:buf];
  return result ?: @"(unprintable selector)";
}

// Belt and braces alongside the %@ fix: if anything inside this hook ever
// triggers selector resolution again, the nested call bails out immediately
// instead of recursing. Thread-local, since the hook runs on any thread.
static __thread int gProbeInResolver = 0;

// Master switch. The hooks can't be uninstalled (a method added to a class
// stays added), but they can be made inert. Left on for the whole app
// lifetime they keep intercepting every unresolved selector in the process
// -- including UIKit's, on the main thread -- long after the CoreSimulator
// work is done, which is pure risk for no information.
static BOOL gHooksEnabled = YES;

static BOOL probeResolveInstanceMethod(id self, SEL _cmd, SEL sel) {
  if (!gHooksEnabled) return NO;
  if (gProbeInResolver) return NO;
  gProbeInResolver++;

  NSString *name = NSStringFromSelector(sel);
  probeRecordMissing(probeDescribeSelector('-', (Class)self, sel));
  BOOL handled = probeLooksLikeCoreSimulator(name);
  if (handled) {
    class_addMethod((Class)self, sel, (IMP)probeMissingSelectorStub, "@@:");
  }
  gProbeInResolver--;
  return handled;
}

// Class methods resolve through a completely separate path
// (+resolveClassMethod:, not +resolveInstanceMethod:), which is why the
// instance-only hook saw nothing before +[NSError ...] aborted the process.
// Note the target of class_addMethod here is the METAclass -- that's where
// class methods live. Same %@-free formatting and re-entrancy guard as
// above, for the same reason.
static BOOL probeResolveClassMethod(id self, SEL _cmd, SEL sel) {
  if (!gHooksEnabled) return NO;
  if (gProbeInResolver) return NO;
  gProbeInResolver++;

  NSString *name = NSStringFromSelector(sel);
  probeRecordMissing(probeDescribeSelector('+', (Class)self, sel));

  // Unknown NSError factories get a real placeholder error rather than being
  // left unresolved: an unrecognized one aborts the process (uncatchable when
  // it happens on a dispatch queue), and a nil return just moves the crash.
  BOOL isErrorFactory = [NSStringFromClass((Class)self) isEqualToString:@"NSError"] &&
                        [name hasPrefix:@"errorWith"];
  if (isErrorFactory) {
    class_addMethod(object_getClass((Class)self), sel, (IMP)probeGenericErrorStub, "@@:");
    gProbeInResolver--;
    return YES;
  }

  BOOL handled = probeLooksLikeCoreSimulator(name);
  if (handled) {
    class_addMethod(object_getClass((Class)self), sel, (IMP)probeMissingSelectorStub, "@@:");
  }
  gProbeInResolver--;
  return handled;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
// The app's Documents folder has never actually been reachable through the
// Files app on this install (UIFileSharingEnabled doesn't survive however
// SideStore resigns this), so writing probe.log to disk, while still useful
// as a crash-survival record, is NOT a way to read results back. The
// pasteboard is: it needs no entitlement, no file browser, and no
// successful app launch beyond this point.
@property(strong, nonatomic) NSString *logText;
@property(strong, nonatomic) UIProgressView *progressBar;
@property(strong, nonatomic) UILabel *progressLabel;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  UIViewController *vc = [[UIViewController alloc] init];
  // systemBackgroundColor, not white: hardcoded white produced a bright band
  // behind the controls while the log rendered dark-mode.
  vc.view.backgroundColor = [UIColor systemBackgroundColor];

  // Compact layout. The controls had grown to 60pt-tall buttons stacked with
  // wide gaps, and the fetch button actually overlapped the bottom of the log
  // view -- the log is the thing worth reading, so the chrome shrinks and it
  // gets the space. Measured up from the bottom so nothing overlaps:
  //   log ... | label 12 | bar 3 | fetch 32 | copy 32 | 8pt inset
  // Safe areas are hardcoded because this runs before the window is laid out,
  // so vc.view.safeAreaInsets is still zero here. 50/34 covers the status bar
  // and home indicator on this hardware -- the screenshot showed controls
  // sitting under the indicator and the log running up under the clock.
  CGRect bounds = vc.view.bounds;
  const CGFloat topInset = 50, bottomInset = 34;
  const CGFloat pad = 8, btnH = 30, labelH = 12, barH = 3;
  const CGFloat copyY = bounds.size.height - bottomInset - btnH;
  const CGFloat fetchY = copyY - 4 - btnH;
  const CGFloat barY = fetchY - 6 - barH;
  const CGFloat labelY = barY - 2 - labelH;
  const CGFloat chromeTop = labelY - 4;

  UITextView *tv =
      [[UITextView alloc] initWithFrame:CGRectMake(0, topInset, bounds.size.width,
                                                   chromeTop - topInset)];
  tv.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.editable = NO;
  // Smaller than before: these logs run to hundreds of lines and fitting more
  // on screen beats legibility at arm's length.
  // 10pt at native resolution. The previous 9 was chosen while the app was
  // unknowingly letterboxed and scaling everything up; once UILaunchScreen
  // fixes that, the same number renders much smaller.
  tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  // Match the view instead of defaulting to white: the screenshot showed a
  // white band where the text view didn't reach, against dark log text.
  tv.backgroundColor = [UIColor systemBackgroundColor];
  tv.textColor = [UIColor labelColor];
  tv.textContainerInset = UIEdgeInsetsMake(4, 4, 4, 4);
  [vc.view addSubview:tv];

  UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
  copyButton.frame = CGRectMake(pad, copyY, bounds.size.width - 2 * pad, btnH);
  copyButton.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  copyButton.backgroundColor = [UIColor systemBlueColor];
  copyButton.tintColor = [UIColor whiteColor];
  copyButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
  copyButton.layer.cornerRadius = 6;
  [copyButton setTitle:@"COPY LOG" forState:UIControlStateNormal];
  [copyButton addTarget:self
                 action:@selector(copyLogTapped:)
       forControlEvents:UIControlEventTouchUpInside];
  [vc.view addSubview:copyButton];

  // Deliberately a button, not automatic. The full RuntimeRoot is several GB
  // compressed and ~16GB extracted; nothing that large should start on its
  // own just because the app launched.
  UIButton *fetchButton = [UIButton buttonWithType:UIButtonTypeSystem];
  fetchButton.frame = CGRectMake(pad, fetchY, bounds.size.width - 2 * pad, btnH);
  fetchButton.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  fetchButton.backgroundColor = [UIColor systemGreenColor];
  fetchButton.tintColor = [UIColor whiteColor];
  fetchButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
  fetchButton.layer.cornerRadius = 6;
  [fetchButton setTitle:@"DOWNLOAD RUNTIME" forState:UIControlStateNormal];
  [fetchButton addTarget:self
                  action:@selector(fetchRuntimeTapped:)
        forControlEvents:UIControlEventTouchUpInside];
  [vc.view addSubview:fetchButton];

  // Progress readout. A multi-GB download over a phone connection is a long
  // silence otherwise, with no way to tell "working" from "hung" -- and this
  // project has produced enough silent hangs to make that distinction worth
  // showing.
  UIProgressView *bar =
      [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  bar.frame = CGRectMake(pad, barY, bounds.size.width - 2 * pad, barH);
  bar.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  bar.progress = 0;
  [vc.view addSubview:bar];
  self.progressBar = bar;

  UILabel *progressLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(pad, labelY,
                                                bounds.size.width - 2 * pad, labelH)];
  progressLabel.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:9
                                                        weight:UIFontWeightRegular];
  progressLabel.textColor = [UIColor secondaryLabelColor];
  progressLabel.text = @"idle";
  [vc.view addSubview:progressLabel];
  self.progressLabel = progressLabel;

  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];

  NSString *docs = NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  NSString *logPath = [docs stringByAppendingPathComponent:@"probe.log"];

  // Written after every step, not just at the end -- if probe_run() crashes
  // the process, whatever got written before the crash is still on disk and
  // is itself the signal (same idea as the crash-log-as-spec approach, just
  // applied to a log file instead of a system crash report).
  NSMutableString *log = [NSMutableString string];
  gLog = log;
  gLogPath = logPath;
  gMissingSelectors = [NSMutableArray array];
  gMissingSelectorsPath = [docs stringByAppendingPathComponent:@"missing-selectors.txt"];
  // Publishes to the clipboard as well as to disk, on every single step --
  // the clipboard is the only channel that actually reaches us on this
  // install, and an abort inside a dispatch barrier can end the process at
  // any point without running anything at the end of launch.
  gTextView = tv;
  gExceptionCrumbPath = [docs stringByAppendingPathComponent:@"last-exception.txt"];
  gBootTracePath = [docs stringByAppendingPathComponent:@"boot-trace.txt"];
  // BOTH hooks: Foundation's for anything on the main run loop, and libobjc's
  // for the dispatch-queue terminations that killed device creation. Only the
  // latter fires for those, which is why nothing was captured before.
  NSSetUncaughtExceptionHandler(&probeUncaughtExceptionHandler);
  objc_setUncaughtExceptionHandler(&probeObjcUncaughtHandler);
  void (^flush)(void) = ^{
    probePublish();
  };

  // Everything below runs OFF the main thread. The previous build did all of
  // this synchronously inside didFinishLaunchingWithOptions, so when one
  // CoreSimulator call blocked forever the window never rendered (black
  // screen), the copy button never became usable, and nothing reached the
  // clipboard -- the run was unobservable. Returning YES promptly and doing
  // the work in the background keeps the UI live no matter what the
  // framework does.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

  // Surface anything the previous run died on, FIRST, before doing anything
  // that might crash again. This is the channel that finally works: the
  // crashing process writes a local file (which can't block), and the next
  // launch reads it out to the clipboard.
  NSString *crumb = [NSString stringWithContentsOfFile:gExceptionCrumbPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
  if (crumb.length) {
    [log appendString:@"=== PREVIOUS RUN DIED WITH ===\n"];
    [log appendString:crumb];
    [log appendString:@"=== end of previous-run exception ===\n\n"];
    [[NSFileManager defaultManager] removeItemAtPath:gExceptionCrumbPath error:nil];
  } else {
    [log appendString:@"(no exception recorded from a previous run)\n\n"];
  }

  // The boot trace is written line by line and flushed, so it survives the
  // abort that the exception crumb only records the end of. Read it out
  // alongside, then clear it so this run's trace starts empty.
  NSString *bootTrace = [NSString stringWithContentsOfFile:gBootTracePath
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
  if (bootTrace.length) {
    [log appendString:@"=== BOOT TRACE FROM THE PREVIOUS RUN ===\n"];
    [log appendString:bootTrace];
    [log appendString:@"=== end of previous-run boot trace ===\n\n"];
  }
  [[NSFileManager defaultManager] removeItemAtPath:gBootTracePath error:nil];
  flush();

  NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"target"
                                                           ofType:@"dylib"];
  [log appendFormat:@"target path: %@\n\n", bundlePath];
  flush();

  void *handle = dlopen([bundlePath fileSystemRepresentation], RTLD_NOW);
  if (!handle) {
    const char *err = dlerror();
    [log appendFormat:@"dlopen FAILED:\n%s\n", err ? err : "(no error string)"];
    flush();
  } else {
    [log appendString:@"dlopen SUCCEEDED (constructor already ran as part of "
                       @"the dlopen() call itself).\n\n"];
    flush();

    // Constructors run too early for UIKit to be safe to touch. probe_run()
    // is a normal exported function instead, looked up explicitly and
    // called now that the app has actually finished launching.
    void *sym = dlsym(handle, "probe_run");
    if (!sym) {
      const char *err = dlerror();
      [log appendFormat:@"dlsym(\"probe_run\") FAILED:\n%s\n", err ? err : "(no error string)"];
      flush();
    } else {
      [log appendString:@"dlsym(\"probe_run\") found it -- calling now.\n"
                         @"(if this app doesn't get past this line, it crashed "
                         @"inside probe_run -- that crash is itself the signal)\n"];
      flush();

      void (*probe_run)(void) = (void (*)(void))sym;
      probe_run();

      [log appendString:@"\nprobe_run() returned without crashing.\n"];
      flush();
    }
  }

  // Skipped now that the probe runs off the main thread. NSExtension's launch
  // path expects the main thread, and this test has already passed repeatedly
  // (real separate PIDs, all four Darwin checkpoints) -- keeping it here would
  // risk a background-thread hang in already-proven code and add ~15 lines to
  // a log that has to be pasted by hand. Flip to YES to re-run it.
  static const BOOL kRunExtensionTest = NO;
  if (kRunExtensionTest) {
  [log appendString:@"\n=== Now triggering LaunchHelper as a separate process ===\n"];

  NSURL *plugInsURL = [[NSBundle mainBundle] builtInPlugInsURL];
  [log appendFormat:@"builtInPlugInsURL: %@\n", plugInsURL];
  NSArray<NSURL *> *plugInContents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtURL:plugInsURL
                                     includingPropertiesForKeys:nil
                                                        options:0
                                                          error:nil];
  [log appendFormat:@"PlugIns/ contents on disk: %@\n", plugInContents];
  // Read the identifier back from the actual installed .appex's own
  // Info.plist rather than hardcoding it -- AltStore's resigning process
  // inserts an extra identifier segment (confirmed: it turned
  // "dev.local.ios18probe.LaunchHelper" into
  // "dev.local.ios18probe.<TEAM-ISH-ID>.LaunchHelper" on install), so a
  // literal string here would never match what's actually registered.
  NSString *installedExtensionId = nil;
  if (plugInContents.count > 0) {
    NSURL *appexURL = plugInContents.firstObject;
    NSURL *appexInfoPlist = [appexURL URLByAppendingPathComponent:@"Info.plist"];
    NSDictionary *appexInfo = [NSDictionary dictionaryWithContentsOfURL:appexInfoPlist];
    installedExtensionId = appexInfo[@"CFBundleIdentifier"];
    [log appendFormat:@"first .appex's CFBundleIdentifier as installed: %@\n",
                       installedExtensionId];
  }
  flush();

  NSError *extError = nil;
  NSExtension *ext = installedExtensionId
      ? [NSExtension extensionWithIdentifier:installedExtensionId error:&extError]
      : nil;
  if (!ext) {
    [log appendFormat:@"NSExtension init FAILED: %@\n", extError];
    flush();
  } else {
    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    NSArray<NSString *> *names = @[
      @"dev.local.ios18probe.LaunchHelper.started",
      @"dev.local.ios18probe.LaunchHelper.dlopenDone",
      @"dev.local.ios18probe.LaunchHelper.probeRunDone",
      @"dev.local.ios18probe.LaunchHelper.reachedEnd",
    ];
    for (NSString *n in names) {
      CFNotificationCenterAddObserver(
          darwinCenter, NULL, darwinCallback, (__bridge CFStringRef)n, NULL,
          CFNotificationSuspensionBehaviorDeliverImmediately);
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *outcome = nil;

    [ext setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
      outcome = [NSString stringWithFormat:
                              @"CANCELLED (likely crashed): %@", error];
      dispatch_semaphore_signal(sema);
    }];

    NSExtensionItem *item = [NSExtensionItem new];
    [ext beginExtensionRequestWithInputItems:@[ item ]
                                   completion:^(NSUUID *identifier) {
      if (identifier) {
        int pid = [ext pidForRequestIdentifier:identifier];
        outcome = [NSString stringWithFormat:
                                @"LAUNCHED as a real separate process. "
                                @"uuid=%@ pid=%d", identifier, pid];
      } else {
        outcome = @"FAILED: beginExtensionRequestWithInputItems returned nil identifier";
      }
      dispatch_semaphore_signal(sema);
    }];

    long timedOut = dispatch_semaphore_wait(
        sema, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (timedOut) {
      [log appendString:@"TIMED OUT waiting 20s for extension launch result\n"];
    } else {
      [log appendFormat:@"%@\n", outcome];
    }
    flush();

    // The completion block above fires once the process is launched and
    // connected, not necessarily once its own beginRequestWithExtensionContext:
    // work (dlopen + probe_run) has finished. Actually pump the run loop
    // (not a blind sleep) so queued Darwin notification callbacks get a
    // chance to fire, up to 5s or until we've seen the final checkpoint.
    CFTimeInterval deadline = CFAbsoluteTimeGetCurrent() + 5.0;
    while (CFAbsoluteTimeGetCurrent() < deadline && !gReachedEnd) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    }
    [log appendFormat:@"\nDarwin notification checkpoints seen: started=%d "
                       @"dlopenDone=%d probeRunDone=%d reachedEnd=%d\n",
                       gStarted, gDlopenDone, gProbeRunDone, gReachedEnd];
    flush();

    for (NSString *n in names) {
      CFNotificationCenterRemoveObserver(darwinCenter, NULL,
                                          (__bridge CFStringRef)n, NULL);
    }

    NSURL *groupURL = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:@"group.dev.local.ios18probe"];
    [log appendFormat:@"\nApp Group container (Probe's view): %@\n", groupURL];
    if (groupURL) {
      NSURL *sharedLogURL =
          [groupURL URLByAppendingPathComponent:@"launchhelper.log"];
      NSString *helperLog = [NSString stringWithContentsOfURL:sharedLogURL
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
      if (helperLog) {
        [log appendFormat:@"\n--- LaunchHelper's own log, read back via the "
                           @"shared App Group container ---\n%@\n"
                           @"--- end of LaunchHelper's log ---\n",
                           helperLog];
      } else {
        [log appendString:@"\nNo shared log found (App Group entitlement "
                           @"may not have carried through resigning, or "
                           @"LaunchHelper hasn't written anything yet)\n"];
      }
    }
    flush();
  }

  }  // end kRunExtensionTest

  [log appendString:@"\n=== Now attempting the real, patched CoreSimulator ===\n"];
  flush();

  // Load CoreSimulator from its framework BUNDLE rather than the loose dylib.
  // Boot reached -[SimDeviceIOServer loadAllBundlesWithError:], which resolves
  // [NSBundle bundleWithIdentifier:@"com.apple.CoreSimulator"] to locate its
  // own framework and load device-IO plugins from it, and threw "Failed to
  // find bundle with identifier" because a bare dylib belongs to no bundle.
  //
  // Instantiating the NSBundle is what registers it in Foundation's table, so
  // bundleWithIdentifier: can find it afterwards -- dlopen alone does not do
  // that. The loose dylib remains as a fallback in case the framework is
  // missing from an older build.
  NSString *frameworkPath = [[[NSBundle mainBundle] bundlePath]
      stringByAppendingPathComponent:@"Frameworks/CoreSimulator.framework"];
  NSString *coresimPath = nil;
  if ([[NSFileManager defaultManager] fileExistsAtPath:frameworkPath]) {
    NSBundle *csBundle = [NSBundle bundleWithPath:frameworkPath];
    [log appendFormat:@"CoreSimulator.framework: %@\n  identifier=%@\n",
                       frameworkPath, csBundle.bundleIdentifier];
    coresimPath = [frameworkPath stringByAppendingPathComponent:@"CoreSimulator"];
    NSBundle *found = [NSBundle bundleWithIdentifier:@"com.apple.CoreSimulator"];
    [log appendFormat:@"  bundleWithIdentifier lookup before load: %@\n",
                       found ? @"FOUND" : @"not yet (expected until loaded)"];
  } else {
    coresimPath = [[NSBundle mainBundle] pathForResource:@"coresim_target"
                                                  ofType:@"dylib"];
    [log appendString:@"(no CoreSimulator.framework -- using the loose dylib)\n"];
  }
  [log appendFormat:@"coresim_target path: %@\n", coresimPath];
  flush();

  void *coresimHandle = dlopen([coresimPath fileSystemRepresentation], RTLD_NOW);
  if (!coresimHandle) {
    const char *err = dlerror();
    [log appendFormat:@"dlopen FAILED:\n%s\n", err ? err : "(no error string)"];
    flush();
  } else {
    [log appendString:@"dlopen SUCCEEDED -- CoreSimulator's real binary "
                       @"loaded and fully linked on iOS.\n"];
    // Confirm the identifier resolves NOW that the image is loaded -- this is
    // the exact lookup loadAllBundlesWithError: performs during boot.
    NSBundle *idLookup = [NSBundle bundleWithIdentifier:@"com.apple.CoreSimulator"];
    [log appendFormat:@"bundleWithIdentifier:com.apple.CoreSimulator -> %@\n",
                       idLookup ? idLookup.bundlePath : @"STILL NOT FOUND"];

    // Ask exactly what loadAllBundlesWithError: asks. It fails with "Failed to
    // retrieve paths for simdeviceio bundles" even though the six .simdeviceio
    // bundles are now inside the framework, and ".simdeviceio" is the only
    // relevant string in the binary -- so it's resolving them through NSBundle
    // resource lookup. Reproducing that lookup here shows whether the problem
    // is the layout (flat vs Versions/A/Resources), the resourcePath, or
    // something else entirely, without another disassembly round.
    if (idLookup) {
      [log appendFormat:@"  bundlePath:   %@\n  resourcePath: %@\n",
                         idLookup.bundlePath, idLookup.resourcePath];
      NSArray *urls = [idLookup URLsForResourcesWithExtension:@"simdeviceio"
                                                subdirectory:nil];
      [log appendFormat:@"  URLsForResourcesWithExtension:@\"simdeviceio\" -> %lu\n",
                         (unsigned long)urls.count];
      for (NSURL *u in urls) [log appendFormat:@"    %@\n", u.lastPathComponent];

      // Same query against the alternative layouts, to identify which one it
      // actually wants if the flat one comes back empty.
      for (NSString *sub in @[ @"Resources", @"Versions/A/Resources" ]) {
        NSArray *subUrls = [idLookup URLsForResourcesWithExtension:@"simdeviceio"
                                                     subdirectory:sub];
        [log appendFormat:@"  subdirectory:%@ -> %lu\n", sub,
                           (unsigned long)subUrls.count];
      }

      NSArray *onDisk = [[NSFileManager defaultManager]
          contentsOfDirectoryAtPath:idLookup.bundlePath error:NULL];
      [log appendFormat:@"  actually on disk in the framework: %@\n",
                         [onDisk componentsJoinedByString:@" "]];
    }
    flush();

    // Loaded successfully, but nothing has actually been *called* yet.
    // Rather than guess selector names from macOS-only tooling we don't
    // have, ask the Objective-C runtime directly what classes and methods
    // this image really defines -- ground truth from the actual loaded
    // binary, not reverse-engineered.
    [log appendString:@"\n=== Introspecting CoreSimulator's real "
                       @"Objective-C class surface ===\n"];
    flush();

    unsigned int imgClassCount = 0;
    const char *imageName = [coresimPath fileSystemRepresentation];
    const char **classNames = objc_copyClassNamesForImage(imageName, &imgClassCount);
    [log appendFormat:@"objc_copyClassNamesForImage(%s) -> %u classes\n",
                       imageName, imgClassCount];
    NSMutableArray<NSString *> *allClassNames = [NSMutableArray array];
    for (unsigned int i = 0; i < imgClassCount; i++) {
      [allClassNames addObject:[NSString stringWithUTF8String:classNames[i]]];
    }
    if (classNames) free(classNames);
    [allClassNames sortUsingSelector:@selector(compare:)];
    [log appendFormat:@"%@\n", [allClassNames componentsJoinedByString:@"\n"]];
    flush();

    // Well-known top-level entry-point class names from prior public
    // reverse-engineering of simctl/Xcode's use of CoreSimulator, plus
    // anything the enumeration above found with "ServiceContext" in the
    // name -- checked independently via NSClassFromString so this still
    // works even if objc_copyClassNamesForImage's image-name matching
    // above found nothing.
    NSMutableArray<NSString *> *toIntrospect = [NSMutableArray arrayWithArray:@[
      @"SimServiceContext", @"SimDeviceSet", @"SimDevice", @"SimRuntime",
      @"SimDeviceType"
    ]];
    for (NSString *name in allClassNames) {
      if ([name rangeOfString:@"ServiceContext"].location != NSNotFound &&
          ![toIntrospect containsObject:name]) {
        [toIntrospect addObject:name];
      }
    }

    // The full method dump is ~600 lines and has to be pasted by hand every
    // run. It already did its job -- it's what revealed
    // serviceContextForDeveloperDir:connectionType:error: and
    // standaloneConnectionWithError:. Flip to YES if a new class needs
    // exploring.
    static const BOOL kDumpMethodLists = NO;
    // SimHostResourceChecker is dumped regardless: boot now fails ONLY on its
    // pre-flight verdict ("maxUserProcs: 1 ... enforcedProcBuffer: 100"), so
    // its method surface is the next thing worth reading.
    NSArray *dumpList = kDumpMethodLists ? toIntrospect : @[ @"SimHostResourceChecker" ];
    [log appendString:@"\n--- method lists for candidate entry-point classes ---\n"];
    for (NSString *className in dumpList) {
      Class cls = NSClassFromString(className);
      if (!cls) {
        [log appendFormat:@"\n%@: NOT FOUND\n", className];
        continue;
      }
      [log appendFormat:@"\n%@:\n", className];

      unsigned int classMethodCount = 0;
      Method *classMethods = class_copyMethodList(object_getClass(cls), &classMethodCount);
      for (unsigned int i = 0; i < classMethodCount; i++) {
        [log appendFormat:@"  + %@\n", NSStringFromSelector(method_getName(classMethods[i]))];
      }
      if (classMethods) free(classMethods);

      unsigned int instMethodCount = 0;
      Method *instMethods = class_copyMethodList(cls, &instMethodCount);
      for (unsigned int i = 0; i < instMethodCount; i++) {
        [log appendFormat:@"  - %@\n", NSStringFromSelector(method_getName(instMethods[i]))];
      }
      if (instMethods) free(instMethods);
    }
    flush();

    // Now actually call into it. No compile-time headers for these private
    // classes, so dispatch is via objc_msgSend cast to the real signature
    // (arm64's ABI needs no separate _stret/_fpret variant, unlike i386/
    // x86_64 -- a plain cast is correct here for all three return types
    // below). Lowest-risk calls first (no IPC, pure introspection), then
    // the real bootstrap entry point known from prior public
    // reverse-engineering of simctl/Xcode's use of CoreSimulator. Whatever
    // it does -- graceful NSError, hang, or crash -- is the next real
    // signal; nothing downstream of it (loadCoreSimulatorServiceWithError:,
    // an XPC connection to the com.apple.CoreSimulator.CoreSimulatorService
    // mach service) has any equivalent on iOS, so this is deliberately not
    // routed around.
    [log appendString:@"\n=== Calling into CoreSimulator's real API ===\n"];
    flush();

    // (globals already initialized at the top of launch, before anything
    // could record into them -- re-initializing here would discard whatever
    // was discovered earlier in the run)
    // Installed on the concrete constant-string class (the actual receiver
    // in the last crash) and on NSString itself, which covers the rest of
    // the cluster's private subclasses by inheritance. class_addMethod only
    // fails if the class implements this *itself* (not inherited), which
    // these don't -- so no risk of clobbering NSObject's global version.
    // Both hook kinds, across the Foundation classes CoreSimulator is most
    // likely to have categories on. class_addMethod only fails if the class
    // implements the resolver *itself* (not inherited), in which case we
    // leave it alone rather than clobbering real dynamic-resolution logic.
    for (NSString *clsName in @[
           @"__NSCFConstantString", @"NSString", @"NSError", @"NSDictionary",
           @"NSArray", @"NSURL", @"NSFileManager", @"NSBundle", @"NSData",
           @"NSProcessInfo", @"NSNumber", @"NSUserDefaults", @"NSDate",
           @"NSUUID", @"NSSet"
         ]) {
      Class cls = NSClassFromString(clsName);
      if (!cls) continue;
      Class meta = object_getClass(cls);
      BOOL inst = class_addMethod(meta, @selector(resolveInstanceMethod:),
                                   (IMP)probeResolveInstanceMethod, "B@::");
      BOOL clsm = class_addMethod(meta, @selector(resolveClassMethod:),
                                   (IMP)probeResolveClassMethod, "B@::");
      [log appendFormat:@"hooks on %@: instance=%@ class=%@\n", clsName,
                         inst ? @"yes" : @"no", clsm ? @"yes" : @"no"];
    }
    flush();

    Class serviceContextClass = NSClassFromString(@"SimServiceContext");
    if (!serviceContextClass) {
      [log appendString:@"SimServiceContext class not found (unexpected -- "
                         @"it was in the introspection dump above)\n"];
      flush();
    } else {
      typedef NSString *(*StringClassMsg)(Class, SEL);
      StringClassMsg stringMsg = (StringClassMsg)objc_msgSend;
      NSString *serviceVersion = stringMsg(serviceContextClass, @selector(serviceVersionString));
      [log appendFormat:@"+[SimServiceContext serviceVersionString] = %@\n", serviceVersion];
      flush();

      typedef BOOL (*BoolClassMsg)(Class, SEL);
      BoolClassMsg boolMsg = (BoolClassMsg)objc_msgSend;
      BOOL isServer = boolMsg(serviceContextClass, @selector(currentProcessIsServer));
      [log appendFormat:@"+[SimServiceContext currentProcessIsServer] = %d\n", isServer];
      flush();

      [log appendString:@"\nCalling +[SimServiceContext "
                         @"sharedServiceContextForDeveloperDir:error:] ...\n"];
      flush();

      // Last build died here with an uncaught NSInvalidArgumentException:
      // CoreSimulator's real initWithDeveloperDir:connectionType:error: sent
      // an unrecognized selector to the __NSCFConstantString we passed as
      // the developer dir. The crash report REDACTS the selector name (shows
      // "%s"), but it's a plain catchable ObjC exception, so catching it here
      // gets us the real name at runtime -- and keeps the app alive so the
      // log actually reaches disk in a readable state.
      //
      // Worth noting why symbol recon never predicted this: ObjC category
      // methods aren't linker symbols. [str someCategoryMethod] compiles to
      // a generic objc_msgSend with a selector name, so `nm` can't see it.
      // Every dependency found so far was linker-visible; this class of gap
      // is invisible until the code actually runs.
      // Last run passed /Applications/Xcode.app/Contents/Developer, which
      // obviously doesn't exist on iOS -- sim_realPath (now implemented for
      // real in the CoreSimulatorUtilities stub) correctly returns nil for a
      // nonexistent path, so that alone would still throw. Give it a real
      // directory inside our own sandbox instead. Empty for now: whatever
      // CoreSimulator looks for underneath is the next thing to learn.
      NSString *developerDir = [docs stringByAppendingPathComponent:@"DeveloperDir"];
      NSError *mkdirError = nil;
      [[NSFileManager defaultManager]
          createDirectoryAtPath:[developerDir stringByAppendingPathComponent:@"Platforms"]
        withIntermediateDirectories:YES
                     attributes:nil
                          error:&mkdirError];
      [log appendFormat:@"developer dir: %@\n  exists=%d  mkdirError=%@\n",
                         developerDir,
                         [[NSFileManager defaultManager] fileExistsAtPath:developerDir],
                         mkdirError];
      flush();

      @try {
        typedef id (*SharedServiceContextMsg)(Class, SEL, NSString *, NSError **);
        SharedServiceContextMsg sharedMsg = (SharedServiceContextMsg)objc_msgSend;
        NSError *serviceError = nil;
        id serviceContext = sharedMsg(
            serviceContextClass,
            @selector(sharedServiceContextForDeveloperDir:error:),
            developerDir, &serviceError);
        [log appendFormat:@"result: %@\nerror: %@\n", serviceContext, serviceError];
        flush();
      } @catch (NSException *ex) {
        [log appendFormat:@"\nEXCEPTION CAUGHT (this is the useful part):\n"
                           @"  name:   %@\n"
                           @"  reason: %@\n",
                           ex.name, ex.reason];
        [log appendFormat:@"  backtrace:\n%@\n",
                           [ex.callStackSymbols componentsJoinedByString:@"\n"]];
        flush();
      }

      [log appendFormat:@"\n--- selectors CoreSimulator wanted but iOS doesn't "
                         @"have (%lu found) ---\n%@\n",
                         (unsigned long)gMissingSelectors.count,
                         gMissingSelectors.count
                             ? [gMissingSelectors componentsJoinedByString:@"\n"]
                             : @"(none)"];
      flush();

      // sharedServiceContextForDeveloperDir:error: hardcodes the daemon path,
      // and failed exactly there: SimError 61, service version (null) vs its
      // own 993.7, because no CoreSimulatorService exists on iOS to answer
      // the handshake.
      //
      // But the introspection dump shows that isn't the only path -- there's
      // a connectionType parameter and a separate standalone entry point:
      //   + serviceContextForDeveloperDir:connectionType:error:
      //   + standaloneConnectionWithError:
      //   + currentProcessIsServer          (already returns 0 for us)
      // If any connection type runs the service IN-PROCESS, the missing
      // daemon stops mattering, which would be a route around the wall
      // rather than an attempt to fake what's behind it.
      //
      // Which integer means what isn't publicly documented, so rather than
      // guess one, try them all and let the device say. Each attempt is
      // logged and flushed BEFORE it runs: an abort inside a dispatch
      // barrier can't be caught, so if one of these kills the process, the
      // last line on the clipboard identifies exactly which.
      [log appendString:@"\n=== Trying non-daemon connection paths ===\n"];
      flush();

      __block id liveContext = nil;
      typedef id (*ConnTypeMsg)(Class, SEL, NSString *, NSUInteger, NSError **);
      ConnTypeMsg connMsg = (ConnTypeMsg)objc_msgSend;
      for (NSUInteger connectionType = 0; connectionType <= 3; connectionType++) {
        [log appendFormat:@"\nserviceContextForDeveloperDir:connectionType:%lu:error: (25s limit)...\n",
                           (unsigned long)connectionType];
        flush();
        __block NSString *connOutcome = @"(did not finish)";
        __block id ctx = nil;
        BOOL connFinished = probeRunWithTimeout(25.0, ^{
        @try {
          NSError *connError = nil;
          ctx = connMsg(serviceContextClass,
                           @selector(serviceContextForDeveloperDir:connectionType:error:),
                           developerDir, connectionType, &connError);
          connOutcome = [NSString stringWithFormat:@"result: %@\n  error: %@", ctx, connError];
          if (ctx) {
            if (!liveContext) liveContext = ctx;
            // A live context means the daemon was bypassed. Ask it something
            // that requires real internal state, not just a non-nil pointer.
            typedef id (*IdMsg)(id, SEL);
            IdMsg idMsg = (IdMsg)objc_msgSend;
            connOutcome = [connOutcome stringByAppendingFormat:
                @"\n  CONTEXT OBTAINED. developerDir=%@\n  supportedRuntimes=%@\n"
                @"  supportedDeviceTypes=%@",
                idMsg(ctx, @selector(developerDir)),
                idMsg(ctx, @selector(supportedRuntimes)),
                idMsg(ctx, @selector(supportedDeviceTypes))];
          }
        } @catch (NSException *ex) {
          connOutcome = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
        }
        });
        [log appendFormat:@"  %@\n  %@\n",
                           connFinished ? @"returned"
                                        : @"*** TIMED OUT -- THIS CALL HANGS ***",
                           connOutcome];
        flush();
      }

      [log appendString:@"\n+[SimServiceContext standaloneConnectionWithError:] ...\n"];
      flush();
      @try {
        typedef id (*StandaloneMsg)(Class, SEL, NSError **);
        StandaloneMsg standaloneMsg = (StandaloneMsg)objc_msgSend;
        NSError *standaloneError = nil;
        id standalone = standaloneMsg(serviceContextClass,
                                       @selector(standaloneConnectionWithError:),
                                       &standaloneError);
        [log appendFormat:@"  result: %@\n  error: %@\n", standalone, standaloneError];
      } @catch (NSException *ex) {
        [log appendFormat:@"  EXCEPTION: %@ -- %@\n", ex.name, ex.reason];
      }
      flush();

      // A live context reports supportedDeviceTypes/supportedRuntimes as
      // empty ARRAYS (not nil, not an error) because the developer dir we
      // handed it is empty -- it has nowhere to find profiles. The context
      // exposes methods to be fed some:
      //   - supportedDeviceTypesAddProfilesAtPath:
      //   - supportedRuntimesAddProfilesAtPath:createDefaultDevicesIfNeeded:
      // so build a .simdevicetype bundle and hand it over.
      //
      // Neither the profile.plist schema nor the expected bundle layout is
      // documented. The keys below are the ones real .simdevicetype profiles
      // carry; the layout is genuinely uncertain, since CoreSimulator is
      // macOS code (Contents/Resources/...) running on iOS, where bundles are
      // normally flat. Rather than pick one, build both and see which the
      // framework accepts -- non-empty supportedDeviceTypes is the answer.
      if (liveContext) {
        [log appendString:@"\n=== Feeding it a synthetic device-type profile ===\n"];
        flush();

        // First, the genuine article: a real Apple .simdevicetype staged into
        // the app bundle by CI. No schema guessing at all.
        NSString *realProfiles = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"RealProfiles/DeviceTypes"];
        [log appendFormat:@"\nreal profiles dir: %@\n  contents: %@\n", realProfiles,
                           [[NSFileManager defaultManager] contentsOfDirectoryAtPath:realProfiles
                                                                               error:nil]];
        flush();
        // Prime suspect for the hang that produced a black screen: this is
        // the first call that makes CoreSimulator go scan a directory, and
        // its profile-loading machinery has queues and file-system monitors
        // behind it. Bounded so a hang is a reported result, not the end of
        // the run.
        [log appendString:@"  calling supportedDeviceTypesAddProfilesAtPath: (30s limit)...\n"];
        flush();
        __block NSString *realOutcome = @"(did not finish)";
        BOOL finished = probeRunWithTimeout(30.0, ^{
          @try {
            typedef id (*PathMsg)(id, SEL, NSString *);
            PathMsg pathMsg = (PathMsg)objc_msgSend;
            pathMsg(liveContext, @selector(supportedDeviceTypesAddProfilesAtPath:),
                    realProfiles);
            typedef id (*IdMsg)(id, SEL);
            IdMsg idMsg = (IdMsg)objc_msgSend;
            id types = idMsg(liveContext, @selector(supportedDeviceTypes));
            realOutcome = [NSString stringWithFormat:@"supportedDeviceTypes: %@", types];
            if ([types respondsToSelector:@selector(count)] && [types count] > 0) {
              realOutcome = [realOutcome
                  stringByAppendingString:@"\n  *** REAL DEVICE TYPE REGISTERED ***"];
            }
          } @catch (NSException *ex) {
            realOutcome = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
          }
        });
        [log appendFormat:@"  %@\n  %@\n",
                           finished ? @"returned" : @"*** TIMED OUT -- THIS CALL HANGS ***",
                           realOutcome];
        flush();

        // Schema corrected against the real profile.plist dumped from the CI
        // runner. The original guesses were wrong in ways that would have
        // failed silently: sizes are separate top-level STRINGS rather than a
        // size dict, DPI is split per-axis, scale and minRuntimeVersion are
        // strings not numbers, supportedProductFamilyIDs capitalizes "IDs",
        // supportedFeatures is a dict not an array, and there are no name or
        // identifier keys at all -- those come from Info.plist.
        NSDictionary *profile = @{
          @"modelIdentifier" : @"iPhone14,7",
          @"productClass" : @"D16",
          @"supportedProductFamilyIDs" : @[ @1 ],
          @"supportedArchs" : @[ @"arm64", @"arm64e" ],
          @"mainScreenWidth" : @"1170",
          @"mainScreenHeight" : @"2532",
          @"mainScreenWidthDPI" : @460,
          @"mainScreenHeightDPI" : @460,
          @"mainScreenScale" : @"3.0",
          @"minRuntimeVersion" : @"16.1",
          @"createByDefaultForRuntimeVersions" :
              @{@"versionMin" : @"16.1", @"versionMax" : @"99.99"},
          @"supportedFeatures" : @{},
          @"supportedFeaturesConditionalOnRuntime" : @{},
          @"environment" : @{},
        };
        NSDictionary *infoPlist = @{
          @"CFBundleIdentifier" : @"com.apple.CoreSimulator.SimDeviceType.Probe-Test-Device",
          @"CFBundleName" : @"Probe Test Device",
          @"CFBundlePackageType" : @"BNDL",
          @"CFBundleShortVersionString" : @"1.0",
          @"CFBundleVersion" : @"1",
          @"CFBundleInfoDictionaryVersion" : @"6.0",
          @"CFBundleDevelopmentRegion" : @"English",
        };

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *layout in @[ @"macOS-style", @"flat" ]) {
          BOOL macStyle = [layout isEqualToString:@"macOS-style"];
          NSString *root = [docs stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"Profiles-%@", layout]];
          NSString *deviceTypesDir = [root stringByAppendingPathComponent:@"DeviceTypes"];
          NSString *bundle = [deviceTypesDir
              stringByAppendingPathComponent:@"ProbeTestDevice.simdevicetype"];
          NSString *infoDir = macStyle ? [bundle stringByAppendingPathComponent:@"Contents"]
                                       : bundle;
          NSString *resourcesDir =
              macStyle ? [infoDir stringByAppendingPathComponent:@"Resources"] : bundle;

          [fm removeItemAtPath:root error:nil];
          [fm createDirectoryAtPath:resourcesDir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
          BOOL wroteInfo = [infoPlist writeToFile:[infoDir stringByAppendingPathComponent:@"Info.plist"]
                                       atomically:YES];
          BOOL wroteProfile =
              [profile writeToFile:[resourcesDir stringByAppendingPathComponent:@"profile.plist"]
                        atomically:YES];

          [log appendFormat:@"\n[%@] bundle=%@\n  wroteInfo=%d wroteProfile=%d\n",
                             layout, bundle, wroteInfo, wroteProfile];
          flush();

          __block NSString *outcome = @"(did not finish)";
          BOOL ok = probeRunWithTimeout(20.0, ^{
            @try {
              typedef id (*PathMsg)(id, SEL, NSString *);
              PathMsg pathMsg = (PathMsg)objc_msgSend;
              pathMsg(liveContext, @selector(supportedDeviceTypesAddProfilesAtPath:),
                      deviceTypesDir);

              typedef id (*IdMsg)(id, SEL);
              IdMsg idMsg = (IdMsg)objc_msgSend;
              id types = idMsg(liveContext, @selector(supportedDeviceTypes));
              outcome = [NSString stringWithFormat:@"supportedDeviceTypes now: %@", types];
              if ([types respondsToSelector:@selector(count)] && [types count] > 0) {
                outcome = [outcome stringByAppendingFormat:
                                       @"\n  *** DEVICE TYPE REGISTERED (%@ layout) ***", layout];
              }
            } @catch (NSException *ex) {
              outcome = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
            }
          });
          [log appendFormat:@"  %@\n  %@\n",
                             ok ? @"returned" : @"*** TIMED OUT -- THIS CALL HANGS ***",
                             outcome];
          flush();
        }

        // The pivotal runtime test. A metadata-only .simruntime (Info.plist +
        // profile.plist, no 16GB RuntimeRoot) is staged in the app by CI.
        // Register it and see (a) whether CoreSimulator accepts a runtime at
        // all, and (b) what it reports about availability -- isAvailableWithError:
        // should name exactly what's missing, which scopes the whole download
        // effort before any gigabytes are fetched.
        NSString *runtimesDir = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"RealProfiles/Runtimes"];
        [log appendFormat:@"\n=== Registering metadata-only runtime ===\n"
                           @"runtimes dir: %@\n  contents: %@\n", runtimesDir,
                           [[NSFileManager defaultManager] contentsOfDirectoryAtPath:runtimesDir
                                                                               error:nil]];
        flush();

        __block NSString *rtOutcome = @"(did not finish)";
        BOOL rtOk = probeRunWithTimeout(30.0, ^{
          @try {
            typedef void (*RtPathMsg)(id, SEL, NSString *, BOOL);
            RtPathMsg rtMsg = (RtPathMsg)objc_msgSend;
            rtMsg(liveContext,
                  @selector(supportedRuntimesAddProfilesAtPath:createDefaultDevicesIfNeeded:),
                  runtimesDir, NO);

            typedef id (*IdMsg)(id, SEL);
            IdMsg idMsg = (IdMsg)objc_msgSend;
            id runtimes = idMsg(liveContext, @selector(supportedRuntimes));
            rtOutcome = [NSString stringWithFormat:@"supportedRuntimes now: %@", runtimes];

            if ([runtimes respondsToSelector:@selector(count)] && [runtimes count] > 0) {
              rtOutcome = [rtOutcome stringByAppendingString:
                               @"\n  *** RUNTIME REGISTERED ***"];
              // Ask each one whether it's available and, if not, why -- that
              // error is the real map of what the RuntimeRoot download has to
              // satisfy.
              for (id rt in runtimes) {
                typedef BOOL (*AvailMsg)(id, SEL, NSError **);
                AvailMsg availMsg = (AvailMsg)objc_msgSend;
                NSError *availErr = nil;
                BOOL avail = availMsg(rt, @selector(isAvailableWithError:), &availErr);
                rtOutcome = [rtOutcome stringByAppendingFormat:
                    @"\n  runtime %@\n    available=%d\n    whyNot=%@",
                    idMsg(rt, @selector(name)), avail, availErr];
              }
            }
          } @catch (NSException *ex) {
            rtOutcome = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
          }
        });
        [log appendFormat:@"  %@\n  %@\n",
                           rtOk ? @"returned" : @"*** TIMED OUT -- THIS CALL HANGS ***",
                           rtOutcome];
        flush();

        // The add path above returns void and silently drops any runtime it
        // considers invalid -- which it did (supportedRuntimes stayed empty)
        // without saying why. -[SimRuntime initWithBundle:error:] is the same
        // validation the add path calls internally, but it hands the NSError
        // back instead of swallowing it. So instantiate SimRuntime directly
        // against the staged bundle to get the actual rejection reason -- that
        // reason is the real requirement list for the RuntimeRoot download.
        [log appendString:@"\n=== Instantiating SimRuntime directly for the real error ===\n"];
        flush();
        Class simRuntimeClass = NSClassFromString(@"SimRuntime");
        NSString *rtBundlePath =
            [runtimesDir stringByAppendingPathComponent:@"iOS 17.2.simruntime"];
        [log appendFormat:@"SimRuntime class=%@  bundle exists=%d\n",
                           simRuntimeClass,
                           [[NSFileManager defaultManager] fileExistsAtPath:rtBundlePath]];
        flush();

        __block NSString *initOutcome = @"(did not finish)";
        BOOL initOk = probeRunWithTimeout(30.0, ^{
          @try {
            NSBundle *rtBundle = [NSBundle bundleWithPath:rtBundlePath];
            typedef id (*AllocMsg)(Class, SEL);
            AllocMsg allocMsg = (AllocMsg)objc_msgSend;
            id rtAlloc = allocMsg(simRuntimeClass, @selector(alloc));

            typedef id (*InitBundleMsg)(id, SEL, NSBundle *, NSError **);
            InitBundleMsg initMsg = (InitBundleMsg)objc_msgSend;
            NSError *initErr = nil;
            id rt = initMsg(rtAlloc, @selector(initWithBundle:error:), rtBundle, &initErr);

            initOutcome = [NSString stringWithFormat:
                @"result: %@\n  error: %@", rt, initErr];
            if (rt) {
              typedef id (*IdMsg)(id, SEL);
              IdMsg idMsg = (IdMsg)objc_msgSend;
              typedef BOOL (*AvailMsg)(id, SEL, NSError **);
              AvailMsg availMsg = (AvailMsg)objc_msgSend;
              NSError *availErr = nil;
              BOOL avail = availMsg(rt, @selector(isAvailableWithError:), &availErr);
              initOutcome = [initOutcome stringByAppendingFormat:
                  @"\n  name=%@ version=%@\n  runtimeRootURL=%@\n  available=%d whyNot=%@",
                  idMsg(rt, @selector(name)), idMsg(rt, @selector(versionString)),
                  idMsg(rt, @selector(runtimeRootURL)), avail, availErr];
            }
          } @catch (NSException *ex) {
            initOutcome = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
          }
        });
        [log appendFormat:@"  %@\n  %@\n",
                           initOk ? @"returned" : @"*** TIMED OUT -- THIS CALL HANGS ***",
                           initOutcome];
        flush();

        // Registration needs Contents/Resources/RuntimeRoot, and the binary
        // strings show it's keyed off a specific marker:
        // RuntimeRoot/System/Library/CoreServices/SystemVersion.plist. The
        // requirements are layered (register < available < boot), so rather
        // than one CI round trip per layer, build the RuntimeRoot up in a
        // WRITABLE copy on-device and re-validate after each addition -- one
        // run maps the whole ladder. Every byte here is synthesized, not
        // downloaded; the point is to find the minimum structure that
        // satisfies each check, which scopes what the real 16GB tree must
        // actually provide.
        // (fm is already the NSFileManager declared in the device-type block
        // above -- reuse it rather than redefining in the same scope)
        NSString *rtBuild = [docs stringByAppendingPathComponent:@"rt-build"];
        [fm removeItemAtPath:rtBuild error:nil];
        [fm createDirectoryAtPath:rtBuild withIntermediateDirectories:YES
                       attributes:nil error:nil];

        // CRITICAL: each step gets its OWN bundle directory, with the target
        // structure laid down BEFORE the bundle is ever accessed. The prior
        // version reused one path and one +[NSBundle bundleWithPath:] -- which
        // returns a PROCESS-CACHED bundle that snapshots its resource listing
        // on first touch, so files added after step 0 were invisible and the
        // error never changed. A unique, pre-populated path per step sidesteps
        // the cache entirely. The `setup` block receives the RuntimeRoot path
        // and builds whatever that step is testing.
        NSString *(^buildAndValidate)(int, void (^)(NSString *)) =
            ^NSString *(int step, void (^setup)(NSString *rroot)) {
          NSString *dir = [rtBuild stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"step%d", step]];
          [fm removeItemAtPath:dir error:nil];
          [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                         attributes:nil error:nil];
          NSString *wb = [dir stringByAppendingPathComponent:@"iOS 17.2.simruntime"];
          [fm copyItemAtPath:rtBundlePath toPath:wb error:nil];
          NSString *rr =
              [wb stringByAppendingPathComponent:@"Contents/Resources/RuntimeRoot"];
          if (setup) setup(rr);

          __block NSString *r = @"(no result)";
          probeRunWithTimeout(20.0, ^{
            @try {
              NSBundle *b = [NSBundle bundleWithPath:wb];  // fresh path, no stale cache
              id a = ((id (*)(Class, SEL))objc_msgSend)(simRuntimeClass, @selector(alloc));
              NSError *e = nil;
              id rt = ((id (*)(id, SEL, NSBundle *, NSError **))objc_msgSend)(
                  a, @selector(initWithBundle:error:), b, &e);
              if (rt) {
                NSError *availErr = nil;
                BOOL avail = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
                    rt, @selector(isAvailableWithError:), &availErr);
                r = [NSString stringWithFormat:@"INIT OK. available=%d whyNot=%@",
                                               avail, availErr];
              } else {
                NSString *d = [e.userInfo[NSLocalizedDescriptionKey] description] ?: e.description;
                r = [NSString stringWithFormat:@"code=%ld %@", (long)e.code, d];
              }
            } @catch (NSException *ex) {
              r = [NSString stringWithFormat:@"EXC: %@", ex.reason];
            }
          });
          return r;
        };

        void (^makeSystemVersion)(NSString *) = ^(NSString *rr) {
          NSString *csDir =
              [rr stringByAppendingPathComponent:@"System/Library/CoreServices"];
          [fm createDirectoryAtPath:csDir withIntermediateDirectories:YES
                         attributes:nil error:nil];
          NSDictionary *sysVersion = @{
            @"ProductName" : @"iPhone OS",
            @"ProductVersion" : @"17.2",
            @"ProductBuildVersion" : @"21C62",
            @"ProductCopyright" : @"1983-2023 Apple Inc.",
          };
          [sysVersion writeToFile:[csDir stringByAppendingPathComponent:@"SystemVersion.plist"]
                       atomically:YES];
        };

        [log appendString:@"\n=== Progressive RuntimeRoot construction "
                           @"(fresh bundle path per step) ===\n"];

        [log appendFormat:@"step 0 (no RuntimeRoot): %@\n",
            buildAndValidate(0, nil)];
        flush();

        [log appendFormat:@"step 1 (+ empty RuntimeRoot/): %@\n",
            buildAndValidate(1, ^(NSString *rr) {
              [fm createDirectoryAtPath:rr withIntermediateDirectories:YES
                             attributes:nil error:nil];
            })];
        flush();

        [log appendFormat:@"step 2 (+ SystemVersion.plist): %@\n",
            buildAndValidate(2, ^(NSString *rr) {
              makeSystemVersion(rr);
            })];
        flush();

        [log appendFormat:@"step 3 (+ dyld + liblaunch skeleton): %@\n",
            buildAndValidate(3, ^(NSString *rr) {
              makeSystemVersion(rr);
              NSString *usrLib = [rr stringByAppendingPathComponent:@"usr/lib"];
              [fm createDirectoryAtPath:usrLib withIntermediateDirectories:YES
                             attributes:nil error:nil];
              [[NSData data] writeToFile:[usrLib stringByAppendingPathComponent:@"dyld"]
                              atomically:YES];
              [[NSData data] writeToFile:
                  [usrLib stringByAppendingPathComponent:@"liblaunch_sim.dylib"]
                              atomically:YES];
            })];
        flush();

        // Stop inferring from the generic error: record every filesystem
        // check CoreSimulator makes while deciding availability. Whatever it
        // probes and does NOT find is the actual requirement list.
        [log appendString:@"\n=== Tracing filesystem checks during availability ===\n"];
        flush();  // publish BEFORE the risky call, so a hang still shows where we were
        gFileTrace = [NSMutableArray array];
        Method m1 = class_getInstanceMethod([NSFileManager class],
                                             @selector(fileExistsAtPath:));
        Method m2 = class_getInstanceMethod([NSFileManager class],
                                             @selector(fileExistsAtPath:isDirectory:));
        gOrigFileExists = method_setImplementation(m1, (IMP)probeFileExists);
        gOrigFileExistsIsDir = method_setImplementation(m2, (IMP)probeFileExistsIsDir);
        gTracingFiles = YES;

        NSString *traced = buildAndValidate(4, ^(NSString *rr) {
          makeSystemVersion(rr);
          NSString *usrLib = [rr stringByAppendingPathComponent:@"usr/lib"];
          [fm createDirectoryAtPath:usrLib withIntermediateDirectories:YES
                         attributes:nil error:nil];
          [[NSData data] writeToFile:[usrLib stringByAppendingPathComponent:@"dyld"]
                          atomically:YES];
        });

        gTracingFiles = NO;
        method_setImplementation(m1, gOrigFileExists);
        method_setImplementation(m2, gOrigFileExistsIsDir);

        [log appendFormat:@"step 4 (traced): %@\n", traced];
        NSLock *tlock = probeFileTraceLock();
        [tlock lock];
        NSArray *traceSnapshot = [gFileTrace copy];
        [tlock unlock];
        [log appendFormat:@"\n%lu filesystem checks recorded:\n%@\n",
                           (unsigned long)traceSnapshot.count,
                           traceSnapshot.count
                               ? [traceSnapshot componentsJoinedByString:@"\n"]
                               : @"(none -- CoreSimulator uses raw stat(), not NSFileManager)"];
        flush();

        // The trace named the one file availability actually wants:
        //   RuntimeRoot/usr/lib/system/host/liblaunch_sim.dylib
        // (the AppleInternal miss is just an is-internal-build probe; absence
        // is normal). Earlier steps put liblaunch_sim.dylib at usr/lib/ --
        // two directories off, which the generic "corrupt or missing files"
        // error would never have revealed.
        //
        // Placed as an empty file first, on purpose: if availability only
        // stat()s it, an empty file is enough and proves the check is
        // existence-only. Tracing stays on so any FURTHER checks past this
        // one get captured in the same run.
        [log appendString:@"\n=== step 5: liblaunch_sim.dylib at the traced path ===\n"];
        flush();
        [tlock lock];
        gFileTrace = [NSMutableArray array];
        [tlock unlock];
        gOrigFileExists = method_setImplementation(m1, (IMP)probeFileExists);
        gOrigFileExistsIsDir = method_setImplementation(m2, (IMP)probeFileExistsIsDir);
        gTracingFiles = YES;

        NSString *step5 = buildAndValidate(5, ^(NSString *rr) {
          makeSystemVersion(rr);
          NSString *hostDir = [rr stringByAppendingPathComponent:@"usr/lib/system/host"];
          [fm createDirectoryAtPath:hostDir withIntermediateDirectories:YES
                         attributes:nil error:nil];
          [[NSData data] writeToFile:
              [hostDir stringByAppendingPathComponent:@"liblaunch_sim.dylib"]
                          atomically:YES];

          // Real SampleContent (17MB, shipped in the app by CI) alongside
          // RuntimeRoot. Device creation copies this into the new device's
          // data directory via sim_copyItemAtPath:toCreatedPath:error:, and
          // last run aborted there because there was nothing to copy. Copied
          // rather than symlinked: copyItemAtPath: would duplicate a symlink
          // instead of following it.
          NSString *resources = [rr stringByDeletingLastPathComponent];
          NSString *sampleSrc = [[[NSBundle mainBundle] bundlePath]
              stringByAppendingPathComponent:@"RealProfiles/SampleContent"];
          if ([fm fileExistsAtPath:sampleSrc]) {
            [fm copyItemAtPath:sampleSrc
                        toPath:[resources stringByAppendingPathComponent:@"SampleContent"]
                         error:nil];
          }
        });

        gTracingFiles = NO;
        method_setImplementation(m1, gOrigFileExists);
        method_setImplementation(m2, gOrigFileExistsIsDir);

        [tlock lock];
        NSArray *trace5 = [gFileTrace copy];
        [tlock unlock];
        [log appendFormat:@"step 5: %@\n\n%lu filesystem checks:\n%@\n",
                           step5, (unsigned long)trace5.count,
                           trace5.count ? [trace5 componentsJoinedByString:@"\n"]
                                        : @"(none)"];
        flush();

        // All three prerequisites now exist on-device: a live
        // SimServiceContext, a registered device type, and a runtime that
        // reports available=1. That's a complete configuration, so try what
        // it's for -- creating an actual SimDevice.
        //
        // Register the step-5 runtime (the available one) into the live
        // context first; everything so far validated SimRuntime standalone,
        // not through the context's own collection.
        [log appendString:@"\n=== Creating a SimDevice ===\n"];
        flush();

        // Split into separately-timed, separately-flushed calls. The first
        // version ran all four in one block and the log ended at the section
        // header with no indication which died. Each sub-step now publishes
        // before it runs, so the last line printed names the culprit without
        // needing a crash report.
        // Prefer a REAL downloaded runtime over the synthetic one. Everything
        // up to here has run against a zero-byte liblaunch_sim.dylib, which is
        // enough to register and report available but obviously cannot boot.
        // Once the download has placed a genuine RuntimeRoot in Application
        // Support, register that instead -- same API call, real bits.
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(
                                   NSApplicationSupportDirectory, NSUserDomainMask, YES)
                                   .firstObject;
        NSString *downloadedRuntimes =
            [appSupport stringByAppendingPathComponent:@"SimRuntimes"];
        NSString *downloadedRoot = [downloadedRuntimes
            stringByAppendingPathComponent:
                @"iOS 17.2.simruntime/Contents/Resources/RuntimeRoot"];
        NSString *realLiblaunch = [downloadedRoot
            stringByAppendingPathComponent:@"usr/lib/system/host/liblaunch_sim.dylib"];

        NSString *step5Dir = [rtBuild stringByAppendingPathComponent:@"step5"];
        BOOL usingDownloaded = NO;
        if ([fm fileExistsAtPath:realLiblaunch]) {
          unsigned long long sz =
              [[fm attributesOfItemAtPath:realLiblaunch error:NULL] fileSize];
          NSArray *rootEntries = [fm contentsOfDirectoryAtPath:downloadedRoot error:NULL];
          [log appendFormat:@"\nDOWNLOADED RUNTIME FOUND -- using it instead of the "
                             @"synthetic one\n  %@\n  liblaunch_sim.dylib = %llu bytes "
                             @"(synthetic was 0)\n  RuntimeRoot top level: %@\n",
                             downloadedRuntimes, sz, rootEntries];
          step5Dir = downloadedRuntimes;
          usingDownloaded = YES;
        } else {
          [log appendFormat:@"\n(no downloaded runtime yet at %@ -- using the "
                             @"synthetic one; tap DOWNLOAD REAL RUNTIME to change that)\n",
                             downloadedRuntimes];
        }
        (void)usingDownloaded;
        flush();
        typedef id (*IdMsg)(id, SEL);
        IdMsg idMsg2 = (IdMsg)objc_msgSend;

        // A: register the AVAILABLE runtime into the context. Prime suspect:
        // the earlier call was a no-op because that bundle was invalid, so
        // this is the first time real registration machinery actually runs.
        [log appendString:@"A. supportedRuntimesAddProfilesAtPath (30s)...\n"];
        flush();
        __block NSString *outA = @"(did not finish)";
        BOOL okA = probeRunWithTimeout(30.0, ^{
          @try {
            ((void (*)(id, SEL, NSString *, BOOL))objc_msgSend)(
                liveContext,
                @selector(supportedRuntimesAddProfilesAtPath:createDefaultDevicesIfNeeded:),
                step5Dir, NO);
            outA = @"ok";
          } @catch (NSException *ex) {
            outA = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
          }
        });
        [log appendFormat:@"   %@ %@\n", okA ? @"returned" : @"*** TIMED OUT ***", outA];
        flush();

        // B: what the context holds now
        [log appendString:@"B. reading context collections (20s)...\n"];
        flush();
        __block NSString *outB = @"(did not finish)";
        __block id ctxRuntime = nil;
        __block id ctxType = nil;
        BOOL okB = probeRunWithTimeout(20.0, ^{
          @try {
            id runtimes = idMsg2(liveContext, @selector(supportedRuntimes));
            id types = idMsg2(liveContext, @selector(supportedDeviceTypes));
            if ([runtimes respondsToSelector:@selector(count)] && [runtimes count] > 0) {
              ctxRuntime = [runtimes firstObject];
            }
            if ([types respondsToSelector:@selector(count)] && [types count] > 0) {
              ctxType = [types firstObject];
            }
            outB = [NSString stringWithFormat:@"runtimes=%@\n   deviceTypes=%@",
                                              runtimes, types];
          } @catch (NSException *ex) {
            outB = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
          }
        });
        [log appendFormat:@"   %@ %@\n", okB ? @"returned" : @"*** TIMED OUT ***", outB];
        flush();

        // C: open a device set in a writable directory of ours
        [log appendString:@"C. deviceSetWithPath:error: (30s)...\n"];
        flush();
        __block NSString *outC = @"(did not finish)";
        __block id deviceSet = nil;
        BOOL okC = probeRunWithTimeout(30.0, ^{
          @try {
            NSString *setPath = [docs stringByAppendingPathComponent:@"DeviceSet"];
            [[NSFileManager defaultManager] createDirectoryAtPath:setPath
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
            NSError *setErr = nil;
            deviceSet = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(
                liveContext, @selector(deviceSetWithPath:error:), setPath, &setErr);
            outC = [NSString stringWithFormat:@"deviceSet=%@ error=%@", deviceSet, setErr];
          } @catch (NSException *ex) {
            outC = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
          }
        });
        [log appendFormat:@"   %@ %@\n", okC ? @"returned" : @"*** TIMED OUT ***", outC];
        flush();

        // D: the actual creation
        [log appendFormat:@"D. createDeviceWithType:runtime:name:error: (60s)...\n"
                           @"   (type=%@ runtime=%@ set=%@)\n",
                           ctxType ? @"yes" : @"nil", ctxRuntime ? @"yes" : @"nil",
                           deviceSet ? @"yes" : @"nil"];
        flush();
        // Trace every file this step reads -- the technique that cracked the
        // availability requirement in one run. (The exception handler that
        // captures the assertion is installed once at launch, not here.)
        [tlock lock];
        gFileTrace = [NSMutableArray array];
        [tlock unlock];
        gOrigFileExists = method_setImplementation(m1, (IMP)probeFileExists);
        gOrigFileExistsIsDir = method_setImplementation(m2, (IMP)probeFileExistsIsDir);
        gTracingFiles = YES;

        __block NSString *outD = @"(did not finish)";
        if (deviceSet && ctxType && ctxRuntime) {
          BOOL okD = probeRunWithTimeout(60.0, ^{
            @try {
              NSError *devErr = nil;
              id device = ((id (*)(id, SEL, id, id, NSString *, NSError **))objc_msgSend)(
                  deviceSet, @selector(createDeviceWithType:runtime:name:error:),
                  ctxType, ctxRuntime, @"Probe iPhone 14", &devErr);
              outD = [NSString stringWithFormat:@"device=%@\n   error=%@", device, devErr];
              gCreatedDevice = device;
              if (device) {
                outD = [outD stringByAppendingFormat:
                    @"\n   *** SIMDEVICE CREATED ***\n   UDID=%@\n   name=%@\n"
                    @"   state=%@\n   devicePath=%@",
                    idMsg2(device, @selector(UDID)), idMsg2(device, @selector(name)),
                    idMsg2(device, @selector(stateString)),
                    idMsg2(device, @selector(devicePath))];
              }
            } @catch (NSException *ex) {
              outD = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
            }
          });
          [log appendFormat:@"   %@ %@\n", okD ? @"returned" : @"*** TIMED OUT ***", outD];

          // E: boot. Only meaningful with a real RuntimeRoot -- booting means
          // starting launchd inside the runtime and spawning its daemons, and
          // there is nothing to start when liblaunch_sim.dylib is a zero-byte
          // placeholder. Attempted regardless so the failure is recorded
          // either way, and it's the last step, so a hang costs nothing that
          // came before it.
          if (gCreatedDevice) {
            // Neutralise the resource pre-check before boot. Last run stopped
            // here with maxUserProcs=1 vs an enforcedProcBuffer of 100, having
            // never attempted a spawn.
            Class rcClass = NSClassFromString(@"SimHostResourceChecker");
            if (rcClass) {
              struct { SEL sel; IMP imp; } patches[] = {
                {@selector(maxUserProcs), (IMP)probeMaxUserProcs},
                {@selector(runningUserProcs), (IMP)probeRunningUserProcs},
                {@selector(maxSystemProcs), (IMP)probeMaxSystemProcs},
                {@selector(runningSystemProcs), (IMP)probeRunningSystemProcs},
                {@selector(maxFiles), (IMP)probeMaxFiles},
                {@selector(openFiles), (IMP)probeOpenFiles},
              };
              NSMutableArray *patched = [NSMutableArray array];
              for (size_t i = 0; i < sizeof(patches) / sizeof(patches[0]); i++) {
                Method m = class_getInstanceMethod(rcClass, patches[i].sel);
                if (m) {
                  method_setImplementation(m, patches[i].imp);
                  [patched addObject:NSStringFromSelector(patches[i].sel)];
                }
              }
              [log appendFormat:@"\npatched SimHostResourceChecker: %@\n",
                                 [patched componentsJoinedByString:@", "]];
            } else {
              [log appendString:@"\nSimHostResourceChecker not found (unexpected)\n"];
            }

            // Boot wants a writable /private/tmp:
            //
            //   /private/tmp does not exist or is not accessible. Simulators
            //   will NOT be available until this misconfiguration of your
            //   system is corrected!
            //
            // It creates /private/tmp/<launchdJobName>/ and writes
            // disabled.plist there. iOS has no /private/tmp and the sandbox
            // won't allow creating one, so patch_tmp_path.py rewrote those two
            // literals in the binary to the RELATIVE paths "tmp" and "tmp/%@".
            // They resolve against the working directory, so pointing it at the
            // data container turns them into the app's own tmp directory --
            // and because the kernel resolves relative paths, this works for
            // direct open()/mkdir() as well as anything via NSFileManager.
            NSString *containerDir =
                [NSHomeDirectory() stringByStandardizingPath];
            NSString *tmpDir = [containerDir stringByAppendingPathComponent:@"tmp"];
            [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL];
            int chdirRc = chdir(containerDir.fileSystemRepresentation);
            char cwdBuf[PATH_MAX] = {0};
            getcwd(cwdBuf, sizeof(cwdBuf));
            [log appendFormat:@"\nworking directory for the relative tmp path:\n"
                               "  chdir(%@) -> %d\n  cwd=%s\n  tmp exists=%d\n",
                               containerDir, chdirRc, cwdBuf,
                               [[NSFileManager defaultManager]
                                   fileExistsAtPath:tmpDir]];

            [log appendFormat:@"\n%@\n", probeInstallBootTracing()];

            [log appendFormat:@"\nE. bootWithOptions:error: (90s) -- %@\n",
                               usingDownloaded ? @"REAL RuntimeRoot"
                                               : @"synthetic RuntimeRoot, expected to fail"];
            flush();
            __block NSString *outE = @"(did not finish)";
            BOOL okE = probeRunWithTimeout(90.0, ^{
              @try {
                NSError *bootErr = nil;
                BOOL booted = ((BOOL (*)(id, SEL, NSDictionary *, NSError **))objc_msgSend)(
                    gCreatedDevice, @selector(bootWithOptions:error:), @{}, &bootErr);
                outE = [NSString stringWithFormat:@"booted=%d error=%@", booted, bootErr];
                typedef id (*IdMsg2)(id, SEL);
                IdMsg2 im = (IdMsg2)objc_msgSend;
                outE = [outE stringByAppendingFormat:@"\n   state now: %@",
                                                     im(gCreatedDevice, @selector(stateString))];
              } @catch (NSException *ex) {
                outE = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@", ex.name, ex.reason];
              }
            });
            [log appendFormat:@"   %@ %@\n",
                               okE ? @"returned" : @"*** TIMED OUT ***", outE];
          }
        } else {
          [log appendString:@"   skipped -- a prerequisite above came back nil\n"];
        }
        gTracingFiles = NO;
        method_setImplementation(m1, gOrigFileExists);
        method_setImplementation(m2, gOrigFileExistsIsDir);
        [tlock lock];
        NSArray *traceD = [gFileTrace copy];
        [tlock unlock];
        [log appendFormat:@"\n%lu filesystem checks during creation:\n%@\n",
                           (unsigned long)traceD.count,
                           traceD.count ? [traceD componentsJoinedByString:@"\n"]
                                        : @"(none)"];
        flush();

        // With posix_spawn measured as EPERM, loading the code is the only
        // remaining route to a launchd_sim. Test it directly against the real
        // binary rather than reasoning about what iOS permits.
        if (usingDownloaded) {
          probeTestCodeLoading(log, downloadedRoot);
          flush();
        }
      }
    }
  }

  // Make the selector hooks inert now that the CoreSimulator work is done.
  // Leaving them live means every unresolved selector in the process keeps
  // routing through probe code -- on the main thread, during UIKit event
  // handling -- for no further information. That's what the watchdog kill
  // came out of.
  gHooksEnabled = NO;

  [log appendString:@"\n=== PROBE COMPLETE ===\n"];
  [log appendFormat:@"(also written to %@, though the Files app can't see "
                     @"it on this install -- use the clipboard button)", logPath];
  flush();
  NSLog(@"[PROBE]\n%@", log);
  });  // end background probe block

  return YES;
}

- (void)fetchRuntimeTapped:(UIButton *)sender {
  [sender setTitle:@"CHECKING..." forState:UIControlStateNormal];
  sender.enabled = NO;

  // Application Support, not Documents and not Caches:
  //   - Documents is backed up to iCloud, and a ~16GB re-downloadable tree
  //     has no business in someone's backup.
  //   - Caches can be purged by the OS under disk pressure, which would make
  //     an installed runtime silently disappear.
  // The fetcher additionally marks it excluded from backup.
  //
  // CoreSimulator imposes no fixed location -- every path so far (developer
  // dir, device set, profile dirs) was one we passed in explicitly. The only
  // real requirement is the BUNDLE SHAPE: SimRuntime derives runtimeRootURL
  // from its own bundle, so RuntimeRoot must land at
  // <x>.simruntime/Contents/Resources/RuntimeRoot. Extract directly into that
  // shape and registration can point at the parent directory.
  NSString *appSupport = NSSearchPathForDirectoriesInDomains(
                             NSApplicationSupportDirectory, NSUserDomainMask, YES)
                             .firstObject;
  NSString *runtimesDir = [appSupport stringByAppendingPathComponent:@"SimRuntimes"];
  NSString *bundleDir =
      [runtimesDir stringByAppendingPathComponent:@"iOS 17.2.simruntime"];
  NSString *dest = [bundleDir stringByAppendingPathComponent:@"Contents/Resources"];

  // Off the main thread: this is network + multi-GB disk work, and blocking
  // the main thread is what got the app watchdog-killed earlier in this
  // project.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSMutableString *out = [NSMutableString stringWithString:
                                                @"=== RUNTIME DOWNLOAD ===\n"];
    void (^publish)(void) = ^{
      NSString *snapshot = [out copy];
      gLastPublished = snapshot;
      dispatch_async(dispatch_get_main_queue(), ^{
        gTextView.text = snapshot;
        [UIPasteboard generalPasteboard].string = snapshot;
      });
    };

    // Refuse to re-download something already here. The fetcher wipes its
    // destination before the first chunk, so a stray tap would destroy a
    // completed 15GB extraction and force another 6.9GB transfer. Anything
    // near the real file count means it's present; a genuinely broken
    // extraction will be far short of that, and re-running is then correct.
    NSFileManager *pre = [NSFileManager defaultManager];
    NSString *existingRoot = [dest stringByAppendingPathComponent:@"RuntimeRoot"];
    NSString *marker =
        [existingRoot stringByAppendingPathComponent:
                          @"usr/lib/system/host/liblaunch_sim.dylib"];
    unsigned long long markerSize =
        [[pre attributesOfItemAtPath:marker error:NULL] fileSize];
    NSArray *existingTop = [pre contentsOfDirectoryAtPath:existingRoot error:NULL];

    if (markerSize > 100000 && existingTop.count >= 5) {
      [out appendFormat:
               @"RUNTIME ALREADY PRESENT -- not re-downloading.\n"
               @"  %@\n  liblaunch_sim.dylib = %llu bytes\n"
               @"  top level (%lu entries): %@\n\n"
               @"Delete the app (or the SimRuntimes folder) if you truly want "
               @"a fresh copy.\n",
               existingRoot, markerSize, (unsigned long)existingTop.count,
               [[existingTop sortedArrayUsingSelector:@selector(compare:)]
                   componentsJoinedByString:@" "]];

      // Re-run the cheap part regardless. RuntimeRoot is the expensive 15GB
      // piece, but the bundle is useless without its plists, and last run's
      // assembly step may not have completed. These are kilobytes, so
      // repeating them costs nothing and guarantees a registrable bundle.
      NSString *staged = [[[NSBundle mainBundle] bundlePath]
          stringByAppendingPathComponent:@"RealProfiles/Runtimes/iOS 17.2.simruntime"];
      NSString *sample = [[[NSBundle mainBundle] bundlePath]
          stringByAppendingPathComponent:@"RealProfiles/SampleContent"];
      [pre copyItemAtPath:[staged stringByAppendingPathComponent:@"Contents/Info.plist"]
                   toPath:[bundleDir stringByAppendingPathComponent:@"Contents/Info.plist"]
                    error:NULL];
      [pre copyItemAtPath:[staged stringByAppendingPathComponent:@"Contents/Resources/profile.plist"]
                   toPath:[dest stringByAppendingPathComponent:@"profile.plist"]
                    error:NULL];
      [pre copyItemAtPath:sample
                   toPath:[dest stringByAppendingPathComponent:@"SampleContent"]
                    error:NULL];

      [out appendString:@"bundle components:\n"];
      for (NSString *rel in @[ @"Contents/Info.plist", @"Contents/Resources/profile.plist",
                               @"Contents/Resources/RuntimeRoot",
                               @"Contents/Resources/SampleContent" ]) {
        NSString *full = [bundleDir stringByAppendingPathComponent:rel];
        [out appendFormat:@"  %@ %@\n",
                          [pre fileExistsAtPath:full] ? @"ok  " : @"MISS", rel];
      }
      [out appendFormat:@"\nregister with:\n  %@\n", runtimesDir];
      publish();
      dispatch_async(dispatch_get_main_queue(), ^{
        [sender setTitle:@"RUNTIME ALREADY INSTALLED" forState:UIControlStateNormal];
        sender.enabled = YES;
        self.progressLabel.text = @"runtime present";
        [self.progressBar setProgress:1.0 animated:NO];
      });
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [sender setTitle:@"DOWNLOADING..." forState:UIControlStateNormal];
    });

    NSError *err = nil;
    BOOL ok = [RuntimeFetcher
        fetchTag:@"runtime-ios17.2"
            into:dest
        progress:^(double fraction, NSString *status) {
          // Fires per network callback; keep it to the bar/label and off the
          // transcript, which the log block handles instead.
          dispatch_async(dispatch_get_main_queue(), ^{
            if (fraction >= 0) {
              [self.progressBar setProgress:(float)fraction animated:YES];
            }
            self.progressLabel.text = status;
          });
        }
             log:^(NSString *line) {
               [out appendFormat:@"%@\n", line];
               publish();
             }
           error:&err];

    [out appendFormat:@"\nresult: %@\n", ok ? @"SUCCESS" : @"FAILED"];
    if (err) [out appendFormat:@"error: %@\n", err.localizedDescription];
    publish();  // publish the verdict BEFORE any further work can stall it

    // Complete the bundle: the download supplies RuntimeRoot, but a runtime
    // is only loadable with its Info.plist/profile.plist, and device creation
    // also needs SampleContent. Copied AFTER fetching, since the fetcher wipes
    // its destination first.
    if (ok) {
      NSFileManager *fm2 = [NSFileManager defaultManager];
      NSString *staged = [[[NSBundle mainBundle] bundlePath]
          stringByAppendingPathComponent:@"RealProfiles/Runtimes/iOS 17.2.simruntime"];
      NSString *sample = [[[NSBundle mainBundle] bundlePath]
          stringByAppendingPathComponent:@"RealProfiles/SampleContent"];

      [fm2 copyItemAtPath:[staged stringByAppendingPathComponent:@"Contents/Info.plist"]
                   toPath:[bundleDir stringByAppendingPathComponent:@"Contents/Info.plist"]
                    error:NULL];
      [fm2 copyItemAtPath:[staged stringByAppendingPathComponent:@"Contents/Resources/profile.plist"]
                   toPath:[dest stringByAppendingPathComponent:@"profile.plist"]
                    error:NULL];
      [fm2 copyItemAtPath:sample
                   toPath:[dest stringByAppendingPathComponent:@"SampleContent"]
                    error:NULL];

      [out appendFormat:@"\nassembled bundle at:\n  %@\n", bundleDir];
      for (NSString *rel in @[ @"Contents/Info.plist", @"Contents/Resources/profile.plist",
                               @"Contents/Resources/RuntimeRoot",
                               @"Contents/Resources/SampleContent" ]) {
        NSString *full = [bundleDir stringByAppendingPathComponent:rel];
        [out appendFormat:@"  %@ %@\n",
                          [fm2 fileExistsAtPath:full] ? @"ok  " : @"MISS", rel];
      }
      [out appendFormat:@"\nregister with:\n  %@\n", runtimesDir];
      publish();
    }

    // Show what landed, WITHOUT walking the whole tree.
    //
    // The previous version called subpathsOfDirectoryAtPath: on RuntimeRoot,
    // which materialises every path into one array before returning -- fine
    // for the 44-file test slice, pathological for 370,917 files. It stalled
    // long enough that the "result:" line above never got published, making a
    // successful 15GB extraction look like a hang.
    //
    // Top level plus a few known-interesting paths is enough to confirm this
    // is a real iOS filesystem rather than a partial one.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *rr = [dest stringByAppendingPathComponent:@"RuntimeRoot"];
    NSArray *top = [fm contentsOfDirectoryAtPath:rr error:NULL];
    [out appendFormat:@"\nRuntimeRoot top level (%lu entries):\n  %@\n",
                      (unsigned long)top.count,
                      [[top sortedArrayUsingSelector:@selector(compare:)]
                          componentsJoinedByString:@" "]];

    for (NSString *probe in @[
           @"usr/lib/system/host/liblaunch_sim.dylib",
           @"usr/lib/dyld_sim",
           @"System/Library/CoreServices/SystemVersion.plist",
           @"System/Library/Caches/com.apple.dyld",
           @"System/Library/CoreServices/SpringBoard.app",
           @"sbin/launchd_sim",
         ]) {
      NSString *full = [rr stringByAppendingPathComponent:probe];
      BOOL isDir = NO;
      BOOL exists = [fm fileExistsAtPath:full isDirectory:&isDir];
      unsigned long long sz =
          exists && !isDir
              ? [[fm attributesOfItemAtPath:full error:NULL] fileSize]
              : 0;
      [out appendFormat:@"  %@ %@%@\n", exists ? @"ok  " : @"MISS", probe,
                        (exists && !isDir)
                            ? [NSString stringWithFormat:@" (%llu bytes)", sz]
                            : (isDir ? @" (dir)" : @"")];
    }
    publish();

    dispatch_async(dispatch_get_main_queue(), ^{
      [sender setTitle:ok ? @"DOWNLOAD DONE -- copy log" : @"DOWNLOAD FAILED -- copy log"
              forState:UIControlStateNormal];
      sender.enabled = YES;
    });
  });
}

- (void)copyLogTapped:(UIButton *)sender {
  [UIPasteboard generalPasteboard].string =
      gLastPublished ?: @"(no log captured yet)";
  [sender setTitle:@"COPIED -- now paste it" forState:UIControlStateNormal];
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
