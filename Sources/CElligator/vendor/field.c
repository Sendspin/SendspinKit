#include <stdint.h>

static inline uint64_t
load_3(const unsigned char *in)
{
    uint64_t result;

    result = (uint64_t) in[0];
    result |= ((uint64_t) in[1]) << 8;
    result |= ((uint64_t) in[2]) << 16;

    return result;
}

static inline uint64_t
load_4(const unsigned char *in)
{
    uint64_t result;

    result = (uint64_t) in[0];
    result |= ((uint64_t) in[1]) << 8;
    result |= ((uint64_t) in[2]) << 16;
    result |= ((uint64_t) in[3]) << 24;

    return result;
}

#include "private/common.h"
#include "private/ed25519_ref10.h"
#include "utils.h"
#include "fe_25_5/constants.h"
#define fe25519_frombytes sendspin_fe25519_frombytes
#define fe25519_tobytes sendspin_fe25519_tobytes
#define fe25519_invert sendspin_fe25519_invert
#define fe25519_pow22523 sendspin_fe25519_pow22523
#include "fe_25_5/fe.h"

void
sendspin_fe25519_invert(fe25519 out, const fe25519 z)
{
    fe25519 t0;
    fe25519 t1;
    fe25519 t2;
    fe25519 t3;
    int     i;

    fe25519_sq(t0, z);
    fe25519_sq(t1, t0);
    fe25519_sq(t1, t1);
    fe25519_mul(t1, z, t1);
    fe25519_mul(t0, t0, t1);
    fe25519_sq(t2, t0);
    fe25519_mul(t1, t1, t2);
    fe25519_sq(t2, t1);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t2, t1);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t2, t2, t1);
    fe25519_sq(t3, t2);
    for (i = 1; i < 20; ++i) {
        fe25519_sq(t3, t3);
    }
    fe25519_mul(t2, t3, t2);
    for (i = 1; i < 11; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t2, t1);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t2, t2, t1);
    fe25519_sq(t3, t2);
    for (i = 1; i < 100; ++i) {
        fe25519_sq(t3, t3);
    }
    fe25519_mul(t2, t3, t2);
    for (i = 1; i < 51; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    for (i = 1; i < 6; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(out, t1, t0);
}

void
sendspin_fe25519_pow22523(fe25519 out, const fe25519 z)
{
    fe25519 t0;
    fe25519 t1;
    fe25519 t2;
    int     i;

    fe25519_sq(t0, z);
    fe25519_sq(t1, t0);
    fe25519_sq(t1, t1);
    fe25519_mul(t1, z, t1);
    fe25519_mul(t0, t0, t1);
    fe25519_sq(t0, t0);
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t1, t1, t0);
    fe25519_sq(t2, t1);
    for (i = 1; i < 20; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    for (i = 1; i < 11; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t1, t1, t0);
    fe25519_sq(t2, t1);
    for (i = 1; i < 100; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    for (i = 1; i < 51; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t0, t0);
    fe25519_sq(t0, t0);
    fe25519_mul(out, t0, z);
}

static inline void
fe25519_cneg(fe25519 h, const fe25519 f, unsigned int b)
{
    fe25519 negf;

    fe25519_neg(negf, f);
    fe25519_copy(h, f);
    fe25519_cmov(h, negf, b);
}

static inline void
fe25519_abs(fe25519 h, const fe25519 f)
{
    fe25519_cneg(h, f, fe25519_isnegative(f));
}

static inline void
fe25519_sqmul(fe25519 s, const int n, const fe25519 a)
{
    int i;

    for (i = 0; i < n; i++) {
        fe25519_sq(s, s);
    }
    fe25519_mul(s, s, a);
}
