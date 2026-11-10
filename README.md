# Sendbay

Native macOS app for copying files to and from Android phones over USB (MTP).
Swift + SwiftUI, no Electron. About 1.6 MB on disk and ~50 MB of memory.

## Install

Download `Sendbay-<version>.dmg` from the
[latest release](https://github.com/hariantara/sendbay/releases/latest), open it
and drag Sendbay into Applications. Requires macOS 14+ on Apple Silicon.

The app is not notarized yet, so macOS blocks it on first launch. Either
right-click Sendbay.app → Open → Open, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Sendbay.app
```

## Layout

- `Sources/MTPKit` – pure-Swift PTP/MTP protocol (no USB code), plus an
  in-memory `MockMTPDevice` used by tests and `--mock-device`.
- `Sources/SendbayUSB` – libusb transport, macOS camera-daemon eviction
  (`ptpcamerad` / `mscamerad-xpc`), IOKit plug/unplug monitor.
- `Sources/Sendbay` – the SwiftUI app.
- `Sources/sendbay-probe` – diagnostic CLI: connects and prints what it sees.

## Commands

```sh
swift test                      # unit tests (MTP protocol, framing, import planning)
./scripts/build-app.sh          # builds build/Sendbay.app (ad-hoc signed)
./scripts/make-dmg.sh           # packages it into build/Sendbay-<version>.dmg
./scripts/make-icons.sh         # re-render the app icon (all sizes)
swift run sendbay-probe         # connection diagnostics against a real phone
swift run Sendbay --mock-device # run the app against the simulated phone

# UI tests (XCUITest via a generated Xcode project; needs `brew install xcodegen`)
xcodegen generate
xcodebuild test -project SendbayUI.xcodeproj -scheme SendbayApp -destination 'platform=macOS'
```

Logs: `log stream --info --predicate 'subsystem == "com.hariantara.sendbay"'`

## Why the phone "disappears" on other apps

macOS' camera daemons grab the phone's MTP interface exclusively. launchd
restarts them within milliseconds, so Sendbay SIGKILLs them and claims the
interface in the same tight loop, with no sleeping in between. On sleep it
closes the session; on wake and on any USB change it reconnects with backoff.

## Licensing notes

The MTP code is written from scratch in Swift, following the MTP spec and the
behaviour of OpenMTP (MIT) and go-mtpfs (BSD-3). libusb (LGPL-2.1) is linked
dynamically and shipped as a separate dylib in the app bundle.
