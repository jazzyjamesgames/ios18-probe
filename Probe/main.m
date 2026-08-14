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
#import <dlfcn.h>

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

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = [UIColor whiteColor];

  UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
  tv.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.editable = NO;
  tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
  [vc.view addSubview:tv];

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
  } else {
    [log appendString:@"dlopen SUCCEEDED -- CoreSimulator's real binary "
                       @"loaded and fully linked on iOS.\n"];
  }
  flush();

  [log appendFormat:@"\n(written to %@ -- pull it via the Files app)", logPath];
  flush();

  tv.text = log;
  NSLog(@"[PROBE]\n%@", log);

  return YES;
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
