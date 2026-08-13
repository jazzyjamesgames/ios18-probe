// This is the "victim" binary. It's compiled as a normal iOS executable,
// then post-processed (see tools/patch_macho.py) into something dlopen()
// will accept as a library. Because dlopen never calls main() on a
// repurposed executable, the actual probe logic runs from a __constructor__
// function instead -- that's the only entry point dlopen will invoke.
#import <Foundation/Foundation.h>

__attribute__((constructor))
static void probe_target_loaded(void) {
    NSString *s = [NSString stringWithFormat:@"hello from target, %d", 42];
    NSArray *a = @[@1, @2, @3];
    NSLog(@"[TARGET] constructor ran: %@ count=%lu", s, (unsigned long)a.count);
}
