// Replacement for the mod menu's 80pool.dylib.
//
// The game's executable carries a hard `LC_LOAD_DYLIB @rpath/80pool.dylib`.
// Removing that command, or weakening it, means editing the main binary — and
// on this device any edit to the executable makes iOS kill the app at launch
// with CODESIGNING / Invalid Page, because the re-signer preserves the
// original page hashes rather than recomputing them. Unmodified binaries sign
// and run; modified ones never load.
//
// So the executable is left completely alone and this stands in for the mod at
// the path it already loads. It does nothing, which is the point: the mod menu
// is gone and the load command is satisfied.
//
// The game imports zero symbols from this library, so the replacement needs
// no initializer, hooks, logging, or external dependencies. Keep one inert
// exported function only so the compiler emits a normal loadable dylib.

void ember_80pool_compatibility_stub(void) {}
