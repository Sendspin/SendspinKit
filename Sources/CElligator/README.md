# CElligator

This target composes the RFC 9380 Elligator2 map for Curve25519 from libsodium ref10 field operations. It does not implement a scalar multiplication or a new field primitive.

The vendored files come from libsodium 1.0.21, revision `3e7548c62f68909461a67f396be0494584a7aae4`, and retain the upstream ISC license in `LICENSE`:

- `vendor/fe_25_5/fe.h`
- `vendor/fe_25_5/constants.h`
- `vendor/private/ed25519_ref10.h`
- `vendor/private/ed25519_ref10_fe_25_5.h`
- `vendor/private/common.h`
- `vendor/field.c` (the upstream `load_3`, `load_4`, `fe25519_invert`, `fe25519_pow22523`, `fe25519_cneg`, `fe25519_abs`, and `fe25519_sqmul` routines)
- `vendor/utils.h`
- `vendor/export.h`

`vendor/field.c` is compared with `crypto_core/ed25519/ref10/ed25519_ref10.c` at the pinned revision. Its routine bodies are byte-identical after these mechanical adaptations: the `fe25519_invert` and `fe25519_pow22523` definitions are renamed to `sendspin_fe25519_invert` and `sendspin_fe25519_pow22523` to avoid symbols from the linked Clibsodium binary; the upstream `fe25519_pow22523` definition is made externally visible for the composition; and only the headers needed by the 10-limb field path are included. `load_3` and `load_4` retain their upstream `static inline` definitions. The `fe25519_cneg`, `fe25519_abs`, and `fe25519_sqmul` helpers are included verbatim even though the current map does not call them.

`CElligator.c` contains only the RFC 9380 field-operation composition and the public map function.
