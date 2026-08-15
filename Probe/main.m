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
  [lock lock];
  BOOL isNew = ![gMissingSelectors containsObject:description];
  if (isNew) [gMissingSelectors addObject:description];
  [lock unlock];
  // Deliberately does NOT publish. Publishing reads gLog, which belongs to
  // the probe thread; touching it from arbitrary threads is exactly the race
  // being fixed. flush() runs often enough on the probe thread that findings
  // still reach the clipboard promptly.
  if (isNew) NSLog(@"[PROBE] missing selector: %@", description);
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

static BOOL probeResolveInstanceMethod(id self, SEL _cmd, SEL sel) {
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
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = [UIColor whiteColor];

  CGRect bounds = vc.view.bounds;
  CGRect textFrame = CGRectMake(0, 0, bounds.size.width, bounds.size.height - 90);
  UITextView *tv = [[UITextView alloc] initWithFrame:textFrame];
  tv.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.editable = NO;
  tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
  [vc.view addSubview:tv];

  UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
  copyButton.frame =
      CGRectMake(20, bounds.size.height - 80, bounds.size.width - 40, 60);
  copyButton.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  copyButton.backgroundColor = [UIColor systemBlueColor];
  copyButton.tintColor = [UIColor whiteColor];
  copyButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
  copyButton.layer.cornerRadius = 12;
  [copyButton setTitle:@"COPY LOG TO CLIPBOARD" forState:UIControlStateNormal];
  [copyButton addTarget:self
                 action:@selector(copyLogTapped:)
       forControlEvents:UIControlEventTouchUpInside];
  [vc.view addSubview:copyButton];

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

  NSString *coresimPath = [[NSBundle mainBundle] pathForResource:@"coresim_target"
                                                            ofType:@"dylib"];
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
    [log appendString:@"\n--- method lists for candidate entry-point classes ---\n"];
    for (NSString *className in (kDumpMethodLists ? toIntrospect : @[])) {
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

        NSString *step5Dir = [rtBuild stringByAppendingPathComponent:@"step5"];
        __block NSString *createOutcome = @"(did not finish)";
        BOOL createOk = probeRunWithTimeout(60.0, ^{
          @try {
            typedef id (*IdMsg)(id, SEL);
            IdMsg idMsg = (IdMsg)objc_msgSend;

            ((void (*)(id, SEL, NSString *, BOOL))objc_msgSend)(
                liveContext,
                @selector(supportedRuntimesAddProfilesAtPath:createDefaultDevicesIfNeeded:),
                step5Dir, NO);

            id runtimes = idMsg(liveContext, @selector(supportedRuntimes));
            id types = idMsg(liveContext, @selector(supportedDeviceTypes));
            createOutcome = [NSString stringWithFormat:
                @"context runtimes: %@\n  context deviceTypes: %@", runtimes, types];

            if (![runtimes respondsToSelector:@selector(count)] || [runtimes count] == 0) {
              createOutcome = [createOutcome stringByAppendingString:
                  @"\n  (no runtime in the context -- cannot create a device)"];
              return;
            }

            id runtime = [runtimes firstObject];
            id deviceType = [types firstObject];

            // A device set is the container devices live in; point it at a
            // writable directory of ours rather than the macOS default.
            NSString *setPath = [docs stringByAppendingPathComponent:@"DeviceSet"];
            [[NSFileManager defaultManager] createDirectoryAtPath:setPath
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
            NSError *setErr = nil;
            id deviceSet = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(
                liveContext, @selector(deviceSetWithPath:error:), setPath, &setErr);
            createOutcome = [createOutcome stringByAppendingFormat:
                @"\n  deviceSet: %@\n  setError: %@", deviceSet, setErr];
            if (!deviceSet) return;

            NSError *devErr = nil;
            id device = ((id (*)(id, SEL, id, id, NSString *, NSError **))objc_msgSend)(
                deviceSet, @selector(createDeviceWithType:runtime:name:error:),
                deviceType, runtime, @"Probe iPhone 14", &devErr);
            createOutcome = [createOutcome stringByAppendingFormat:
                @"\n  createDevice: %@\n  error: %@", device, devErr];

            if (device) {
              createOutcome = [createOutcome stringByAppendingFormat:
                  @"\n  *** SIMDEVICE CREATED ***\n  UDID=%@\n  name=%@\n  state=%@\n  devicePath=%@",
                  idMsg(device, @selector(UDID)), idMsg(device, @selector(name)),
                  idMsg(device, @selector(stateString)),
                  idMsg(device, @selector(devicePath))];
            }
          } @catch (NSException *ex) {
            createOutcome = [NSString stringWithFormat:@"EXCEPTION: %@ -- %@",
                                                       ex.name, ex.reason];
          }
        });
        [log appendFormat:@"  %@\n  %@\n",
                           createOk ? @"returned" : @"*** TIMED OUT ***", createOutcome];
        flush();
      }
    }
  }

  [log appendString:@"\n=== PROBE COMPLETE ===\n"];
  [log appendFormat:@"(also written to %@, though the Files app can't see "
                     @"it on this install -- use the clipboard button)", logPath];
  flush();
  NSLog(@"[PROBE]\n%@", log);
  });  // end background probe block

  return YES;
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
