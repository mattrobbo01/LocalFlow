import AppKit
import ApplicationServices
import os

/// Learns dictionary corrections from what the user does *after* a dictation.
///
/// On injection, remembers the focused text element and the exact text typed.
/// Later (next dictation, or a delayed check), it re-reads that element via
/// the Accessibility API and aligns the old and new words. A word the user
/// swapped for a similar-looking one (case fix, spelling, jargon) becomes a
/// dictionary entry — so the same correction never has to be made twice.
///
/// Entirely local, fail-quiet: sandboxed apps that don't expose AX values,
/// stale elements, or wholesale rewrites simply produce no learning.
@MainActor
final class AutoLearner {
    struct Learned {
        let spoken: String
        let written: String
    }

    private struct Pending {
        let text: String
        let element: AXUIElement
        let at: Date
        /// Last state of the field that still contained our dictation — the
        /// learning source if the field is cleared (message sent) before the
        /// session ends.
        var lastSeen: String?
    }

    private let logger = Logger(subsystem: "com.mattrobertson.localflow", category: "learn")
    private var pending: Pending?
    private var pollTimer: Timer?

    /// Fired when a watch session concludes with corrections (field cleared,
    /// user sent the message, or the session timed out).
    var onLearned: (([Learned]) -> Void)?

    private let pollInterval: TimeInterval = 6
    private let sessionMaxAge: TimeInterval = 150

    /// Called right after text is injected into the focused app. Starts a
    /// watch session on the focused element.
    func noteInjection(text: String) {
        stopPolling()
        guard let element = Self.focusedElement() else {
            pending = nil
            return
        }
        pending = Pending(text: text, element: element, at: Date(), lastSeen: nil)
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Immediate flush (e.g. the user is starting a new dictation): learn
    /// from the field's live state if it still holds our text, otherwise
    /// from the last snapshot. Ends the watch session.
    func flush() -> [Learned] {
        guard let pending else { return [] }
        let source = bestSource(for: pending)
        stopSession()
        return learn(from: pending.text, source: source)
    }

    private func poll() {
        guard let current = pending else {
            stopPolling()
            return
        }
        if Date().timeIntervalSince(current.at) > sessionMaxAge {
            finishSession()
            return
        }
        guard let value = Self.stringValue(of: current.element), !value.isEmpty,
              Self.matchFraction(injected: current.text, current: value) > 0.5
        else {
            // Field emptied, cleared, or moved on — the user sent/committed
            // the text. Learn from the final snapshot we took before that.
            finishSession()
            return
        }
        pending?.lastSeen = value
    }

    private func finishSession() {
        guard let pending else { return }
        let source = bestSource(for: pending)
        stopSession()
        let learned = learn(from: pending.text, source: source)
        if !learned.isEmpty {
            onLearned?(learned)
        }
    }

    /// Live field content when it still holds our dictation; else the last
    /// snapshot that did.
    private func bestSource(for pending: Pending) -> String? {
        if let value = Self.stringValue(of: pending.element), !value.isEmpty,
           Self.matchFraction(injected: pending.text, current: value) > 0.5 {
            return value
        }
        return pending.lastSeen
    }

    private func learn(from injected: String, source: String?) -> [Learned] {
        guard let source else { return [] }
        let learned = Self.diffCorrections(injected: injected, current: source)
        for item in learned {
            logger.info("learned correction: \(item.spoken, privacy: .public) → \(item.written, privacy: .public)")
        }
        return learned
    }

    private func stopSession() {
        pending = nil
        stopPolling()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - AX plumbing

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    // MARK: - Word alignment

    /// Fraction of injected words still present (in order) in the field —
    /// the "is this field still showing our dictation" test.
    nonisolated static func matchFraction(injected: String, current: String) -> Double {
        let a = words(injected).map { $0.lowercased() }
        let b = words(current).map { $0.lowercased() }
        guard !a.isEmpty, b.count < 2_000 else { return 0 }
        return Double(lcsPairs(a, b).count) / Double(a.count)
    }

    /// Align the injected words against the field's current words (LCS on
    /// lowercase forms) and harvest 1-for-1 substitutions of similar words.
    nonisolated static func diffCorrections(injected: String, current: String) -> [Learned] {
        let injectedWords = words(injected)
        let (currentWords, startsSentence) = wordsWithSentenceStarts(current)
        guard !injectedWords.isEmpty, currentWords.count < 2_000 else { return [] }

        let anchors = lcsPairs(
            injectedWords.map { $0.lowercased() },
            currentWords.map { $0.lowercased() })

        var learned: [Learned] = []
        // Anchors match case-insensitively, so a pure case fix ("habits" →
        // "Habits") hides inside a matched pair — harvest those directly.
        // Sentence-start capitalizations are grammar, not vocabulary: skip,
        // or every "it" would become "It" forever.
        for (i, j) in anchors
        where injectedWords[i] != currentWords[j] && !startsSentence[j] {
            learned.append(Learned(spoken: injectedWords[i], written: currentWords[j]))
        }
        var prevA = -1, prevB = -1
        // Examine the gaps between consecutive anchor pairs: exactly one
        // unmatched word on each side = a candidate substitution.
        for (a, b) in anchors + [(injectedWords.count, currentWords.count)] {
            let gapA = (prevA + 1)..<a
            let gapB = (prevB + 1)..<b
            if gapA.count == 1, gapB.count == 1 {
                let spoken = injectedWords[gapA.lowerBound]
                let written = currentWords[gapB.lowerBound]
                if isLearnable(spoken: spoken, written: written) {
                    learned.append(Learned(spoken: spoken, written: written))
                }
            }
            prevA = a
            prevB = b
        }
        // A dictation that was mostly rewritten is an edit for meaning, not
        // ASR corrections — learn nothing rather than learn noise.
        let matchedFraction = Double(anchors.count) / Double(injectedWords.count)
        guard matchedFraction > 0.5 else { return [] }
        return Array(learned.prefix(3))
    }

    /// Grammar words that must NEVER become dictionary rules — a one-off
    /// edit ("this"→"the" in one sentence) would otherwise rewrite every
    /// future dictation globally.
    nonisolated private static let neverLearn: Set<String> = [
        "this", "that", "than", "then", "these", "those", "there", "their",
        "they", "them", "your", "you're", "its", "it's", "were", "we're",
        "where", "have", "has", "had", "will", "would", "could", "should",
    ]

    nonisolated private static func isLearnable(spoken: String, written: String) -> Bool {
        let spokenLower = spoken.lowercased()
        let writtenLower = written.lowercased()

        // Grammar/function/common-short words are context edits, never vocabulary.
        if neverLearn.contains(spokenLower) || neverLearn.contains(writtenLower) { return false }
        if TextFormatter.commonShortWords.contains(spokenLower) { return false }

        if spokenLower == writtenLower {
            // Case-only corrections: learn capitalizations ("habits"→"Habits"),
            // never downgrades ("Take"→"take" — that's sentence context).
            guard spoken != written,
                  written.first?.isUppercase == true,
                  spoken.first?.isLowercase == true
            else { return false }
            return true
        }
        guard spoken.count >= 3, written.count >= 2 else { return false }
        // Words must be recognizably similar — a spelling/jargon fix, not a
        // different word choice.
        let distance = levenshtein(spokenLower, writtenLower)
        let maxLength = max(spoken.count, written.count)
        guard Double(distance) / Double(maxLength) <= 0.5 else { return false }
        // If both sides are ordinary lowercase English words ("drafts"→"draft",
        // "thing"→"saying"), the user edited meaning, not vocabulary. Jargon,
        // names, and brands (unknown or capitalized words) remain learnable.
        if written == writtenLower, isRealEnglishWord(spokenLower), isRealEnglishWord(writtenLower) {
            return false
        }
        return true
    }

    /// Spell-checker lookup — call sites all run on the main thread.
    nonisolated private static func isRealEnglishWord(_ word: String) -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            let checker = NSSpellChecker.shared
            let range = checker.checkSpelling(of: word, startingAt: 0)
            return range.location == NSNotFound
        }
    }

    nonisolated private static func words(_ text: String) -> [String] {
        wordsWithSentenceStarts(text).words
    }

    /// Tokenize into words plus a parallel flag: does this word begin a
    /// sentence (first word, or preceded by . ! ? or a line break)?
    nonisolated private static func wordsWithSentenceStarts(
        _ text: String
    ) -> (words: [String], startsSentence: [Bool]) {
        var result: [String] = []
        var flags: [Bool] = []
        var nextStartsSentence = true
        for token in text.components(separatedBy: .whitespacesAndNewlines) where !token.isEmpty {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            let endsSentence =
                token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
            if word.count > 1, word.rangeOfCharacter(from: .letters) != nil {
                result.append(word)
                flags.append(nextStartsSentence)
                nextStartsSentence = endsSentence
            } else {
                nextStartsSentence = nextStartsSentence || endsSentence
            }
        }
        return (result, flags)
    }

    /// Longest common subsequence over word arrays; returns matched index pairs.
    nonisolated private static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
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

    nonisolated private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        var row = Array(0...bChars.count)
        for (i, ca) in aChars.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, cb) in bChars.enumerated() {
                let insertOrDelete = min(row[j + 1], row[j]) + 1
                let substitute = previous + (ca == cb ? 0 : 1)
                previous = row[j + 1]
                row[j + 1] = min(insertOrDelete, substitute)
            }
        }
        return row[bChars.count]
    }
}
