# Bundled browser signing certificates

`android/app/src/main/resources/privileged_browsers.json` is copied unchanged from
<https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json>, Google's list of browsers allowed to make passkey requests for websites,
with the SHA-256 fingerprints of their signing certificates.

- Downloaded: 2026-10-31
- SHA-256: `0891ee2507894999ead3eb4f42e17936a2e8ed8f8fd95592535c9811ef319481`

Autofill believes the website a browser reports only when the browser's package is in `AutofillTarget.BROWSERS`, is in this list, and is
signed with one of its `release` certificates (`AutofillBrowsers`). Any app can take a browser's package name when that browser is not
installed; this check is what stops it from claiming any site. `userdebug` certificates and the list's non-browser apps are ignored.
Browsers on `BROWSERS` that are not in this list (Tor Browser, F-Droid Firefox forks, Kiwi, Via and others) are matched as ordinary apps.

The app reads only this bundled file and never downloads updates. To refresh it, download it from the URL above, update the date and
hash here, and keep the manifest's `<queries>` in step (`AutofillBrowsersTest` fails until they match).
