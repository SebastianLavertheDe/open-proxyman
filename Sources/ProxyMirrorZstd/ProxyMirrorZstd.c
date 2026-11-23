#include "ProxyMirrorZstd.h"
/* Stable v1.5.7 public API declarations. Keep the generated single-file decoder
   intact so it can be reproduced and audited against upstream. */
typedef struct ZSTD_DCtx_s ZSTD_DStream;
typedef struct { const void *src; size_t size; size_t pos; } ZSTD_inBuffer;
typedef struct { void *dst; size_t size; size_t pos; } ZSTD_outBuffer;
extern ZSTD_DStream *ZSTD_createDStream(void);
extern size_t ZSTD_freeDStream(ZSTD_DStream *);
extern size_t ZSTD_initDStream(ZSTD_DStream *);
extern size_t ZSTD_DCtx_setParameter(ZSTD_DStream *, int, int);
extern unsigned ZSTD_isError(size_t);
extern size_t ZSTD_decompressStream(ZSTD_DStream *, ZSTD_outBuffer *, ZSTD_inBuffer *);

void *pm_zstd_create(void) {
    ZSTD_DStream *decoder = ZSTD_createDStream();
    if (!decoder) return NULL;
    /* ZSTD_d_windowLogMax = 100, with 2^25 = 32 MiB window. */
    if (ZSTD_isError(ZSTD_DCtx_setParameter(decoder, 100, 25)) ||
        ZSTD_isError(ZSTD_initDStream(decoder))) {
        ZSTD_freeDStream(decoder);
        return NULL;
    }
    return decoder;
}
void pm_zstd_destroy(void *decoder) { ZSTD_freeDStream((ZSTD_DStream *)decoder); }
int pm_zstd_decode(void *decoder, const void *input, size_t *input_size,
                   void *output, size_t *output_size) {
    ZSTD_inBuffer in = { input, *input_size, 0 };
    ZSTD_outBuffer out = { output, *output_size, 0 };
    size_t result = ZSTD_decompressStream((ZSTD_DStream *)decoder, &out, &in);
    *input_size = in.pos;
    *output_size = out.pos;
    return ZSTD_isError(result) ? -1 : result == 0 ? 0 : 1;
}
