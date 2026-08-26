#ifndef SENDSPIN_CELLIGATOR_H
#define SENDSPIN_CELLIGATOR_H

#include <stdint.h>

/// Maps an RFC 7748 X25519 u-coordinate through RFC 9380 Elligator2.
void sendspin_cpace_map_to_curve(uint8_t out[32], const uint8_t in[32]);

#endif
