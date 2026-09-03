#include "../LiveContainerRuntime/LiveContainer/EmberFortniteGuards.h"
#include <assert.h>
#include <stdio.h>

static void check_name(const char *text, bool expected) {
    uint16_t name[96] = {0};
    size_t n = strlen(text);
    for (size_t i = 0; i < n; i++) name[i] = (uint8_t)text[i];
    uintptr_t base = 0x120000000ULL, caller = base + 0x6287c0;
    assert(EmberFNAllowedFailure(0, caller, base, name, (int32_t)n + 1) == expected);
    assert(!EmberFNAllowedFailure(1, caller, base, name, (int32_t)n + 1));
    assert(!EmberFNAllowedFailure(0, caller + 4, base, name, (int32_t)n + 1));
    assert(!EmberFNAllowedFailure(0, caller, 0, name, (int32_t)n + 1));
    assert(!EmberFNAllowedFailure(0, caller, base, name, 0));
    assert(!EmberFNAllowedFailure(0, caller, base, name, -1));
    assert(!EmberFNAllowedFailure(0, caller, base, name, 97));
    assert(!EmberFNAllowedFailure(0, caller, base, NULL, (int32_t)n + 1));
    name[n] = 'x';
    assert(!EmberFNAllowedFailure(0, caller, base, name, (int32_t)n + 1));
}

int main(void) {
    puts("Starting Fortnite guard tests");
    fflush(stdout);
    check_name("com.apple.developer.kernel.extended-virtual-addressing", true);
    check_name("com.apple.developer.kernel.increased-memory-limit", true);
    check_name("get-task-allow", false);
    check_name("application-identifier", false);
    check_name("com.apple.developer.kernel.extended-virtual-addressing.extra", false);
    check_name("com.apple.developer.kernel.increased-memory-limi", false);
    check_name("", false);
    puts("PASS Fortnite failure guards: exact names/callsite/status; malformed inputs rejected");
    return 0;
}
