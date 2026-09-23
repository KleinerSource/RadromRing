#include "RRSelection.h"

#include <assert.h>
#include <stdio.h>

typedef struct {
    uint32_t value;
    uint32_t observedUpperBound;
} RRStubRandom;

static uint32_t RRStubRandomValue(uint32_t upperBound, void *context) {
    RRStubRandom *stub = (RRStubRandom *)context;
    stub->observedUpperBound = upperBound;
    return stub->value;
}

static void RRAssertOriginal(RRSelectionResult result) {
    assert(result.useOriginalTone);
    assert(result.toneIdentifier == NULL);
}

static void RRTestDisabledUsesOriginal(void) {
    const char *selected[] = { "tone-a" };
    RRStubRandom stub = { .value = 0, .observedUpperBound = 0 };
    RRAssertOriginal(RRSelectTone(false, false, selected, 1, RRStubRandomValue, &stub));
    assert(stub.observedUpperBound == 0);
}

static void RRTestContactToneUsesOriginal(void) {
    const char *selected[] = { "tone-a" };
    RRStubRandom stub = { .value = 0, .observedUpperBound = 0 };
    RRAssertOriginal(RRSelectTone(true, true, selected, 1, RRStubRandomValue, &stub));
    assert(stub.observedUpperBound == 0);
}

static void RRTestEmptyPoolUsesOriginal(void) {
    RRStubRandom stub = { .value = 0, .observedUpperBound = 0 };
    RRAssertOriginal(RRSelectTone(true, false, NULL, 0, RRStubRandomValue, &stub));
    assert(stub.observedUpperBound == 0);
}

static void RRTestSelectsFromConfiguredPool(void) {
    const char *selected[] = { "tone-a", "tone-b", "tone-c" };
    RRStubRandom stub = { .value = 1, .observedUpperBound = 0 };
    RRSelectionResult result = RRSelectTone(true, false, selected, 3,
                                            RRStubRandomValue, &stub);
    assert(!result.useOriginalTone);
    assert(result.toneIdentifier == selected[1]);
    assert(stub.observedUpperBound == 3);
}

static void RRTestInvalidCandidateUsesOriginal(void) {
    const char *selected[] = { "tone-a", NULL };
    RRStubRandom stub = { .value = 1, .observedUpperBound = 0 };
    RRAssertOriginal(RRSelectTone(true, false, selected, 2, RRStubRandomValue, &stub));
}

static void RRTestOutOfRangeRandomValueUsesOriginal(void) {
    const char *selected[] = { "tone-a" };
    RRStubRandom stub = { .value = 4, .observedUpperBound = 0 };
    RRAssertOriginal(RRSelectTone(true, false, selected, 1, RRStubRandomValue, &stub));
}

int main(void) {
    RRTestDisabledUsesOriginal();
    RRTestContactToneUsesOriginal();
    RRTestEmptyPoolUsesOriginal();
    RRTestSelectsFromConfiguredPool();
    RRTestInvalidCandidateUsesOriginal();
    RRTestOutOfRangeRandomValueUsesOriginal();
    puts("RRSelection tests passed");
    return 0;
}
