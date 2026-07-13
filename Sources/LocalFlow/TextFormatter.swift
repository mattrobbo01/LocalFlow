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

        text = Self.removeStutters(text)

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

    /// Real 1–3 letter English words — protected from the fragment rule and
    /// barred from auto-learning.
    static let commonShortWords: Set<String> = [
        "a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if",
        "in", "is", "it", "me", "my", "no", "of", "oh", "ok", "on", "or", "so",
        "to", "up", "us", "we", "am", "ah", "act", "add", "age", "ago", "aid",
        "aim", "air", "all", "and", "any", "are", "arm", "art", "ask", "bad",
        "bag", "ban", "bar", "bat", "bed", "beg", "bet", "big", "bit", "box",
        "boy", "bug", "bus", "but", "buy", "can", "cap", "car", "cat", "cop",
        "cry", "cup", "cut", "dad", "day", "did", "die", "dig", "dip", "dog",
        "dot", "dry", "due", "ear", "eat", "egg", "end", "era", "eve", "eye",
        "fan", "far", "fat", "fee", "few", "fit", "fix", "fly", "for", "fun",
        "gap", "gas", "get", "got", "gun", "gut", "guy", "gym", "had", "has",
        "hat", "her", "hey", "him", "hip", "his", "hit", "hot", "how", "hub",
        "hug", "ice", "ill", "its", "job", "joy", "key", "kid", "kit", "lab",
        "lap", "law", "lay", "leg", "let", "lid", "lie", "lip", "log", "lot",
        "low", "mad", "man", "map", "may", "men", "met", "mix", "mom", "mud",
        "net", "new", "nod", "nor", "not", "now", "nut", "odd", "off", "oil",
        "old", "one", "our", "out", "owe", "own", "pad", "pan", "pay", "pen",
        "per", "pet", "pie", "pin", "pop", "pot", "pro", "put", "ran", "raw",
        "red", "rid", "rip", "row", "rub", "run", "sad", "sat", "saw", "say",
        "sea", "see", "set", "she", "shy", "sin", "sit", "six", "sky", "son",
        "spy", "sum", "sun", "tab", "tag", "tan", "tap", "tax", "tea", "ten",
        "the", "tie", "tin", "tip", "toe", "ton", "too", "top", "toy", "try",
        "two", "use", "van", "vet", "via", "war", "was", "way", "web", "wet",
        "who", "why", "win", "won", "yes", "yet", "you", "zip",
    ]

    /// Deterministic stutter cleanup:
    /// - orphan word-start fragments ("co coffee", "w want" → the full word)
    /// - doubled short words ("the the" → "the"; long doubles like
    ///   "very very" are kept — they're usually intentional emphasis)
    /// - stranded single letters that aren't words ("I said b something")
    static func removeStutters(_ input: String) -> String {
        var tokens = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let bare = tokens[index].trimmingCharacters(in: .punctuationCharacters)
            let next = index + 1 < tokens.count
                ? tokens[index + 1].trimmingCharacters(in: .punctuationCharacters)
                : nil

            // Fragment that the next word completes ("co coffee") — but only
            // when the fragment is NOT itself a word, or "to town" and
            // "an analysis" would lose their real words.
            if let next, bare.count <= 3, next.count > bare.count,
               bare.rangeOfCharacter(from: .letters) != nil,
               !Self.commonShortWords.contains(bare.lowercased()),
               next.lowercased().hasPrefix(bare.lowercased()) {
                tokens.remove(at: index)
                continue
            }
            // Doubled short word ("the the", "a a").
            if let next, bare.count <= 3, !bare.isEmpty,
               bare.lowercased() == next.lowercased() {
                tokens.remove(at: index)
                continue
            }
            // Stranded single letter that isn't "a" or "I".
            if bare.count == 1, bare.rangeOfCharacter(from: .letters) != nil,
               bare.lowercased() != "a", bare.lowercased() != "i",
               tokens[index] == bare {  // no attached punctuation worth keeping
                tokens.remove(at: index)
                continue
            }
            index += 1
        }
        return tokens.joined(separator: " ")
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
           - false starts, stutters, and partial word fragments — including \
        when the fragment is itself a word: "set settled in" → "settled in", \
        "we we should" → "we should", "co coffee" → "coffee"
           - self-corrections, keeping the speaker's corrected version
           - fragments of background speech (TV, other people) that don't fit the dictation
        2. FIX punctuation and capitalization: sentence breaks, commas, \
           question marks, apostrophes, capital letters, paragraph breaks.
        3. FIX small words the transcriber misheard — ONLY these swaps, ONLY \
           when the sentence is ungrammatical without the fix: \
           a↔an↔the, this↔that, than↔then. \
           Example: "a prompt this I just dictated" → "a prompt that I just dictated". \
           NEVER touch one of these words when it is already correct.

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

    /// ASR confusion groups: the polish pass may swap words *within* a group
    /// (transcriber mishearings), never across groups or beyond them.
    private static let confusionGroups: [Set<String>] = [
        ["a", "an", "the"],
        ["this", "that"],
        ["than", "then"],
    ]

    private static func sameGroup(_ a: String, _ b: String) -> Bool {
        confusionGroups.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Guardrail: validate the model's output edit-by-edit against an
    /// alignment with the original. Legal edits: deletions (anywhere) and
    /// 1-for-1 swaps within a confusion group. ANY other introduced word
    /// means it rephrased — discard its answer and keep the rule-based text.
    static func isDeleteOnly(original: String, polished: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let a = words(original)
        let b = words(polished)
        guard !b.isEmpty else { return false }

        let anchors = lcsPairs(a, b)
        var prevA = -1, prevB = -1
        for (i, j) in anchors + [(a.count, b.count)] {
            let removed = (prevA + 1)..<i
            let introduced = (prevB + 1)..<j
            if !introduced.isEmpty {
                // Only a single-word, same-confusion-group substitution may
                // introduce a word the user didn't say.
                guard introduced.count == 1, removed.count == 1,
                      sameGroup(a[removed.lowerBound], b[introduced.lowerBound])
                else { return false }
            }
            prevA = i
            prevB = j
        }
        return true
    }

    /// Longest common subsequence over word arrays; returns matched pairs.
    private static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
