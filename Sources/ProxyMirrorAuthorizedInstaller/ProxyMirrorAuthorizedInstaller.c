#include "ProxyMirrorAuthorizedInstaller.h"

OSStatus PMExecuteAuthorizedSystemProxyInstaller(
    AuthorizationRef authorization,
    char *const *arguments,
    FILE **communicationsPipe)
{
    // The SDK exposes this legacy installer API to C. The App obtains the right
    // first. Long-running work belongs to the installed launchd service.
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = AuthorizationExecuteWithPrivileges(
        authorization, "/usr/bin/env", kAuthorizationFlagDefaults, arguments, communicationsPipe);
    #pragma clang diagnostic pop
    return status;
}
