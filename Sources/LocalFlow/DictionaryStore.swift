import AppKit
import SwiftUI

/// Shared, observable personal dictionary backed by dictionary.json.
/// Read by the formatter on every dictation, edited in the dictionary
/// window, and appended to by the auto-learner.
@MainActor
final class DictionaryStore: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    @Published var entries: [Entry] = [] {
        didSet { save() }
    }

    private var suppressSave = false

    init() {
        load()
    }

    func load() {
        suppressSave = true
        defer { suppressSave = false }
        guard let data = try? Data(contentsOf: Settings.dictionaryURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            entries = []
            return
        }
        entries = decoded
            .map { Entry(spoken: $0.key, written: $0.value) }
            .sorted { $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending }
    }

    private func save() {
        guard !suppressSave else { return }
        var dict: [String: String] = [:]
        for entry in entries {
            let spoken = entry.spoken.trimmingCharacters(in: .whitespaces)
            let written = entry.written.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty, !written.isEmpty else { continue }
            dict[spoken] = written
        }
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(dict) {
            try? data.write(to: Settings.dictionaryURL)
        }
    }

    /// Current replacements as the formatter consumes them.
    func personalDictionary() -> PersonalDictionary {
        var dict: [String: String] = [:]
        for entry in entries where !entry.spoken.isEmpty && !entry.written.isEmpty {
            dict[entry.spoken] = entry.written
        }
        return PersonalDictionary(replacements: dict)
    }

    /// Add a learned correction (skips duplicates and anything that would
    /// form a rewrite cycle with an existing entry). Returns true if added.
    @discardableResult
    func learn(spoken: String, written: String) -> Bool {
        let spokenKey = spoken.lowercased()
        let writtenKey = written.lowercased()
        guard !entries.contains(where: { $0.spoken.lowercased() == spokenKey }) else { return false }
        // Reject A→B when B→A (or B→anything) already exists: replacements
        // chain and cycle ("thing"→"saying" + "saying"→"thing" = coin flip).
        guard !entries.contains(where: { $0.spoken.lowercased() == writtenKey }),
              !entries.contains(where: {
                  $0.written.lowercased() == spokenKey && $0.spoken.lowercased() == writtenKey
              })
        else { return false }
        entries.append(Entry(spoken: spoken, written: written))
        entries.sort { $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending }
        return true
    }
}

// MARK: - Editor window

@MainActor
final class DictionaryWindowController {
    private var window: NSWindow?

    func show(store: DictionaryStore) {
        if window == nil {
            let view = DictionaryView(store: store)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Personal Dictionary"
            window.setContentSize(NSSize(width: 480, height: 420))
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore
    @State private var newSpoken = ""
    @State private var newWritten = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("When you say the word on the left, LocalFlow types the word on the right. Matching is case-insensitive. Corrections you make after dictating are learned automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()

            List {
                HStack {
                    Text("You say").frame(maxWidth: .infinity, alignment: .leading)
                    Text("LocalFlow types").frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(width: 28)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach($store.entries) { $entry in
                    HStack {
                        TextField("spoken", text: $entry.spoken)
                            .textFieldStyle(.roundedBorder)
                        TextField("written", text: $entry.written)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            store.entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this entry")
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                TextField("you say…", text: $newSpoken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                TextField("LocalFlow types…", text: $newWritten)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newSpoken.trimmingCharacters(in: .whitespaces).isEmpty
                            || newWritten.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private func add() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespaces)
        let written = newWritten.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        store.learn(spoken: spoken, written: written)
        newSpoken = ""
        newWritten = ""
    }
}
