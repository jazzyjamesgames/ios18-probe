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

static void probePublish(void) {
  NSMutableString *out = [NSMutableString string];
  if (gLog) [out appendString:gLog];
  if (gMissingSelectors.count) {
    [out appendFormat:@"\n\n--- missing selectors seen so far (%lu) ---\n%@\n",
                      (unsigned long)gMissingSelectors.count,
                      [gMissingSelectors componentsJoinedByString:@"\n"]];
  }
  [UIPasteboard generalPasteboard].string = out;
  if (gLogPath) {
    [out writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
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
  return [name hasPrefix:@"sim_"] || [name containsString:@"Sim"];
}

static void probeRecordMissing(NSString *description) {
  if ([gMissingSelectors containsObject:description]) return;
  [gMissingSelectors addObject:description];
  [[gMissingSelectors componentsJoinedByString:@"\n"]
      writeToFile:gMissingSelectorsPath
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:nil];
  probePublish();
  NSLog(@"[PROBE] missing selector: %@", description);
}

static BOOL probeResolveInstanceMethod(id self, SEL _cmd, SEL sel) {
  NSString *name = NSStringFromSelector(sel);
  probeRecordMissing(
      [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass((Class)self), name]);
  // Only stub CoreSimulator's own category methods. The previous run stubbed
  // EVERY unresolved selector, including Foundation internals that are
  // supposed to be dynamically resolved or to fail
  // (encodeWithOSLogCoder:options:maxLength:,
  // _dynamicContextEvaluation:patternString:) -- returning nil for those
  // corrupted string formatting so badly that the log came back with
  // "%@NSCONTEXT" where real paths and exception names should have been.
  // Log everything, but only interfere where we actually mean to.
  if (!probeLooksLikeCoreSimulator(name)) return NO;
  class_addMethod((Class)self, sel, (IMP)probeMissingSelectorStub, "@@:");
  return YES;
}

// Class methods resolve through a completely separate path
// (+resolveClassMethod:, not +resolveInstanceMethod:), which is why the
// instance-only hook above saw nothing before +[NSError ...] aborted the
// process. Note the target of class_addMethod here is the METAclass --
// that's where class methods live.
static BOOL probeResolveClassMethod(id self, SEL _cmd, SEL sel) {
  NSString *name = NSStringFromSelector(sel);
  probeRecordMissing(
      [NSString stringWithFormat:@"+[%@ %@]", NSStringFromClass((Class)self), name]);
  // Stubbed for sim_-prefixed selectors as before, and also for anything on
  // NSError: this crash is uncatchable, so without a stub the process dies
  // at the first one and any selectors after it stay invisible. A nil return
  // from an NSError factory is at least plausibly-shaped, and whatever
  // breaks downstream of it is its own signal.
  if (!probeLooksLikeCoreSimulator(name)) return NO;
  class_addMethod(object_getClass((Class)self), sel, (IMP)probeMissingSelectorStub, "@@:");
  return YES;
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
  void (^flush)(void) = ^{
    probePublish();
  };

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

    [log appendString:@"\n--- method lists for candidate entry-point classes ---\n"];
    for (NSString *className in toIntrospect) {
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
           @"NSProcessInfo", @"NSNumber"
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

      typedef id (*ConnTypeMsg)(Class, SEL, NSString *, NSUInteger, NSError **);
      ConnTypeMsg connMsg = (ConnTypeMsg)objc_msgSend;
      for (NSUInteger connectionType = 0; connectionType <= 3; connectionType++) {
        [log appendFormat:@"\nserviceContextForDeveloperDir:connectionType:%lu:error: ...\n",
                           (unsigned long)connectionType];
        flush();
        @try {
          NSError *connError = nil;
          id ctx = connMsg(serviceContextClass,
                           @selector(serviceContextForDeveloperDir:connectionType:error:),
                           developerDir, connectionType, &connError);
          [log appendFormat:@"  result: %@\n  error: %@\n", ctx, connError];
          if (ctx) {
            // A live context means the daemon was bypassed. Ask it something
            // that requires real internal state, not just a non-nil pointer.
            typedef id (*IdMsg)(id, SEL);
            IdMsg idMsg = (IdMsg)objc_msgSend;
            [log appendFormat:@"  CONTEXT OBTAINED. developerDir=%@\n",
                               idMsg(ctx, @selector(developerDir))];
            [log appendFormat:@"  supportedRuntimes=%@\n",
                               idMsg(ctx, @selector(supportedRuntimes))];
            [log appendFormat:@"  supportedDeviceTypes=%@\n",
                               idMsg(ctx, @selector(supportedDeviceTypes))];
          }
        } @catch (NSException *ex) {
          [log appendFormat:@"  EXCEPTION: %@ -- %@\n", ex.name, ex.reason];
        }
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
    }
  }

  [log appendFormat:@"\n(also written to %@, though the Files app can't see "
                     @"it on this install -- use the clipboard button)", logPath];
  flush();

  tv.text = log;
  NSLog(@"[PROBE]\n%@", log);

  // Copied automatically as well as on the button, so that even if something
  // later in launch kills the process, the results are already sitting on
  // the clipboard ready to paste.
  self.logText = [log copy];
  [UIPasteboard generalPasteboard].string = self.logText;

  return YES;
}

- (void)copyLogTapped:(UIButton *)sender {
  [UIPasteboard generalPasteboard].string = self.logText ?: @"(no log captured)";
  [sender setTitle:@"COPIED -- now paste it" forState:UIControlStateNormal];
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
