import AppKit
import Foundation
import FluidAudio

// Headless verification mode: `LocalFlow --transcribe file.wav` runs the full
// on-device ASR + formatting pipeline on an audio file and prints the result.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--transcribe"),
   CommandLine.arguments.count > flagIndex + 1 {
    let path = CommandLine.arguments[flagIndex + 1]
    let url = URL(fileURLWithPath: path)

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        do {
            let engine = TranscriptionEngine(onStateChange: { state in
                if case .downloading(let percent) = state {
                    FileHandle.standardError.write(Data("downloading models: \(percent)%\r".utf8))
                }
            })
            await engine.load()
            let loadStarted = Date()
            let result = try await engine.transcribe(url: url)
            let formatter = TextFormatter(dictionary: PersonalDictionary.load(), settings: Settings.load())
            let formatted = await formatter.format(result.text)

            print("raw:       \(result.text)")
            print("formatted: \(formatted)")
            print(String(
                format: "audio: %.2fs  inference: %.0f ms  (%.0fx real-time)  wall: %.2fs",
                result.duration, result.processingTime * 1000, result.rtfx,
                Date().timeIntervalSince(loadStarted)))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
    semaphore.wait()
    exit(0)
}

// Test hook: `LocalFlow --diff-test "<injected>" "<current>"` prints the
// corrections the auto-learner would harvest.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--diff-test"),
   CommandLine.arguments.count > flagIndex + 2 {
    let learned = AutoLearner.diffCorrections(
        injected: CommandLine.arguments[flagIndex + 1],
        current: CommandLine.arguments[flagIndex + 2])
    for item in learned { print("\(item.spoken) → \(item.written)") }
    print("(\(learned.count) corrections)")
    exit(0)
}

// Test hook: `LocalFlow --format-test "<raw text>"` runs the rule-based
// formatting pass and prints the result.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--format-test"),
   CommandLine.arguments.count > flagIndex + 1 {
    let formatter = TextFormatter(dictionary: PersonalDictionary(), settings: Settings())
    print(formatter.rulePass(CommandLine.arguments[flagIndex + 1]))
    exit(0)
}

// Normal launch: background menu-bar app (no Dock icon).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
