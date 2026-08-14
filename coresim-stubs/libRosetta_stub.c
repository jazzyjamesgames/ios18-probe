// Real stub, not a placeholder: on iOS there is no such thing as a
// Rosetta-translated process, ever, on any device. "Not available / not
// applicable" isn't a guess standing in for unknown real behavior here --
// it's the actually correct answer these three functions can give.
//
// Exact signatures are unverified (symbol recon gives names, not types) --
// these are reasonable-guess C functions returning 0/NULL-equivalents. If
// CoreSimulator expects something more specific, a crash here is itself the
// next signal, same as everywhere else in this project.
int rosetta_is_translation_available(void) { return 0; }
int rosetta_get_expected_version(void) { return 0; }
int rosetta_get_runtime_version(void) { return 0; }
