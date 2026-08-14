// Deliberately empty. Used for the dependencies where symbol recon found
// zero (DiskArbitration bucket exceptions aside) or unimplemented-for-wave-1
// referenced symbols: DiskArbitration, ROCKit, DeviceIdentity,
// CoreSimulatorUtilities, libxcselect, CoreServices, SimPasteboardPlus.
// The point of wave 1 isn't to guess ~90 symbols' behavior blind -- it's to
// let dyld's own binding error name the *actual* first one CoreSimulator
// needs, the same "let it fail and read the message" approach used
// throughout this whole project. This file only needs to compile into a
// valid, loadable dylib; it doesn't need to export anything yet.
static void unused(void) {}
