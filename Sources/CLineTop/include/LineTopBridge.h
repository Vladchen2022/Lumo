#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// RGBA rows and the returned alpha mask share the caller's pixel orientation.
bool LumoExtractLineMask(const uint8_t *rgba, size_t width, size_t height,
                         bool photoLike, double edgeStrength, double contrast,
                         double brightness, double thickness, uint8_t *alpha);
#ifdef __cplusplus
}
#endif
