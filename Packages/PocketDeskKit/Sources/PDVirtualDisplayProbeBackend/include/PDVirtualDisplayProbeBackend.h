#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// This developer-only bridge is not linked by either PocketDesk app.
bool PDVDAvailable(char *error, size_t capacity);
uint32_t PDVDCreate(uint32_t width, uint32_t height, uint32_t serial, char *error, size_t capacity);
void PDVDDestroy(void);
