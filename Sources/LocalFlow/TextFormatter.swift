import Foundation

/// Post-processing pass over raw transcripts — the local stand-in for Wispr's
/// cloud Llama cleanup. Rule-based (instant), with an optional polish step
/// through a local Ollama model when one is running.
struct TextFormatter {
    var dictionary: PersonalDictionary
    var settings: Settings

    private static let fillerPattern = try! NSRegularExpression(
        pattern: "\\b(um+|uh+|uhm+|erm*|hmm+|mhm+)\\b[,.]?\\s*",
        options: [.caseInsensitive])

    /// Spoken layout commands, matched with optional surrounding punctuation.
    private static let spokenCommands: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*", options: [.caseInsensitive]), "\n\n"),
        (try! NSRegularExpression(pattern: "[,.]?\\s*\\bnew line\\b[,.]?\\s*", options: [.caseInsensitive]), "\n"),
    ]

    func format(_ raw: String) async -> String {
        var text = rulePass(raw)
        if settings.ollamaEnabled, let polished = await OllamaPolisher.polish(
            text, model: settings.ollamaModel) {
            text = polished
        }
        return text
    }

    /// Deterministic cleanup: fillers, spoken commands, dictionary, whitespace.
    func rulePass(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = Self.fillerPattern.stringByReplacingMatches(
            in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")

        for (regex, replacement) in Self.spokenCommands {
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text),
                withTemplate: replacement)
        }

        text = dictionary.apply(to: text)

        // Collapse doubled spaces left behind by removals, tidy space-before-punct.
        text = text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)

        text = Self.capitalizeSentences(text)
        return text
    }

    /// Deterministic capitalization: sentence starts (after .!? and line
    /// breaks), the leading character, and the pronoun "I" — so transcripts
    /// read properly without needing the LLM pass.
    static func capitalizeSentences(_ input: String) -> String {
        var chars = Array(input)
        var atSentenceStart = true
        for i in 0..<chars.count {
            let c = chars[i]
            if atSentenceStart, c.isLetter {
                chars[i] = Character(c.uppercased())
                atSentenceStart = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                atSentenceStart = true
            } else if !c.isWhitespace {
                atSentenceStart = false
            }
        }
        var text = String(chars)
        // Standalone pronoun "i" and its contractions (i'm, i've, i'll, i'd).
        text = text.replacingOccurrences(
            of: #"\bi\b"#, with: "I", options: .regularExpression)
        return text
    }
}

/// Optional local-LLM polish via Ollama's HTTP API on localhost. Strictly
/// best-effort: short timeout, and any failure falls back to the rule-based
/// text. Nothing leaves the machine — Ollama runs on-device.
enum OllamaPolisher {
    static func polish(_ text: String, model: String) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        You are a dictation cleanup filter. You may do exactly two things:

        1. DELETE words that do not belong:
           - filler words (um, uh, er, hmm)
           - false starts and self-corrections, keeping the speaker's corrected version
           - fragments of background speech (TV, other people) that don't fit the dictation
        2. FIX punctuation and capitalization: sentence breaks, commas, \
           question marks, apostrophes, capital letters, paragraph breaks.

        You must NEVER change, add, replace, or reorder the speaker's words. \
        Every remaining word must appear exactly as dictated, in the original \
        order, with the speaker's own wording and tone preserved. \
        If nothing needs fixing, return the text unchanged. \
        Reply with ONLY the resulting text — no quotes, no commentary.

        Dictated text: \(text)
        """
        let body: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false,
            "options": ["temperature": 0],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let output = json["response"] as? String
        else { return nil }

        var cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap their answer in quotes despite instructions.
        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        guard !cleaned.isEmpty, isDeleteOnly(original: text, polished: cleaned) else { return nil }
        return cleaned
    }

    /// Guardrail: the polish pass may only *remove* words. If the model's
    /// output contains words that weren't dictated, it rephrased — discard
    /// its answer and keep the rule-based text.
    private static func isDeleteOnly(original: String, polished: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let originalWords = Set(words(original))
        let polishedWords = words(polished)
        guard !polishedWords.isEmpty else { return false }

        let invented = polishedWords.filter { !originalWords.contains($0) }
        // Tolerate a word or two of drift (punctuation-driven splits), no more.
        return invented.count <= max(1, polishedWords.count / 50)
    }
}
