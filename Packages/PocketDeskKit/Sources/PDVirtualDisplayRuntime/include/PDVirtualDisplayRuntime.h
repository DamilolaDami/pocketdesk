#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Mac-only runtime. Tokens own objects; capture IDs never authorize destruction.
bool PDVDAvailable(char *error, size_t capacity);
uint64_t PDVDCreate(uint32_t width, uint32_t height, double refreshRate, uint32_t serial, char *error, size_t capacity);
uint32_t PDVDCaptureID(uint64_t token);
bool PDVDDestroy(uint64_t token);

uint64_t PDVDCreateScaled(uint32_t width, uint32_t height, uint32_t scale, double refreshRate, uint32_t serial, char *error, size_t capacity);
bool PDVDConfigure(uint64_t token, uint32_t width, uint32_t height, uint32_t scale, double refreshRate, char *error, size_t capacity);
