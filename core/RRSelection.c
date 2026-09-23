#include "RRSelection.h"

#include <limits.h>
#include <string.h>

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

RRSelectionResult RRSelectToneAvoidingPrevious(bool enabled,
                                               bool hasContactSpecificTone,
                                               const char *const *selectedToneIdentifiers,
                                               size_t selectedToneCount,
                                               const char *previousToneIdentifier,
                                               RRBoundedRandomFunction randomFunction,
                                               void *randomContext) {
    if (!enabled || hasContactSpecificTone || selectedToneIdentifiers == NULL ||
        selectedToneCount == 0 || selectedToneCount > UINT32_MAX ||
        randomFunction == NULL) {
        return RROriginalTone();
    }

    size_t previousIndex = selectedToneCount;
    if (previousToneIdentifier != NULL && selectedToneCount > 1) {
        for (size_t index = 0; index < selectedToneCount; index++) {
            const char *candidate = selectedToneIdentifiers[index];
            if (candidate != NULL && strcmp(candidate, previousToneIdentifier) == 0) {
                previousIndex = index;
                break;
            }
        }
    }
    if (previousIndex == selectedToneCount) {
        return RRSelectTone(enabled, hasContactSpecificTone, selectedToneIdentifiers,
                            selectedToneCount, randomFunction, randomContext);
    }

    /* Draw from the other candidates, then skip over the previous slot. */
    uint32_t index = randomFunction((uint32_t)(selectedToneCount - 1), randomContext);
    if (index >= selectedToneCount - 1) {
        return RROriginalTone();
    }
    if (index >= previousIndex) index++;

    const char *toneIdentifier = selectedToneIdentifiers[index];
    if (toneIdentifier == NULL || toneIdentifier[0] == '\0') {
        return RROriginalTone();
    }

    RRSelectionResult result = { .toneIdentifier = toneIdentifier, .useOriginalTone = false };
    return result;
}
