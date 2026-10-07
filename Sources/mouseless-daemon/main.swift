import Foundation

// MouselessDaemon (root)
//
// Reads the Karabiner DriverKit Virtual HID Keyboard at the HID layer (below
// macOS Secure Input) and SEIZES it while the app's overlay / free mode is
// active, so grid keys are swallowed and never reach the focused app — even in
// password fields. Keys are forwarded to Glide.app over a UNIX socket; the app
// decides per key whether it's a grid command (consume) or should pass through.
//
// Mouse output is NOT handled here — the app posts CGEvents directly (Secure
// Input doesn't block synthetic mouse output). So there is no DriverKit/dext
// dependency: idle = observe (keys reach the OS), active = seize (keys consumed
// or explicitly re-injected on passthrough).

let grabber = KeyboardGrabber()
let ipcServer = IPCServer()

private let stateQueue = DispatchQueue(label: "com.mouseless.daemon-state")
private var _mouselessActive = false

/// Safety watchdog: if the app holds the seize for longer than this without any
/// activity (or never releases it because it hung/crashed without closing the
/// socket), auto-release so the keyboard can never get stuck captured.
private let watchdogTimeout: TimeInterval = 30
private var watchdogTimer: DispatchSourceTimer?

var mouselessActive: Bool {
    get { stateQueue.sync { _mouselessActive } }
    set { stateQueue.sync { _mouselessActive = newValue } }
}

// MARK: - seize control

/// Enter active mode: seize the virtual keyboard so keys go only to the daemon.
func activate() {
    mouselessActive = true
    grabber.setSeized(true)
    armWatchdog()
    NSLog("mouseless-daemon: activated (seized)")
}

/// Leave active mode: release the seize so keys reach the OS again.
func deactivate(reason: String) {
    mouselessActive = false
    grabber.setSeized(false)
    cancelWatchdog()
    NSLog("mouseless-daemon: deactivated (%@)", reason)
}

private func armWatchdog() {
    cancelWatchdog()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + watchdogTimeout)
    timer.setEventHandler {
        NSLog("mouseless-daemon: WATCHDOG fired — auto-releasing seize")
        deactivate(reason: "watchdog timeout")
    }
    watchdogTimer = timer
    timer.resume()
}

private func cancelWatchdog() {
    watchdogTimer?.cancel()
    watchdogTimer = nil
}

/// Refresh the watchdog deadline on activity so a genuinely-in-use session
/// isn't force-released mid-use.
private func pokeWatchdog() {
    guard mouselessActive else { return }
    armWatchdog()
}

// MARK: - key forwarding

/// Runs on the main runloop (HID callbacks are scheduled there).
private var idleGate = IdleKeyGate()

func handleKeyEvent(_ event: KeyEventMessage) {
    pokeWatchdog()
    // While idle the app still needs activation hotkeys to DECIDE to enter a
    // mode and ask us to seize (chicken-and-egg otherwise), but idle is also
    // when the user is typing into a password field. IdleKeyGate forwards only
    // modifiers and ⌃/⌘/Fn chords; plain typing is dropped or redacted.
    //
    // When idle the device is opened SHARED, so the OS also receives the key
    // (normal typing keeps working). When seized, the OS does NOT get it, so the
    // app's decision (grid command vs. nothing) is authoritative.
    //
    // Never log key identities: this process sees passwords.
    guard let client = ipcServer.activeClient,
          let outgoing = idleGate.filter(event, modeActive: mouselessActive) else { return }
    client.sendKeyEvent(outgoing)
}

// MARK: - commands from the app

func handleCommand(_ command: DaemonCommand) {
    switch command {
    case .activateOverlay:
        activate()
    case .deactivateOverlay:
        deactivate(reason: "app request")
    case .consumeKey, .passthroughKey:
        // Seize means the OS never saw the key, so "consume" is a no-op and
        // "passthrough" would require re-injecting through a virtual keyboard.
        // The app currently swallows everything while a mode is active (and
        // passes unbound keys through to itself), so nothing is needed here.
        // Refresh the watchdog as a sign of life.
        pokeWatchdog()
    default:
        // All mouse/scroll commands are obsolete — the app posts CGEvents
        // directly and never sends them here. Ignore defensively.
        break
    }
}

// MARK: - lifecycle

func setupSignalHandlers() {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler { shutdown() }
    termSource.resume()

    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSource.setEventHandler { shutdown() }
    intSource.resume()

    _retainedSignalSources = [termSource, intSource]
}

private var _retainedSignalSources: [DispatchSourceSignal] = []

func shutdown() {
    NSLog("mouseless-daemon: shutting down")
    grabber.release() // always drops the seize first
    ipcServer.stop()
    exit(0)
}

func main() {
    NSLog("mouseless-daemon: starting")

    setupSignalHandlers()

    do {
        ipcServer.onCommand = { command in
            handleCommand(command)
        }

        ipcServer.onClientDisconnected = {
            // The app went away — never leave the keyboard seized.
            deactivate(reason: "client disconnected")
        }

        try ipcServer.start(path: "/var/run/mouseless.sock")
        NSLog("mouseless-daemon: socket ready")

        grabber.onKeyEvent = { event in
            handleKeyEvent(event)
        }
        try grabber.start()

        CFRunLoopRun()
    } catch {
        NSLog("mouseless-daemon fatal: %@", "\(error)")
        exit(1)
    }
}

main()
