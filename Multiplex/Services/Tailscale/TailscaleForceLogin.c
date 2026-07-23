// tsnet only consumes a configured auth key inside its
// StartLoginInteractive branch, and reaches that branch when the backend
// state is NeedsLogin OR the TSNET_FORCE_LOGIN env knob is set. A fresh
// state store reads as NoState at that check, so a first-ever login with
// an auth key is silently skipped ("Authkey is set; but state is NoState.
// Ignoring authkey." — tsnet v1.94.1, tsnet.go:763-770, observed on
// device 2026-07-23).
//
// The knob must be in the environment BEFORE the Go runtime captures it,
// which happens in the libtailscale archive's own load-time constructor —
// a setenv from Swift is too late. This constructor is compiled into the
// app's object files, which the linker places ahead of OTHER_LDFLAGS
// libraries, so its mod_init_func entry runs first.
//
// The knob is set ONLY while the tsnet state file does not exist: forcing
// it unconditionally would make every tailscale_up on an already-enrolled
// node re-run interactive login (env values are frozen for the process
// lifetime once Go captures them). On visionOS the file compiles and the
// state path never exists, but nothing links or reads the knob — inert.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor))
static void multiplex_tsnet_force_login(void) {
    const char *home = getenv("HOME");
    if (home == NULL) {
        return;
    }
    char path[1024];
    int written = snprintf(
        path, sizeof path,
        "%s/Library/Application Support/tailscale-node/tailscaled.state",
        home);
    if (written <= 0 || (size_t)written >= sizeof path) {
        return;
    }
    if (access(path, F_OK) != 0) {
        setenv("TSNET_FORCE_LOGIN", "1", 1);
    }
}
