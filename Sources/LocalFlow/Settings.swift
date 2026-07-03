import Foundation

/// User-configurable settings, persisted as JSON in Application Support.
struct Settings: Codable {
    enum Hotkey: String, Codable {
        case fn
        case rightCommand
        case rightOption
    }

    var hotkey: Hotkey = .fn
    var playSounds: Bool = true
    /// Polish transcripts with a local Ollama model when one is running.
    var ollamaEnabled: Bool = false
    var ollamaModel: String = "llama3.2"
    /// Discard recordings shorter than this — filters accidental fn taps.
    var minimumUtteranceSeconds: Double = 0.35
    /// Drop audio segments not matching the enrolled voice (needs enrollment).
    var voiceFilterEnabled: Bool = true
    /// Max cosine distance to the enrolled voice for a segment to count as
    /// the owner speaking. Lower = stricter.
    var voiceMatchThreshold: Double = 0.6
    /// Learn dictionary corrections from edits made shortly after dictating.
    var autoLearnEnabled: Bool = true

    init() {}

    /// Tolerant decoding: fields added in later versions fall back to their
    /// defaults instead of discarding the user's whole settings file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? defaults.hotkey
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? defaults.playSounds
        ollamaEnabled = try c.decodeIfPresent(Bool.self, forKey: .ollamaEnabled) ?? defaults.ollamaEnabled
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? defaults.ollamaModel
        minimumUtteranceSeconds =
            try c.decodeIfPresent(Double.self, forKey: .minimumUtteranceSeconds)
            ?? defaults.minimumUtteranceSeconds
        voiceFilterEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .voiceFilterEnabled) ?? defaults.voiceFilterEnabled
        voiceMatchThreshold =
            try c.decodeIfPresent(Double.self, forKey: .voiceMatchThreshold) ?? defaults.voiceMatchThreshold
        autoLearnEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .autoLearnEnabled) ?? defaults.autoLearnEnabled
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
    }

    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    static var dictionaryURL: URL { directory.appendingPathComponent("dictionary.json") }
    static var historyURL: URL { directory.appendingPathComponent("history.jsonl") }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            let defaults = Settings()
            defaults.save()
            return defaults
        }
        return settings
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.settingsURL)
        }
    }
}

/// Personal dictionary: exact and case-insensitive replacements applied
/// to transcripts before injection. Editable JSON so corrections stick.
struct PersonalDictionary {
    private(set) var replacements: [String: String] = [:]

    init(replacements: [String: String] = [:]) {
        self.replacements = replacements
    }

    static func load() -> PersonalDictionary {
        var dict = PersonalDictionary()
        if let data = try? Data(contentsOf: Settings.dictionaryURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict.replacements = decoded
        } else {
            // Seed an example file so users can discover the format.
            let example = ["local flow": "LocalFlow"]
            try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(example) {
                try? data.write(to: Settings.dictionaryURL)
            }
            dict.replacements = example
        }
        return dict
    }

    func apply(to text: String) -> String {
        var result = text
        for (spoken, written) in replacements {
            guard !spoken.isEmpty else { continue }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: spoken) + "\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, options: [], range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: written))
            }
        }
        return result
    }
}
