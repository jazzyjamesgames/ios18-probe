// Private, undocumented -- Apple's old MessageTracer/ASL logging helper.
// Only one symbol referenced (confirmed via symbol recon: exactly one
// "(from libDiagnosticMessagesClient)" line). It's a logging function, so
// an empty body that touches none of its arguments is safe regardless of
// its real (unverified) signature -- on arm64 a function that never reads
// its incoming registers/stack args behaves identically no matter what the
// caller actually passed, same reasoning as the no-op DARegister*Callback
// stubs elsewhere in this project.
void msgtracer_log_with_keys(void) {}
