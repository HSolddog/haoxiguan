"""Generate public synthetic protocol vectors with Python + system libsodium.
Run from repo root; this script never reads application data or credentials.
"""
import base64
import ctypes
import ctypes.util
import hashlib
import hmac
import json
from pathlib import Path

lib = ctypes.CDLL(ctypes.util.find_library('sodium'))
assert lib.sodium_init() >= 0
key = bytes(range(32))
id_key = bytes(range(32, 64))
nonce = bytes(range(24))
logical = 'records:synthetic-record'
entity = base64.urlsafe_b64encode(hmac.new(id_key, ('haoxiguan/entity/v1/' + logical).encode(), hashlib.sha256).digest()).decode().rstrip('=')
context = dict(vault='synthetic-vault', epoch='synthetic-epoch', entityId=entity, baseRevision=3, deleted=False)
compact = lambda value: json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
aad = compact(['haoxiguan-sync-object', 1, context['vault'], context['epoch'], entity, 3, False, 1])
payload = dict(habitId='synthetic-habit', date='2026-10-02', value=1250)
plaintext = compact(dict(logicalId=logical, payload=payload))
out = ctypes.create_string_buffer(len(plaintext) + 16)
out_len = ctypes.c_ulonglong()
f = lib.crypto_aead_xchacha20poly1305_ietf_encrypt
f.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong,
              ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
assert f(out, ctypes.byref(out_len), plaintext, len(plaintext), aad, len(aad), None, nonce, key) == 0
b64 = lambda value: base64.b64encode(value).decode()
wire = b64(compact(dict(v=1, generation=1, nonce=b64(nonce), ciphertext=b64(out.raw[:out_len.value]))))
vector = dict(description='Public synthetic Python ctypes/libsodium vector; not user credentials',
              keys=dict(format='haoxiguan-sync-keyring', version=1, vault=context['vault'], idKey=b64(id_key), currentGeneration=1, contentKeys={'1': b64(key)}),
              context=context, logicalId=logical, payload=payload, aadHex=aad.hex(), ciphertext=wire)
Path('test/fixtures/sync-v1-vector.json').write_text(json.dumps(vector, indent=2) + '\n')
