# Transfer files

Phone-to-phone transfers (`PVXFER01`, see `docs/FORMAT.md`) written by each app, so each app's tests open the other's:

| File | Written by | Code | Records |
| --- | --- | --- | --- |
| `ios.pvtransfer` | iOS checks (`PASSVAULT_WRITE_TRANSFER_FIXTURE=1 swift run vault-security-checks`) | `PHNE-2C3D-E4FG` | "From iOS" (login), "iOS note" (secure note) |
| `android.pvtransfer` | Android instrumented test `transfersOpenAcrossPlatforms` (logged to logcat as `PassVaultFixture`) | `ANDR-D2CD-E3FG` | "From Android" (login), "Android card" (card) |

They hold no real data.
