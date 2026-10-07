# nomouse-helper

The root helper behind [nomouse](https://nomouse.app), the macOS app that drives
the mouse from the keyboard.

This helper runs as root and reads raw keystrokes. That is exactly what a
keylogger does, so its source is published here: you can see what it does
with your keys before you trust it. It's about 1,000 lines of Swift, small
enough to read in an afternoon.

## Why it exists

When a password field or `sudo` prompt has focus, macOS turns on **Secure
Input**. A normal app's event tap stops receiving keys while it's on, so
keyboard tools stop working right where you're typing. Only the IOKit HID
layer, below Secure Input, can still see keys, and opening a HID keyboard
there requires root.

The helper reads the keyboard at the HID layer. When nomouse enters free mode
or grid mode, the helper briefly takes exclusive control of the keyboard, so
those keys move the pointer instead of reaching the focused field. It then
forwards keys to the nomouse app over a local socket. The app does
everything else: it moves the pointer and clicks with the normal macOS event
APIs, which Secure Input doesn't block.

It reads the **Karabiner-Elements virtual keyboard** (vendor 1452, product 591),
so Karabiner-Elements must be installed. It never touches your physical keyboard
device directly.

## What it does and doesn't do

| Claim | Where to check |
|---|---|
| **Never writes keystrokes to disk.** The log only records start/stop, device and connection events. | Every `NSLog` in `Sources/` |
| **Only the signed nomouse app can connect.** Each connection's kernel audit token is checked against a code-signing requirement: an Apple-issued certificate for team `3CK2XS2T3D`, identifier `com.tienthuan.glide`. Other apps running as you are refused. Root is allowed, because root can already read the keyboard. | `IPCServer.swift` `verifyPeerCredentials`, `clientRequirement` |
| **While idle, ordinary typing is never sent, not even to the app.** It forwards only modifier keys (⇧⌃⌥⌘Fn) and ⌃/⌘/Fn+key shortcuts, which the app needs to notice "tap ⌥" or "⌘⇧Space". ⇧/⌥ combos type characters, so they are sent only as "a key was pressed", with no key identity. Everything else is dropped. | `IdleKeyGate.swift`, `main.swift` `handleKeyEvent` |
| **Only two commands do anything: capture keys and release keys.** It can't move the mouse, type keys, or run anything. Every other message type is ignored. | `main.swift` `handleCommand` |
| **Can't leave your keyboard stuck.** The keyboard is released after 30 s with no activity, when the app disconnects, quits or crashes, and on SIGTERM/SIGINT. | `main.swift` `watchdogTimeout`, `onClientDisconnected`, `shutdown` |
| **No network access.** It uses only a Unix socket at `/var/run/mouseless.sock`. | `IPCServer.swift` (`AF_UNIX` only) |

The socket file is world-writable (`0666`) so that whoever is logged in can
reach it. Access control comes from the audit-token and code-signature check
above, not from file permissions.

## Verify it yourself

```bash
swift build -c release   # the exact binary scripts/install.sh installs
swift test               # IdleKeyGate privacy contract

sudo launchctl list | grep com.mouseless.daemon     # is it running?
ls -l /var/run/mouseless.sock

# Type in a password field, then check the log: there should be no key entries
tail -f /var/log/mouseless-daemon.log

# Try to connect as yourself without being the signed app: you're refused
nc -U /var/run/mouseless.sock </dev/null; grep rejected /var/log/mouseless-daemon.log | tail -1
```

## Build and install from source

Requires macOS 13+, Swift 5.9+ (Xcode 15+), and Karabiner-Elements.

```bash
scripts/install.sh     # builds, installs to /usr/local/bin, loads the LaunchDaemon
scripts/uninstall.sh   # removes the binary, plist, socket and log
```

After installing, open **System Settings → Privacy & Security → Input
Monitoring**, click **+**, press ⌘⇧G, enter `/usr/local/bin/mouseless-daemon`,
and turn it on. Then run `sudo launchctl kickstart -k system/com.mouseless.daemon`.
Without this permission macOS refuses to open the keyboard, and the log shows
`failed 0xe00002e2`. A plain `swift build` is ad-hoc signed, and macOS ties the
permission to that exact binary. So either grant it again after each rebuild,
or sign the binary with your own certificate and a stable identifier
(`codesign --force --sign "<identity>" --identifier com.mouseless.daemon …`).

If you build your own copy of the app, change `clientRequirement` in
`IPCServer.swift` to match your signing identity. Otherwise the helper will
refuse your app.

## Naming

The helper still uses its pre-release identifiers: the `mouseless-daemon`
binary, the `com.mouseless.daemon` label, and `/var/run/mouseless.sock`. It is
not affiliated with any other product named "Mouseless".

## Reporting a security issue

Email **hello@nomouse.app** with "security" in the subject. Please don't open
a public issue for anything exploitable.

## License

[MIT](LICENSE). This covers only this helper; the nomouse app is not part of
this repository.
