import Foundation
import Security

/// Runs command-line tools and collects what they print.
public enum Shell {
    public struct Output: Sendable {
        public let status: Int32
        public let text: String
    }

    /// Runs `executable` and waits for it. Standard output and error are collected together.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], input: String? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // Always give the tool its own input, so nothing waits on a terminal that isn't there.
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        do {
            try process.run()
        } catch {
            return Output(status: -1, text: error.localizedDescription)
        }
        if let input { inputPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inputPipe.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    /// Quotes `text` as one argument for /bin/sh.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command as root after the standard macOS password prompt. Unlike
    /// `PrivilegedRunner.run`, this is safe off the main thread, so long tasks don't freeze the window.
    public static func runAsAdmin(_ command: String) -> Result<String, PrivilegedRunner.Failure> {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let output = run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if output.status == 0 { return .success(output.text) }
        if output.text.contains("-128") { return .failure(.cancelled) }
        return .failure(.failed(output.text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// Code-signing checks used by Malware Removal and the Updater.
enum CodeSignature {
    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// True when the file carries no code signature at all.
    static func isUnsigned(_ url: URL) -> Bool {
        guard let code = staticCode(url) else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == OSStatus(errSecCSUnsigned)
    }

    /// True when the signature is intact.
    static func isValid(_ url: URL) -> Bool {
        guard let code = staticCode(url) else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    /// The developer's Team ID from the signature, if it was signed with a Developer ID or by the App Store.
    static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True for compiled programs, as opposed to scripts or other files.
    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let bytes = handle.readData(ofLength: 4)
        guard bytes.count == 4 else { return false }
        let magic = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }
}
