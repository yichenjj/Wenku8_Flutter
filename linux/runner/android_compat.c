// Symbols the API runtime (libcpp.so, built against Android bionic) expects to
// resolve. The patched library binds everything else against glibc; these four
// only exist on Android, so the executable exports them (see --export-dynamic).
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

int* __errno(void) { return __errno_location(); }

void android_set_abort_message(const char* message) {
  fprintf(stderr, "[api-runtime] %s\n", message ? message : "");
  abort();
}

// Bionic's stdio table. Only needed for symbol resolution; the invoked API
// paths never stream through these handles.
char __sF[3 * 512];
