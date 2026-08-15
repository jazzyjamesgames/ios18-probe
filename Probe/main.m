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

static BOOL probeResolveInstanceMethod(id self, SEL _cmd, SEL sel) {
  NSString *name = NSStringFromSelector(sel);
  if (![gMissingSelectors containsObject:name]) {
    [gMissingSelectors addObject:name];
    [[gMissingSelectors componentsJoinedByString:@"\n"]
        writeToFile:gMissingSelectorsPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    NSLog(@"[PROBE] missing selector on %@: %@", NSStringFromClass((Class)self), name);
  }
  // Only stub CoreSimulator's own category methods. The previous run stubbed
  // EVERY unresolved selector, including Foundation internals that are
  // supposed to be dynamically resolved or to fail
  // (encodeWithOSLogCoder:options:maxLength:,
  // _dynamicContextEvaluation:patternString:) -- returning nil for those
  // corrupted string formatting so badly that the log came back with
  // "%@NSCONTEXT" where real paths and exception names should have been.
  // Log everything, but only interfere where we actually mean to.
  if ([name hasPrefix:@"sim_"]) {
    class_addMethod((Class)self, sel, (IMP)probeMissingSelectorStub, "@@:");
    return YES;
  }
  return NO;
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
  void (^flush)(void) = ^{
    [log writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

    gMissingSelectors = [NSMutableArray array];
    gMissingSelectorsPath = [docs stringByAppendingPathComponent:@"missing-selectors.txt"];
    // Installed on the concrete constant-string class (the actual receiver
    // in the last crash) and on NSString itself, which covers the rest of
    // the cluster's private subclasses by inheritance. class_addMethod only
    // fails if the class implements this *itself* (not inherited), which
    // these don't -- so no risk of clobbering NSObject's global version.
    for (NSString *clsName in @[ @"__NSCFConstantString", @"NSString" ]) {
      Class cls = NSClassFromString(clsName);
      if (!cls) continue;
      BOOL added = class_addMethod(object_getClass(cls),
                                    @selector(resolveInstanceMethod:),
                                    (IMP)probeResolveInstanceMethod, "B@::");
      [log appendFormat:@"selector-resolution hook on %@: %@\n", clsName,
                         added ? @"installed" : @"NOT installed (already implemented)"];
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
