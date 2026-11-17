#ifndef PROXY_MIRROR_AUTHORIZED_INSTALLER_H
#define PROXY_MIRROR_AUTHORIZED_INSTALLER_H

#include <Security/Authorization.h>
#include <stdio.h>

OSStatus PMExecuteAuthorizedSystemProxyInstaller(
    AuthorizationRef _Nonnull authorization,
    char * _Nullable const * _Nonnull arguments,
    FILE * _Nullable * _Nonnull communicationsPipe);

#endif
