#include "RRSelection.h"

#include <limits.h>

static RRSelectionResult RROriginalTone(void) {
    RRSelectionResult result = { .toneIdentifier = NULL, .useOriginalTone = true };
    return result;
}

RRSelectionResult RRSelectTone(bool enabled,
                               bool hasContactSpecificTone,
                               const char *const *selectedToneIdentifiers,
                               size_t selectedToneCount,
                               RRBoundedRandomFunction randomFunction,
                               void *randomContext) {
    if (!enabled || hasContactSpecificTone || selectedToneIdentifiers == NULL ||
        selectedToneCount == 0 || selectedToneCount > UINT32_MAX ||
        randomFunction == NULL) {
        return RROriginalTone();
    }

    uint32_t index = randomFunction((uint32_t)selectedToneCount, randomContext);
    if (index >= selectedToneCount) {
        return RROriginalTone();
    }

    const char *toneIdentifier = selectedToneIdentifiers[index];
    if (toneIdentifier == NULL || toneIdentifier[0] == '\0') {
        return RROriginalTone();
    }

    RRSelectionResult result = { .toneIdentifier = toneIdentifier, .useOriginalTone = false };
    return result;
}
