#ifndef RR_SELECTION_H
#define RR_SELECTION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef uint32_t (*RRBoundedRandomFunction)(uint32_t upperBound, void *context);

typedef struct {
    const char *toneIdentifier;
    bool useOriginalTone;
} RRSelectionResult;

/* selectedToneIdentifiers must already be filtered against the live system catalog. */
RRSelectionResult RRSelectTone(bool enabled,
                               bool hasContactSpecificTone,
                               const char *const *selectedToneIdentifiers,
                               size_t selectedToneCount,
                               RRBoundedRandomFunction randomFunction,
                               void *randomContext);

#endif
