//  Exposes the vendored bcrypt-pbkdf (the seal side of bind key
//  passphrases — see CBcryptSeal/bcrypt-kdf.h) to Swift. Keep this header
//  to that one include: the project is Swift-first, and everything else
//  already crosses via modules.
#include "Models/Bind/CBcryptSeal/bcrypt-kdf.h"
