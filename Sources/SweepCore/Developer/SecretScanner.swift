import Foundation

/// A credential that appears in an AI agent's saved transcript.
public struct SecretFinding: Identifiable, Hashable, Sendable {
    public var id: String { file + ":" + fingerprint }
    public let kind: String
    /// The value with all but its first and last few characters hidden.
    public let masked: String
    public let agent: String
    public let file: String
    /// The project the conversation was in, when the transcript says.
    public let project: String?
    public let occurrences: Int
    public let lastSeen: Date?
    let fingerprint: String
}

/// Looks for API keys, tokens and private keys in Claude Code, Codex and Gemini CLI transcripts.
///
/// Entirely offline and read-only: files are read, matched against known credential formats, and only masked values are kept.
public struct SecretScanner: Sendable {
    let home: String

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }

    struct Pattern {
        let kind: String
        let regex: NSRegularExpression
        init(_ kind: String, _ pattern: String) {
            self.kind = kind
            // The patterns are fixed and known to compile.
            regex = try! NSRegularExpression(pattern: pattern)
        }
    }

    static let patterns: [Pattern] = [
        Pattern("Anthropic API key", #"sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_\-]{80,}"#),
        Pattern("OpenAI API key", #"sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}T3BlbkFJ[A-Za-z0-9_\-]{20,}"#),
        Pattern("OpenAI API key", #"sk-proj-[A-Za-z0-9_\-]{80,}"#),
        Pattern("GitHub token", #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}"#),
        Pattern("GitHub token", #"github_pat_[A-Za-z0-9_]{60,}"#),
        Pattern("AWS access key", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
        Pattern("Google API key", #"AIza[0-9A-Za-z_\-]{35}"#),
        Pattern("Slack token", #"xox[baprs]-[0-9A-Za-z\-]{10,}"#),
        Pattern("Stripe secret key", #"(?:sk|rk)_live_[0-9A-Za-z]{24,}"#),
        Pattern("Hugging Face token", #"hf_[A-Za-z]{34}"#),
        Pattern("npm token", #"npm_[A-Za-z0-9]{36}"#),
        Pattern("Private key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"#),
    ]

    /// Folders searched, with the agent that wrote them and the file endings that hold transcripts.
    var sources: [(agent: String, folder: String, suffixes: [String])] {
        [("Claude Code", home + "/.claude/projects", [".jsonl"]),
         ("Codex", home + "/.codex/sessions", [".jsonl"]),
         ("Codex", home + "/.codex/archived_sessions", [".jsonl"]),
         ("Gemini CLI", home + "/.gemini/tmp", [".json", ".jsonl"])]
    }

    static let maximumFileSize = 200 * 1024 * 1024

    public func scan() -> [SecretFinding] {
        var files: [(agent: String, path: String)] = []
        for source in sources {
            guard let enumerator = FileManager.default.enumerator(atPath: source.folder) else { continue }
            for case let relative as String in enumerator where source.suffixes.contains(where: { relative.hasSuffix($0) }) {
                files.append((source.agent, source.folder + "/" + relative))
            }
        }
        var results = [[SecretFinding]](repeating: [], count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let found = scan(file: files[index].path, agent: files[index].agent)
            lock.sync { results[index] = found }
        }
        return results.flatMap { $0 }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    func scan(file: String, agent: String) -> [SecretFinding] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file)
        guard let size = attributes?[.size] as? Int, size > 0, size <= Self.maximumFileSize,
              let data = FileManager.default.contents(atPath: file) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        var counts: [String: (kind: String, value: String, count: Int)] = [:]
        for pattern in Self.patterns {
            pattern.regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let swiftRange = Range(match.range, in: text) else { return }
                let value = String(text[swiftRange])
                counts[value, default: (pattern.kind, value, 0)].count += 1
            }
        }
        guard !counts.isEmpty else { return [] }
        let project = Self.project(in: text)
        let date = attributes?[.modificationDate] as? Date
        return counts.values.map {
            SecretFinding(kind: $0.kind, masked: Self.mask($0.value), agent: agent, file: file, project: project,
                          occurrences: $0.count, lastSeen: date, fingerprint: Self.fingerprint($0.value))
        }
    }

    /// Keeps enough to recognise the key, never enough to use it.
    public static func mask(_ value: String) -> String {
        if value.hasPrefix("-----BEGIN") { return value }
        let visibleStart = min(value.count / 4, value.hasPrefix("sk-ant-") ? 10 : 6)
        let visibleEnd = min(4, value.count / 6)
        return String(value.prefix(visibleStart)) + "••••••••" + String(value.suffix(visibleEnd))
    }

    /// A short, stable, non-reversible tag for telling values apart without storing them.
    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    static let cwd = try! NSRegularExpression(pattern: #""cwd"\s*:\s*"([^"]+)""#)

    static func project(in text: String) -> String? {
        guard let match = cwd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
