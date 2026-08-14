// This is the "victim" binary. It's compiled as a normal iOS executable,
// then post-processed (see tools/patch_macho.py) into something dlopen()
// will accept as a library.
//
// Two entry points, for two different purposes:
//   - The constructor runs automatically, synchronously, during dlopen()
//     itself (dyld runs a dylib's mod-init-funcs as part of loading it,
//     before dlopen() returns a handle). Good for a cheap "did the load
//     even work" signal, but it runs before UIApplicationMain has set
//     anything up, so it is NOT safe to touch UIKit from here.
//   - probe_run() is looked up explicitly via dlsym() by the host app and
//     called later, once the app has actually finished launching -- that's
//     the one that touches UIKit.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor))
static void probe_target_loaded(void) {
    NSString *s = [NSString stringWithFormat:@"hello from target, %d", 42];
    NSArray *a = @[@1, @2, @3];
    NSLog(@"[TARGET] constructor ran: %@ count=%lu", s, (unsigned long)a.count);
}

__attribute__((visibility("default")))
void probe_run(void) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    v.backgroundColor = [UIColor systemBlueColor];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    label.text = @"probe_run";
    label.font = [UIFont boldSystemFontOfSize:12];
    [v addSubview:label];

    NSLog(@"[TARGET] probe_run: built UIView %@ with subview %@, label.text=%@",
          v, label, label.text);
}

// Never actually called via dlopen (dlopen doesn't invoke main() on a
// repurposed executable) -- this only exists so the *initial* compile,
// which still links as a normal MH_EXECUTE before patch_macho.py flips
// the header, has an entry point to satisfy the linker.
int main(void) { return 0; }
