import AppKit
import AVFoundation
import FluidAudio
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.mattrobertson.localflow", category: "app")
    private var statusItem: NSStatusItem!
    private var hotkeyMonitor: HotkeyMonitor?
    private let recorder = AudioRecorder()
    private let overlay = OverlayIndicator()
    private var engine: TranscriptionEngine!
    private let voiceFilter = VoiceFilter()
    private var settings = Settings.load()
    private let dictionaryStore = DictionaryStore()
    private let dictionaryWindow = DictionaryWindowController()
    private let autoLearner = AutoLearner()
    private var isEnrolling = false
    private var lastDictation: String?

    private var engineState: TranscriptionEngine.State = .idle
    private var lastLatency: Double?
    private var statusMenuItem: NSMenuItem!
    private var latencyMenuItem: NSMenuItem!
    private var ollamaMenuItem: NSMenuItem!
    private var voiceEnrollItem: NSMenuItem!
    private var voiceFilterItem: NSMenuItem!
    private var autoLearnItem: NSMenuItem!
    private var voiceEnrolled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        engine = TranscriptionEngine(onStateChange: { [weak self] state in
            Task { @MainActor in self?.engineStateChanged(state) }
        })
        autoLearner.onLearned = { [weak self] learned in
            self?.applyLearned(learned, announce: true)
        }

        Task { await engine.load() }
        Task {
            await voiceFilter.loadIfEnrolled()
            let enrolled = await voiceFilter.isEnrolled
            await MainActor.run {
                self.voiceEnrolled = enrolled
                self.refreshMenu()
            }
        }

        Task { await self.requestPermissionsAndStartHotkey() }
    }

    // MARK: - Permissions & hotkey

    private func requestPermissionsAndStartHotkey() async {
        // Explicitly request Input Monitoring — without this, a missing grant
        // fails silently (the tap gets created, then the OS kills it).
        if !CGPreflightListenEventAccess() {
            logger.warning("Input Monitoring not granted — requesting")
            CGRequestListenEventAccess()
        }

        // Arm the hotkey first — never let a pending permission dialog leave
        // the app deaf to the fn key. The health check recreates the tap
        // automatically once access is granted.
        startHotkeyMonitor()

        // Prompts for Accessibility if missing (needed to post the paste keystroke).
        let axOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOptions)

        let micGranted = await AudioRecorder.requestMicrophoneAccess()
        logger.info("startup permissions: mic=\(micGranted)")
        if !micGranted {
            showPermissionAlert(
                "Microphone access is required",
                "Grant LocalFlow microphone access in System Settings → Privacy & Security → Microphone, then relaunch.")
        }
    }

    private func startHotkeyMonitor() {
        overlay.levelProvider = { [weak self] in self?.recorder.currentLevel ?? 0 }
        let monitor = HotkeyMonitor(hotkey: settings.hotkey)
        monitor.onRecordStart = { [weak self] handsFree in self?.recordStarted(handsFree: handsFree) }
        monitor.onRecordEnd = { [weak self] in self?.recordEnded() }
        monitor.onRecordCancel = { [weak self] in self?.recordCancelled() }
        monitor.onPasteLast = { [weak self] in self?.pasteLastDictation() }

        if monitor.start() {
            hotkeyMonitor = monitor
        } else {
            // Tap creation fails without Input Monitoring approval.
            showPermissionAlert(
                "Input Monitoring is required",
                "LocalFlow watches for the \(hotkeyName()) key using a listen-only event tap. Grant access in System Settings → Privacy & Security → Input Monitoring, then relaunch.")
        }
    }

    private func showPermissionAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Dictation pipeline

    private func recordStarted(handsFree: Bool) {
        guard !isEnrolling else { return }
        // Natural checkpoint: before a new dictation, close out the previous
        // watch session so fresh corrections apply immediately.
        applyLearned(autoLearner.flush(), announce: false)
        guard case .ready = engineState else {
            logger.warning("hold started but engine not ready: \(self.engineStatusText(), privacy: .public)")
            overlay.show(.message(engineStatusText()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.overlay.hide()
            }
            return
        }
        // Self-heal: a leftover recording means an earlier release was lost —
        // discard it rather than wedging on this stale state forever.
        if recorder.isRecording {
            logger.warning("hold started while already recording — discarding stale recording")
            recorder.cancel()
        }

        do {
            try recorder.start()
            logger.info("recording started (handsFree=\(handsFree))")
            overlay.show(.listening(handsFree: handsFree))
            playSound("Pop")
            setIcon(recording: true)
        } catch {
            logger.error("recorder failed to start: \(error.localizedDescription, privacy: .public)")
            overlay.show(.message("Mic unavailable"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.overlay.hide()
            }
        }
    }

    private func recordEnded() {
        guard !isEnrolling else { return }
        guard recorder.isRecording else {
            logger.info("hold ended but not recording — hiding overlay")
            overlay.hide()
            return
        }
        let samples = recorder.stop()
        setIcon(recording: false)

        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        logger.info("recording stopped: \(String(format: "%.2f", duration), privacy: .public)s")
        guard duration >= settings.minimumUtteranceSeconds else {
            overlay.hide()
            return
        }

        overlay.show(.processing)
        let formatter = TextFormatter(
            dictionary: dictionaryStore.personalDictionary(), settings: settings)
        let filterSettings = settings

        Task {
            let started = Date()
            do {
                var audio = samples
                if filterSettings.voiceFilterEnabled, await voiceFilter.isEnrolled {
                    audio = await voiceFilter.filter(
                        samples, threshold: Float(filterSettings.voiceMatchThreshold))
                    if audio.isEmpty {
                        self.logger.info("voice filter removed all audio — nothing to type")
                        self.overlay.hide()
                        return
                    }
                }
                let result = try await engine.transcribe(audio)
                self.logger.info("transcribed \(result.text.count) chars in \(Int(result.processingTime * 1000)) ms")
                let text = await formatter.format(result.text)
                if !text.isEmpty {
                    self.lastDictation = text
                    TextInjector.inject(text)
                    self.playSound("Bottle")
                    self.recordHistory(text: text, duration: duration)
                    if self.settings.autoLearnEnabled {
                        self.autoLearner.noteInjection(text: text)
                    }
                }
                self.lastLatency = Date().timeIntervalSince(started)
                self.refreshMenu()
            } catch {
                self.overlay.show(.message("Transcription failed"))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self.overlay.hide()
        }
    }

    private func recordCancelled() {
        guard !isEnrolling, recorder.isRecording else { return }
        recorder.cancel()
        setIcon(recording: false)
        overlay.hide()
    }

    /// Local-only dictation history (JSONL you can grep) — the private
    /// counterpart to Wispr's cloud-synced history.
    private func recordHistory(text: String, duration: Double) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "seconds": (duration * 10).rounded() / 10,
            "text": text,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let url = Settings.historyURL
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            try? (line + "\n").data(using: .utf8)!.write(to: url)
        }
    }

    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: - Status item / menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        latencyMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        latencyMenuItem.isEnabled = false
        latencyMenuItem.isHidden = true
        menu.addItem(latencyMenuItem)

        menu.addItem(.separator())
        let hotkeyItem = NSMenuItem(
            title: "Hold \(hotkeyName()) to dictate · double-tap for hands-free",
            action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        ollamaMenuItem = NSMenuItem(
            title: "Polish with local LLM (Ollama)",
            action: #selector(toggleOllama), keyEquivalent: "")
        ollamaMenuItem.target = self
        ollamaMenuItem.state = settings.ollamaEnabled ? .on : .off
        menu.addItem(ollamaMenuItem)

        voiceEnrollItem = NSMenuItem(
            title: "Enroll My Voice (20s)…",
            action: #selector(enrollVoice), keyEquivalent: "")
        voiceEnrollItem.target = self
        menu.addItem(voiceEnrollItem)

        voiceFilterItem = NSMenuItem(
            title: "Only Type My Voice",
            action: #selector(toggleVoiceFilter), keyEquivalent: "")
        voiceFilterItem.target = self
        voiceFilterItem.state = settings.voiceFilterEnabled ? .on : .off
        menu.addItem(voiceFilterItem)

        let dictItem = NSMenuItem(
            title: "Personal Dictionary…",
            action: #selector(openDictionary), keyEquivalent: "d")
        dictItem.target = self
        menu.addItem(dictItem)

        autoLearnItem = NSMenuItem(
            title: "Learn From My Edits",
            action: #selector(toggleAutoLearn), keyEquivalent: "")
        autoLearnItem.target = self
        autoLearnItem.state = settings.autoLearnEnabled ? .on : .off
        menu.addItem(autoLearnItem)

        let pasteLastItem = NSMenuItem(
            title: "Paste Last Dictation (⌃⌘V)",
            action: #selector(pasteLastFromMenu), keyEquivalent: "")
        pasteLastItem.target = self
        menu.addItem(pasteLastItem)

        let historyItem = NSMenuItem(
            title: "Open Dictation History…",
            action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setIcon(recording: Bool) {
        let symbol = recording ? "waveform.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "LocalFlow")
    }

    private func engineStateChanged(_ state: TranscriptionEngine.State) {
        engineState = state
        refreshMenu()
    }

    private func engineStatusText() -> String {
        switch engineState {
        case .idle: return "Starting…"
        case .downloading(let percent): return "Downloading model… \(percent)%"
        case .loading: return "Loading model…"
        case .ready: return "Ready — on-device ASR loaded"
        case .failed(let message): return "Model failed: \(message)"
        }
    }

    private func refreshMenu() {
        statusMenuItem.title = engineStatusText()
        if let latency = lastLatency {
            latencyMenuItem.title = String(format: "Last dictation: %.0f ms", latency * 1000)
            latencyMenuItem.isHidden = false
        }
        voiceEnrollItem.title =
            voiceEnrolled ? "Re-enroll My Voice (20s)…" : "Enroll My Voice (20s)…"
        voiceFilterItem.state = settings.voiceFilterEnabled ? .on : .off
        voiceFilterItem.isEnabled = voiceEnrolled
    }

    /// Record ~20 s of natural speech and build the owner's voice profile.
    @objc private func enrollVoice() {
        guard !isEnrolling, !recorder.isRecording else { return }
        isEnrolling = true
        do {
            try recorder.start()
        } catch {
            isEnrolling = false
            overlay.show(.message("Mic unavailable"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.overlay.hide() }
            return
        }
        playSound("Pop")
        overlay.show(.message("Enrolling — speak naturally for 20 seconds…"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isEnrolling else { return }
            let samples = self.recorder.stop()
            self.overlay.show(.message("Building your voice profile…"))
            Task {
                do {
                    try await self.voiceFilter.enroll(samples: samples)
                    self.voiceEnrolled = true
                    self.overlay.show(.message("Voice enrolled ✓"))
                    self.playSound("Bottle")
                } catch {
                    self.logger.error("enrollment failed: \(error.localizedDescription, privacy: .public)")
                    self.overlay.show(.message("Enrollment failed"))
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.overlay.hide()
                self.isEnrolling = false
                self.refreshMenu()
            }
        }
    }

    /// ⌃⌘V or menu: re-insert the most recent dictation at the cursor —
    /// the rescue for dictating with no text field focused.
    private func pasteLastDictation() {
        if lastDictation == nil {
            lastDictation = Self.lastHistoryEntry()
        }
        guard let text = lastDictation else {
            overlay.show(.message("No dictation yet"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.overlay.hide() }
            return
        }
        logger.info("pasting last dictation (\(text.count) chars)")
        TextInjector.inject(text)
        playSound("Bottle")
    }

    /// Most recent dictation from history.jsonl — survives app restarts.
    private static func lastHistoryEntry() -> String? {
        guard let data = try? String(contentsOf: Settings.historyURL, encoding: .utf8) else { return nil }
        guard let line = data.split(separator: "\n").last(where: { !$0.isEmpty }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = json["text"] as? String
        else { return nil }
        return text
    }

    @objc private func pasteLastFromMenu() {
        pasteLastDictation()
    }

    /// Apply corrections the auto-learner harvested.
    private func applyLearned(_ learned: [AutoLearner.Learned], announce: Bool) {
        guard settings.autoLearnEnabled, !learned.isEmpty else { return }
        var added: [String] = []
        for item in learned where dictionaryStore.learn(spoken: item.spoken, written: item.written) {
            added.append("\(item.spoken) → \(item.written)")
        }
        if announce, !recorder.isRecording, let first = added.first {
            overlay.show(.message("Learned: \(first)"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.overlay.hide()
            }
        }
    }

    @objc private func toggleAutoLearn() {
        settings.autoLearnEnabled.toggle()
        settings.save()
        autoLearnItem.state = settings.autoLearnEnabled ? .on : .off
    }

    @objc private func toggleVoiceFilter() {
        settings.voiceFilterEnabled.toggle()
        settings.save()
        voiceFilterItem.state = settings.voiceFilterEnabled ? .on : .off
    }

    @objc private func toggleOllama() {
        settings.ollamaEnabled.toggle()
        settings.save()
        ollamaMenuItem.state = settings.ollamaEnabled ? .on : .off
    }

    @objc private func openDictionary() {
        dictionaryWindow.show(store: dictionaryStore)
    }

    @objc private func openHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([Settings.historyURL])
    }

    private func hotkeyName() -> String {
        switch settings.hotkey {
        case .fn: return "fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        }
    }
}
