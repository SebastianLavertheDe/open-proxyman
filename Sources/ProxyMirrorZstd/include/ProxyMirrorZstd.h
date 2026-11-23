#ifndef PROXY_MIRROR_ZSTD_H
#define PROXY_MIRROR_ZSTD_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Window memory is capped at 32 MiB independently of caller output limits. */
void *pm_zstd_create(void);
void pm_zstd_destroy(void *decoder);
/* Returns 0 at a complete frame, 1 while more input/output is required, -1 on error.
   input_size/output_size are capacities on entry and consumed/written on return. */
int pm_zstd_decode(void *decoder, const void *input, size_t *input_size,
                   void *output, size_t *output_size);
#ifdef __cplusplus
}
#endif
#endif
