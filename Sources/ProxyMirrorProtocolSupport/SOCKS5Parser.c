#include "ProxyMirrorProtocolSupport.h"
#include <string.h>

int pm_socks5_greeting(const uint8_t *bytes, size_t count, size_t *consumed) {
    *consumed = 0;
    if (count < 2) return 0;
    if (bytes[0] != 5 || bytes[1] == 0) return -255;
    size_t total = 2 + (size_t)bytes[1];
    if (count < total) return 0;
    *consumed = total;
    for (size_t i = 2; i < total; ++i) if (bytes[i] == 0) return 1;
    return -255;
}

int pm_socks5_parse_request(const uint8_t *bytes, size_t count, pm_socks5_request *request) {
    memset(request, 0, sizeof(*request));
    if (count < 4) return 0;
    if (bytes[0] != 5 || bytes[2] != 0) return -1;
    if (bytes[1] != 1) return -7; /* CONNECT only, no BIND/UDP ASSOCIATE. */
    request->address_type = bytes[3];
    request->address_offset = 4;
    switch (bytes[3]) {
        case 1: request->address_length = 4; break;
        case 4: request->address_length = 16; break;
        case 3:
            if (count < 5) return 0;
            if (bytes[4] == 0) return -8;
            request->address_offset = 5;
            request->address_length = bytes[4];
            break;
        default: return -8;
    }
    size_t port_offset = request->address_offset + request->address_length;
    if (count < port_offset + 2) return 0;
    request->port = (uint16_t)(((uint16_t)bytes[port_offset] << 8) | bytes[port_offset + 1]);
    if (request->port == 0) return -8;
    request->consumed = port_offset + 2;
    return 1;
}
