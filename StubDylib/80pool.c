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
// It is also the hook. Anything you want injected for offline testing goes in
// the constructor below and arrives before the game's own main runs.

#include <stdio.h>

__attribute__((constructor))
static void ember_stub_init(void) {
    fprintf(stderr, "[Ember] 80pool stub loaded; mod menu is not present\n");
}
