#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static inline bool EmberFNAllowedFailure(int status, uintptr_t caller, uintptr_t base,
                                         const uint16_t *name, int32_t length) {
    if (!base || status != 0 || caller != base + 0x6287c0 ||
        !name || length <= 1 || length > 96 || name[length - 1] != 0) return false;
    const char *allowed[] = {"com.apple.developer.kernel.extended-virtual-addressing",
                             "com.apple.developer.kernel.increased-memory-limit"};
    for (unsigned i = 0; i < 2; i++) {
        size_t n = strlen(allowed[i]);
        if ((size_t)length != n + 1) continue;
        bool equal = true;
        for (size_t j = 0; j < n; j++) if (name[j] != (uint8_t)allowed[i][j]) equal = false;
        if (equal) return true;
    }
    return false;
}
