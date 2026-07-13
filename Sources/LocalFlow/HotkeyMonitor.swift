import AppKit
import CoreGraphics
import os

/// Dictation hotkey monitor built on a listen-only CGEventTap.
///
/// Two interaction modes, mirroring Wispr Flow:
/// - **Hold-to-talk**: hold the key, speak, release.
/// - **Hands-free**: double-tap the key to start, single press to stop.
///
/// The fn/Globe key never arrives as keyDown — it surfaces as a `flagsChanged`
/// event (keycode 63) with `.maskSecondaryFn` toggling. The same applies to the
/// right-command / right-option alternatives, so this watches flag transitions.
///
/// Deliberately `listenOnly`: a modifying tap can suppress keystrokes for every
/// app on the system, and a single missed key-up leaves the keyboard broken
/// (Wispr Flow's infamous "ate my spacebar" bug). Listening can't break typing.
///
/// Reliability: event delivery to taps is not guaranteed (secure input,
/// permission changes, system HUDs can swallow events). A watchdog polls the
/// physical key state during holds, a health check resurrects the tap if the
/// OS disables it, and both modes carry a hard duration cap — no lost event
/// can wedge the app.
final class HotkeyMonitor {
    /// Recording should begin. `handsFree` is true for double-tap sessions
    /// (which end on the next key press, not on release).
    var onRecordStart: ((_ handsFree: Bool) -> Void)?
    var onRecordEnd: (() -> Void)?
    /// Fired when another key is pressed mid-hold (e.g. fn+Delete): the hold
    /// was a shortcut chord, not dictation, so the recording is cancelled.
    var onRecordCancel: (() -> Void)?
    /// ⌃⌘V — paste the most recent dictation wherever the cursor is.
    var onPasteLast: (() -> Void)?

    private enum Mode {
        case idle
        case holding
        case handsFree
    }

    private let logger = Logger(subsystem: "com.mattrobertson.localflow", category: "hotkey")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var watchdog: Timer?

    private var mode: Mode = .idle
    private var recordingStartedAt: Date?
    /// Set on the release of a short tap; a new press within the double-tap
    /// window then starts a hands-free session.
    private var lastShortTapUpAt: Date?
    private var currentDownAt: Date?
    /// keyState visibility differs by key/keyboard; only trust its "up"
    /// reading once it has demonstrably seen this key down during the hold.
    private var watchdogSawKeyDown = false

    private let hotkey: Settings.Hotkey
    private let doubleTapWindow: TimeInterval = 0.35
    /// Safety caps: force-end runaway sessions.
    private let maxHoldSeconds: TimeInterval = 90
    private let maxHandsFreeSeconds: TimeInterval = 300

    init(hotkey: Settings.Hotkey) {
        self.hotkey = hotkey
    }

    private var hotkeyKeycode: Int64 {
        switch hotkey {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        }
    }

    private var hotkeyFlag: CGEventFlags {
        switch hotkey {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        }
    }

    /// The physical truth, independent of event delivery. Uses per-keycode
    /// key state, NOT flagsState — the fn/Globe key is invisible to the
    /// modifier-flags snapshot even while held.
    private var hotkeyPhysicallyDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hotkeyKeycode))
    }

    // MARK: - Tap lifecycle

    /// Returns false when the tap can't be created (Input Monitoring not granted).
    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            logger.error("event tap creation failed — Input Monitoring not granted?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("event tap started for \(self.hotkey.rawValue, privacy: .public)")
        if healthTimer == nil { startHealthCheck() }
        return true
    }

    func stop() {
        stopWatchdog()
        healthTimer?.invalidate()
        healthTimer = nil
        tearDownTap()
    }

    private func tearDownTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func recreateTap() {
        tearDownTap()
        if start() {
            logger.info("tap recreated successfully")
        } else {
            logger.error("tap recreation failed — will retry via health check")
        }
    }

    /// Every few seconds, verify the tap still exists and is enabled;
    /// resurrect it if the OS killed it while we weren't looking.
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let tap = self.tap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    self.logger.warning("health check: tap found disabled — recreating")
                    self.recreateTap()
                }
            } else {
                self.recreateTap()
            }
        }
    }

    // MARK: - Event handling / state machine

    private func handle(type: CGEventType, event: CGEvent) {
        // The OS disables taps around permission changes and stalls. A plain
        // re-enable can leave the tap silently dead — rebuild it from scratch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("tap disabled (\(type.rawValue)) — recreating")
            DispatchQueue.main.async { self.recreateTap() }
            return
        }

        if type == .keyDown {
            // ⌃⌘V (keycode 9 = V): paste the last dictation.
            let flags = event.flags
            if event.getIntegerValueField(.keyboardEventKeycode) == 9,
               flags.contains(.maskCommand), flags.contains(.maskControl),
               !flags.contains(.maskAlternate), !flags.contains(.maskShift) {
                logger.info("paste-last shortcut")
                DispatchQueue.main.async { self.onPasteLast?() }
                return
            }
            // A real key while the hotkey is held means a shortcut chord
            // (fn+arrow, fn+delete…) — abandon the dictation hold. Typing
            // during a hands-free session is allowed and ignored.
            if mode == .holding {
                logger.info("keyDown during hold — cancelling")
                transition(to: .idle, fire: onRecordCancel)
            }
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == hotkeyKeycode
        else { return }

        let isDown = event.flags.contains(hotkeyFlag)
        logger.debug("flagsChanged: down=\(isDown) mode=\(String(describing: self.mode), privacy: .public)")
        isDown ? keyPressed() : keyReleased()
    }

    private func keyPressed() {
        switch mode {
        case .idle:
            if let tapUp = lastShortTapUpAt, Date().timeIntervalSince(tapUp) < doubleTapWindow {
                // Second tap of a double-tap: hands-free session.
                lastShortTapUpAt = nil
                currentDownAt = Date()
                logger.info("double-tap — hands-free session started")
                transition(to: .handsFree) { self.onRecordStart?(true) }
            } else {
                currentDownAt = Date()
                logger.info("hold started")
                transition(to: .holding) { self.onRecordStart?(false) }
            }
        case .handsFree:
            // A press during hands-free stops the session (its release is
            // ignored back in idle).
            logger.info("press during hands-free — ending session")
            transition(to: .idle, fire: onRecordEnd)
        case .holding:
            break  // duplicate down; ignore
        }
    }

    private func keyReleased() {
        switch mode {
        case .holding:
            // Short taps arm the double-tap detector; AppDelegate discards
            // their sub-minimum recordings.
            if let down = currentDownAt, Date().timeIntervalSince(down) < doubleTapWindow {
                lastShortTapUpAt = Date()
            }
            logger.info("hold ended")
            transition(to: .idle, fire: onRecordEnd)
        case .handsFree:
            break  // release of the tap that started the session; keep going
        case .idle:
            break  // release after a hands-free stop press; ignore
        }
    }

    private func transition(to newMode: Mode, fire: (() -> Void)?) {
        mode = newMode
        DispatchQueue.main.async {
            switch newMode {
            case .holding, .handsFree:
                self.recordingStartedAt = Date()
                self.watchdogSawKeyDown = false
                self.startWatchdog()
            case .idle:
                self.recordingStartedAt = nil
                self.stopWatchdog()
            }
            fire?()
        }
    }

    // MARK: - Watchdog (runs on main)

    private func startWatchdog() {
        stopWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        switch mode {
        case .idle:
            stopWatchdog()
        case .holding:
            if hotkeyPhysicallyDown {
                watchdogSawKeyDown = true
            }
            if watchdogSawKeyDown && !hotkeyPhysicallyDown {
                logger.warning("release event was missed — watchdog ending hold")
                transition(to: .idle, fire: onRecordEnd)
            } else if elapsed > maxHoldSeconds {
                logger.warning("hold exceeded \(Int(self.maxHoldSeconds))s cap — force-ending")
                transition(to: .idle, fire: onRecordEnd)
            }
        case .handsFree:
            // No key to poll — only the duration cap applies.
            if elapsed > maxHandsFreeSeconds {
                logger.warning("hands-free exceeded \(Int(self.maxHandsFreeSeconds))s cap — force-ending")
                transition(to: .idle, fire: onRecordEnd)
            }
        }
    }
}
