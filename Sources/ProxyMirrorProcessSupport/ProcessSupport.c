#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include "ProxyMirrorProcessSupport.h"
#include <spawn.h>
#include <errno.h>

int pm_posix_spawn_file_actions_addclosefrom(void *actions,
                                           int first_descriptor) {
#if defined(__linux__)
    return posix_spawn_file_actions_addclosefrom_np((posix_spawn_file_actions_t *)actions,
                                                   first_descriptor);
#else
    /* Darwin callers already use POSIX_SPAWN_CLOEXEC_DEFAULT. */
    (void)actions;
    (void)first_descriptor;
    return ENOTSUP;
#endif
}
