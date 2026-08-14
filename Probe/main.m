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
  flush();

  NSError *extError = nil;
  NSExtension *ext = [NSExtension extensionWithIdentifier:@"dev.local.ios18probe.LaunchHelper"
                                                      error:&extError];
  if (!ext) {
    [log appendFormat:@"NSExtension init FAILED: %@\n", extError];
    flush();
  } else {
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
  }

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
