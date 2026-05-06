import Foundation

public enum InstallationKind: Sendable, Equatable {
    /// Installed via Homebrew cask `ai-usages-tracker`.
    case homebrewCask
    /// Bundle lives outside any known package manager prefix — the user copied
    /// the .app manually (e.g. dragged into /Applications, or running ad-hoc).
    case manual
}

public struct InstallationInfo: Sendable, Equatable {
    public let kind: InstallationKind
    public let bundlePath: String

    public init(kind: InstallationKind, bundlePath: String) {
        self.kind = kind
        self.bundlePath = bundlePath
    }
}

/// Detects how the running app bundle was installed, so the installer can pick
/// the right upgrade path (Homebrew cask vs. direct zip replacement).
public actor InstallationDetector {
    private let bundlePath: String
    private let process: ProcessRunning
    private let fileManager: FileManager
    private let homebrewBinaryPaths: [String]
    private let pathEnvironment: String?
    private let loginShellPath: String?

    public static let homebrewCaskName = "ai-usages-tracker"
    public static let homebrewBundlePath = "/Applications/AI Usages Tracker.app"
    public static let homebrewUserBundlePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/AI Usages Tracker.app")
        .path

    public init(
        bundlePath: String,
        process: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        homebrewBinaryPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        loginShellPath: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) {
        self.bundlePath = bundlePath
        self.process = process
        self.fileManager = fileManager
        self.homebrewBinaryPaths = homebrewBinaryPaths
        self.pathEnvironment = pathEnvironment
        self.loginShellPath = loginShellPath
    }

    public func detect() async -> InstallationInfo {
        guard let brewPath = await resolveBrewPath() else {
            return InstallationInfo(kind: .manual, bundlePath: bundlePath)
        }
        // `brew --caskroom` returns the directory containing per-cask folders.
        // The `app` cask stanza copies the .app into /Applications rather than
        // symlinking it, so the running bundle path can't be compared with the
        // caskroom subtree. We still require the running bundle to be the app at
        // Homebrew's global or user appdir: otherwise a manual/dev copy would
        // be misclassified whenever the cask is also installed on the machine.
        let caskroom: String
        do {
            let result = try await process.run(
                executablePath: brewPath,
                arguments: ["--caskroom"],
                timeoutSeconds: 5
            )
            guard result.terminationStatus == 0, !result.timedOut else {
                return InstallationInfo(kind: .manual, bundlePath: bundlePath)
            }
            caskroom = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return InstallationInfo(kind: .manual, bundlePath: bundlePath)
        }

        guard !caskroom.isEmpty else {
            return InstallationInfo(kind: .manual, bundlePath: bundlePath)
        }

        let caskDir = caskroom.hasSuffix("/") ? "\(caskroom)\(Self.homebrewCaskName)" : "\(caskroom)/\(Self.homebrewCaskName)"
        var isDirectory: ObjCBool = false
        if isExpectedHomebrewBundlePath(bundlePath),
           fileManager.fileExists(atPath: caskDir, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return InstallationInfo(kind: .homebrewCask, bundlePath: bundlePath)
        }
        return InstallationInfo(kind: .manual, bundlePath: bundlePath)
    }

    /// Exposed for the installer — returns the path of an existing brew binary
    /// or nil if Homebrew cannot be found through any discovery method.
    public func brewExecutablePath() async -> String? {
        await resolveBrewPath()
    }

    /// Resolves the brew binary path by trying, in order:
    /// 1. Hardcoded standard install paths (`/opt/homebrew/bin/brew`, `/usr/local/bin/brew`).
    /// 2. The inherited `PATH` environment.
    /// 3. The user's login shell — GUI apps launched via Finder/Dock inherit a
    ///    minimal `PATH` that misses Homebrew when it lives outside the
    ///    standard locations (e.g. `~/tools/homebrew`).
    private func resolveBrewPath() async -> String? {
        if let direct = firstExistingBrewPath() { return direct }
        return await brewPathViaLoginShell()
    }

    private func firstExistingBrewPath() -> String? {
        let pathBrewCandidates = (pathEnvironment ?? "")
            .split(separator: ":")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("brew").path }
        return (homebrewBinaryPaths + pathBrewCandidates).first { fileManager.fileExists(atPath: $0) }
    }

    private func isExpectedHomebrewBundlePath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == Self.homebrewBundlePath || standardized == Self.homebrewUserBundlePath
    }

    private func brewPathViaLoginShell() async -> String? {
        guard let shell = loginShellPath, !shell.isEmpty, fileManager.fileExists(atPath: shell) else {
            return nil
        }
        // `-l -i -c "command -v brew"` runs the user's shell as both login AND
        // interactive so every init file gets sourced: `.zshenv`/`.zprofile`
        // (login) plus `.zshrc` (interactive). Many users put their Homebrew
        // PATH setup (`eval "$(brew shellenv)"` or a manual `export PATH=...`)
        // in `.zshrc`, which a login-only non-interactive shell does NOT
        // source. Without `-i` we'd miss those setups and incorrectly fall
        // back to a Manual install classification. Interactive shells can be
        // slow when users have heavy rc files, hence a generous timeout.
        do {
            let result = try await process.run(
                executablePath: shell,
                arguments: ["-l", "-i", "-c", "command -v brew"],
                timeoutSeconds: 10
            )
            guard result.terminationStatus == 0, !result.timedOut else { return nil }
            let lines = String(decoding: result.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines.reversed().first { fileManager.fileExists(atPath: $0) }
        } catch {
            return nil
        }
    }
}
