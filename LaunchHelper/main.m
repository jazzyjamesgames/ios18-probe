// LaunchHelper -- a minimal app-extension bundle whose only job is to prove
// out genuine OS-level process separation, adapted from studying
// LiveContainer's real, shipping LiveProcess component.
//
// Deliberately scoped down from LiveContainer's own implementation: they
// need their extension process to behave like an arbitrary full guest app
// (hence hooking dlopen and shadowing UIApplicationMain to hijack the
// extension's own bootstrap). We don't need that yet -- this just proves
// the OS will launch this as a separate process at all, and that dlopen
// from within it works, using nothing but the standard, unmodified
// NSExtensionRequestHandling protocol.
//
// No main() here on purpose. The actual process entry point is set via the
// linker (-Wl,-e,_NSExtensionMain in the build step) to point directly at
// Foundation's own real, exported NSExtensionMain function -- confirmed to
// exist and be dlsym-resolvable by LiveContainer's own source, which calls
// dlsym(RTLD_NEXT, "NSExtensionMain") to chain to it. That real function is
// Apple's own extension bootstrap: it reads NSExtensionPrincipalClass from
// Info.plist, instantiates it, and calls beginRequestWithExtensionContext:
// on it -- which is where all of our own logic lives, below.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

// Darwin notifications: system-wide, unsandboxed pub-sub, no entitlement
// needed at all (unlike the App Group file channel, which didn't survive
// SideStore's resigning). Can't carry the log text, but can confirm exactly
// how far beginRequestWithExtensionContext: actually got before returning.
static void postDarwin(NSString *name) {
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge CFStringRef)name, NULL, NULL,
                                        true);
}

@interface LaunchHelperHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation LaunchHelperHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
  NSMutableString *log = [NSMutableString string];
  [log appendFormat:@"LaunchHelper extension process started. pid=%d\n\n",
                     getpid()];
  postDarwin(@"dev.local.ios18probe.LaunchHelper.started");

  // Written to the shared App Group container after every step, same
  // "survive a crash" pattern as Probe's own log -- Probe's process is a
  // different process entirely, so this is the only channel back to it.
  NSURL *groupURL = [[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:@"group.dev.local.ios18probe"];
  NSURL *sharedLogURL = [groupURL URLByAppendingPathComponent:@"launchhelper.log"];
  void (^flush)(void) = ^{
    [log writeToURL:sharedLogURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
  };
  [log appendFormat:@"App Group container: %@\n\n", groupURL];
  flush();

  NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"target"
                                                           ofType:@"dylib"];
  [log appendFormat:@"target path: %@\n", bundlePath];
  flush();

  void *handle = dlopen([bundlePath fileSystemRepresentation], RTLD_NOW);
  postDarwin(@"dev.local.ios18probe.LaunchHelper.dlopenDone");
  if (!handle) {
    const char *err = dlerror();
    [log appendFormat:@"dlopen FAILED:\n%s\n", err ? err : "(no error string)"];
    flush();
  } else {
    [log appendString:@"dlopen SUCCEEDED (constructor already ran as part "
                       @"of the dlopen() call itself).\n\n"];
    flush();

    void *sym = dlsym(handle, "probe_run");
    if (!sym) {
      const char *err = dlerror();
      [log appendFormat:@"dlsym(\"probe_run\") FAILED:\n%s\n",
                         err ? err : "(no error string)"];
      flush();
    } else {
      [log appendString:@"dlsym(\"probe_run\") found it -- calling now.\n"
                         @"(if this process dies before the next flush, it "
                         @"crashed inside probe_run -- the shared log will "
                         @"still show progress up to that point)\n"];
      flush();
      void (*probe_run)(void) = (void (*)(void))sym;
      probe_run();
      postDarwin(@"dev.local.ios18probe.LaunchHelper.probeRunDone");
      [log appendString:@"\nprobe_run() returned without crashing.\n"];
      flush();
    }
  }

  NSLog(@"[LAUNCHHELPER]\n%@", log);
  postDarwin(@"dev.local.ios18probe.LaunchHelper.reachedEnd");

  NSExtensionItem *resultItem = [[NSExtensionItem alloc] init];
  resultItem.userInfo = @{@"log" : log};
  [context completeRequestReturningItems:@[ resultItem ]
                        completionHandler:nil];
}

@end
