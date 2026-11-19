# BIP-39 test vectors

`english-vectors.tsv` holds every English vector from the BIP-39 reference implementation,
[trezor/python-mnemonic](https://github.com/trezor/python-mnemonic) `vectors.json` (commit
`b57a5ad77a981e743f4167ab2f7927a55c1e82a8`, file SHA-256 `fa3b937b7cff9c9b8ecd3aa011faeb8d6dd67993174b72326e83f4de8fdb30f8`),
MIT licensed. Each line is the entropy in hex, a tab, and the mnemonic. The seeds and extended keys in the original are left out:
PassVault stores phrases and never derives seeds.

The list covers 16, 24 and 32 bytes of entropy (12, 18 and 24 words). Both apps' tests read this file, so their BIP-39 encoding is
checked against phrases they did not produce.

Extracted with:

```
python3 -c 'import json; [print(e + "\t" + m) for e, m, *_ in json.load(open("vectors.json"))["english"]]' > english-vectors.tsv
```
