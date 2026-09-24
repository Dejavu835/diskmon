#ifndef DiskMonIOKitSMART_h
#define DiskMonIOKitSMART_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Native IOKit SMART (same path as Stats / DriveDx / diskutil keys).
/// Missing numeric fields are INT32_MIN; TB fields are -1.
typedef struct {
    int32_t celsius;
    int32_t percentUsed;
    int32_t availableSpare;
    int32_t powerOnHours;
    int32_t powerCycles;
    int32_t unsafeShutdowns;
    int32_t mediaErrors;
    int32_t criticalWarning;
    double dataUnitsReadTB;
    double dataUnitsWrittenTB;
    int32_t healthPassed; // 1 passed, 0 fail, -1 unknown
} DiskMonNativeSMART;

bool DiskMonReadNVMeSMART(const char *bsdName, DiskMonNativeSMART *out);
bool DiskMonReadATASMART(const char *bsdName, DiskMonNativeSMART *out);

#ifdef __cplusplus
}
#endif

#endif
