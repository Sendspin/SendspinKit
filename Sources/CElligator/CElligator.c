#include "CElligator.h"

#include <stdint.h>
#include <string.h>

static uint64_t load_3(const unsigned char *in)
{
    return (uint64_t) in[0] | ((uint64_t) in[1] << 8) | ((uint64_t) in[2] << 16);
}

static uint64_t load_4(const unsigned char *in)
{
    return (uint64_t) in[0] | ((uint64_t) in[1] << 8) |
           ((uint64_t) in[2] << 16) | ((uint64_t) in[3] << 24);
}

#include "private/ed25519_ref10.h"
#define fe25519_frombytes sendspin_fe25519_frombytes_inline
#define fe25519_tobytes sendspin_fe25519_tobytes_inline
#define fe25519_invert sendspin_fe25519_invert
#include "fe_25_5/constants.h"
#include "fe_25_5/fe.h"

void sendspin_fe25519_invert(fe25519 out, const fe25519 z);
void sendspin_fe25519_pow22523(fe25519 out, const fe25519 z);

/*
 * Field operations and inversion come from libsodium 1.0.21, commit
 * 3e7548c62f68909461a67f396be0494584a7aae4 (ref10). This composition uses
 * the libsodium ISC license; see LICENSE. Vendored files:
 * private/common.h, private/ed25519_ref10.h, private/ed25519_ref10_fe_25_5.h,
 * fe_25_5/constants.h, fe_25_5/fe.h, utils.h, and export.h.
 */

void sendspin_cpace_map_to_curve(uint8_t out[32], const uint8_t in[32])
{
    fe25519 r, denominator, v, gx1, t, chi, alternate;
    fe25519_frombytes(r, in);
    fe25519_sq(t, r);
    fe25519_mul32(t, t, 2);
    fe25519_1(denominator);
    fe25519_add(denominator, denominator, t);
    fe25519_invert(denominator, denominator);
    fe25519_mul(v, curve25519_A, denominator);
    fe25519_neg(v, v);
    fe25519_sq(t, v);
    fe25519_mul(gx1, t, v);
    fe25519_mul(t, curve25519_A, v);
    fe25519_mul(t, t, v);
    fe25519_add(gx1, gx1, t);
    fe25519_add(gx1, gx1, v);
    sendspin_fe25519_pow22523(chi, gx1);
    fe25519_sq(t, chi);
    fe25519_sq(t, t);
    fe25519_sq(alternate, gx1);
    fe25519_mul(chi, t, alternate);
    fe25519_neg(alternate, v);
    fe25519_sub(alternate, alternate, curve25519_A);
    fe25519_1(t);
    fe25519_add(t, t, chi);
    fe25519_copy(chi, t);
    fe25519_copy(t, v);
    fe25519_cmov(t, alternate, fe25519_iszero(chi));
    sendspin_fe25519_tobytes_inline(out, t);
}
