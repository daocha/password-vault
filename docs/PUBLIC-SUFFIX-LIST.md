# Bundled Public Suffix List

`android/app/src/main/resources/public_suffix_list.dat` is copied unchanged from
<https://publicsuffix.org/list/public_suffix_list.dat>. It includes both ICANN and private-domain rules.

- Version: `2026-10-28_13-15-55_UTC`
- Upstream commit: `9dfbe81931367b3f0af21035c36ae7eeb830dd88`
- SHA-256: `1f96bae40adfc22ca2474d7c0099bbcfcb25aefd3e2547b5c2147c0dd2e3ebd9`
- License: Mozilla Public License 2.0; the upstream license notice is preserved at the start of the file.

The app reads only this bundled resource and never downloads list updates. Refresh it from the official URL when maintaining the app,
preserve the license notice, update the provenance above, and run the domain-matching tests. Autofill uses wildcard and exception rules,
keeps private hosting tenants separate, compares IP addresses as complete literals, and refuses lossy or ambiguous host encodings.

Domain and app-name matches only rank suggestions. They never authorize filling without the explicit destination confirmation.
