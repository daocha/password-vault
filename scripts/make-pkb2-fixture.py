#!/usr/bin/env python3
"""Writes a SANITIZED Password Keeper .pkb2 test fixture (fake data, password "correct horse"), following the
app's own exporter: scrypt(N=65536,r=8,p=1) -> AES-CBC key wrap + HMAC-SHA256, then AES-CBC records + HMAC.
Needs the `cryptography` package.   scripts/make-pkb2-fixture.py android/app/src/test/resources/sample.pkb2
"""
import hashlib, hmac, os, struct, sys
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

PASSWORD = "correct horse"
# Hand-written JSON: the real exporter emits the key "t" twice inside historical-password subfields.
RECORDS = ('{"settings":{"cd":true},"records":['
  '{"u":"11111111111111111111111111111111","t":"p","fav":true,"lm":1700000000,"f":['
  '{"n":null,"v":"Sample login","t":"t"},{"n":null,"v":"example.com","t":"w"},{"n":null,"v":"alice","t":"u"},'
  '{"n":null,"v":"Pw-one-1!","t":"p","sf":[{"t":1700000000}]},{"n":null,"v":"first note","t":"n"},'
  '{"n":null,"v":"alice2","t":"u"},'
  '{"n":null,"v":"Pw-two-2!","t":"p","sf":[{"t":"hp","pw":"Older-pw-9!","t":1680000000},{"t":"hp","pw":"Old-pw-0!","t":1690000000},{"t":1700000000}]},'
  '{"n":null,"v":"second note","t":"n"},'
  '{"n":"First pet?","v":"Rex","t":"sq","sf":[{"t":1700000000}]},{"n":"Birth city?","v":"Paris","t":"sq"},'
  '{"n":null,"v":"second.example.com","t":"w"},{"n":"Work login","v":"bob","t":"u"},{"n":null,"v":"Pw-three-3!","t":"p"},'
  '{"n":"Previous password","v":"typed-by-hand","t":"p"},'
  '{"n":null,"v":"","t":"i"}]},'
  '{"u":"22222222222222222222222222222222","t":"n","fav":false,"lm":1700000100,"f":[{"n":null,"v":"Secure note","t":"t"},{"n":null,"v":"line1\\nline2 \\u00e9","t":"n"}]},'
  '{"u":"33333333333333333333333333333333","t":"l","fav":false,"lm":1700000200,"f":[{"n":null,"v":"Shopping","t":"t"},'
  '{"n":"Items","v":"","t":"lst","sf":[{"t":"chk","lst_lbl":"milk","lst_chk":true,"lst_ord":1},{"t":"chk","lst_lbl":"eggs","lst_chk":false,"lst_ord":0}]}]}'
  ']}')

def cbc_encrypt(key, iv, data):
    p = padding.PKCS7(128).padder(); data = p.update(data) + p.finalize()
    e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor(); return e.update(data) + e.finalize()
mac = lambda k, m: hmac.new(k, m, hashlib.sha256).digest()

salt, iv = os.urandom(32), os.urandom(16)
dk = Scrypt(salt=salt, length=64, n=65536, r=8, p=1).derive(PASSWORD.encode())
rk, rmk, riv = os.urandom(32), os.urandom(32), os.urandom(16)
keys = cbc_encrypt(dk[:32], iv, rk + rmk + riv); recs = cbc_encrypt(rk, riv, RECORDS.encode())
out = b"PKB2" + struct.pack(">I", 2) + salt + iv + struct.pack(">I", len(keys)) + keys + mac(dk[32:], keys) + struct.pack(">I", len(recs)) + recs + mac(rmk, recs)
open(sys.argv[1], "wb").write(out); print("wrote", sys.argv[1], len(out), "bytes")
