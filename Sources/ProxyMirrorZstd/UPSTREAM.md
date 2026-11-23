Zstandard decoder v1.5.7, https://github.com/facebook/zstd/tree/v1.5.7

`zstddeclib.c` is unmodified output of upstream's amalgamation tool:

    cd zstd-1.5.7/build/single_file_libs
    python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c

Source archive: https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7
SHA-256: 37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3

Used under the BSD license in LICENSE. Legacy pre-v0.8 frames and external
compression dictionaries are not enabled. The small ProxyMirrorZstd.c bridge
caps the streaming decoder window at 32 MiB. Swift separately caps produced
output and supports cancellation between 32 KiB chunks.
