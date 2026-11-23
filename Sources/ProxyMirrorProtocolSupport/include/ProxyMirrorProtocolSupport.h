#ifndef PROXY_MIRROR_PROTOCOL_SUPPORT_H
#define PROXY_MIRROR_PROTOCOL_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Returns 0 when incomplete, 1 when accepted, -255 for no acceptable method. */
int pm_socks5_greeting(const uint8_t *bytes, size_t count, size_t *consumed);
typedef struct {
    size_t address_offset;
    size_t address_length;
    size_t consumed;
    uint16_t port;
    uint8_t address_type;
} pm_socks5_request;
/* Returns 0 when incomplete, 1 when parsed, or negative SOCKS5 reply code. */
int pm_socks5_parse_request(const uint8_t *bytes, size_t count, pm_socks5_request *request);
#ifdef __cplusplus
}
#endif
#endif
