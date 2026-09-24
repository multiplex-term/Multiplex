/*
 * OpenBSD's bcrypt_pbkdf (ISC-style license, see bcrypt-kdf.c), vendored
 * from Citadel's CCitadelBcrypt copy with two Multiplex changes: every
 * symbol is prefixed `mpxbind_` so it can never collide with Citadel's own
 * objects in the app binary, and SHA-512 comes from CommonCrypto directly
 * instead of a caller-registered function pointer. This is the ENCRYPT-side
 * KDF for sealing a bind's SSH key in the standard openssh-key-v1 format;
 * Citadel's independent copy is the decrypt side, which is exactly what
 * makes the round-trip test meaningful.
 */

#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <inttypes.h>

int
mpxbind_bcrypt_pbkdf(const unsigned char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                     uint8_t *key, size_t keylen, unsigned int rounds);
