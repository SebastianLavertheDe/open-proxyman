#ifndef PROXY_MIRROR_PROCESS_SUPPORT_H
#define PROXY_MIRROR_PROCESS_SUPPORT_H

/* Keep GNU-only declarations inside the C implementation. Swift's Glibc
 * importer does not expose addclosefrom_np with the Ubuntu 22.04 headers.
 * The opaque pointer also keeps this shim from importing a second copy of
 * libc's platform-specific posix_spawn record definitions into Swift. */
int pm_posix_spawn_file_actions_addclosefrom(void *actions,
                                           int first_descriptor);

#endif
