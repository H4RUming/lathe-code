import Foundation
import LatheDomain

public enum PolicyDecision: Equatable, Sendable { case allow, ask, deny(String) }

public enum PolicyEngine {
    public static func decision(_ prepared: PreparedTool, mode: PermissionMode) -> PolicyDecision {
        switch mode {
        case .fullAccess: return .allow
        case .requestApproval: return .ask
        case .acceptEdits: return prepared.effect == .shell ? .ask : .allow
        case .autoApprove: return isLowRisk(prepared) ? .allow : .ask
        }
    }

    /// A small deterministic allowlist, not a model's claim that work is safe.
    /// Unknown paths, configuration, credentials and executable files ask first.
    private static func isLowRisk(_ prepared: PreparedTool) -> Bool {
        switch prepared.operation {
        case .command(let request, _, _):
            // No shell expansion, flags, environment launcher or path aliases.
            // Other commands may execute configuration/hooks or touch the network.
            return request.executable == "/bin/pwd" && request.arguments.isEmpty
        case .list(let path):
            return ordinaryPath(path, directory: true)
        case .read(let path), .write(let path, _, _):
            return !prepared.executableFile && ordinaryPath(path, directory: false)
        }
    }

    private static func ordinaryPath(_ path: String, directory: Bool) -> Bool {
        if path == "." { return directory }
        let originalComponents = path.split(separator: "/").map(String.init)
        guard !originalComponents.isEmpty, !originalComponents.contains(where: sensitiveComponent) else { return false }
        let components = originalComponents.map { $0.lowercased() }
        let directories = directory ? components : Array(components.dropLast())
        // A root filename or paths below a recognized source/documentation tree
        // qualify; an unfamiliar top-level directory needs human judgment.
        if let first = directories.first, !sourceDirectories.contains(first) { return false }
        if directory { return true }
        guard let name = components.last else { return false }
        if documentationNames.contains(name) { return true }
        return sourceExtensions.contains((name as NSString).pathExtension)
    }

    private static func sensitiveComponent(_ component: String) -> Bool {
        let lowered = component.lowercased()
        if lowered.hasPrefix(".") || restrictedNames.contains(lowered) || lowered.hasPrefix("package@swift-") { return true }
        // Split both lowerCamelCase and acronym boundaries (userSecrets, APIKey).
        let separated = component
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        let words = separated.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains { sensitiveWords.contains($0) }
    }

    private static let sourceDirectories: Set<String> = [
        "src", "source", "sources", "test", "tests", "docs", "documentation",
        "examples", "samples", "include", "lib", "libs", "app", "apps", "modules",
        "components", "views", "models", "resources", "assets", "packages",
    ]
    private static let sourceExtensions: Set<String> = [
        "swift", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "rs", "go",
        "java", "kt", "py", "js", "jsx", "ts", "tsx", "html", "css", "scss",
        "md", "markdown", "rst", "txt",
    ]
    private static let documentationNames: Set<String> = ["readme", "license", "licence", "copying", "changelog"]
    private static let restrictedNames: Set<String> = [
        "package.swift", "makefile", "gnumakefile", "dockerfile", "jenkinsfile",
        "gemfile", "rakefile", "justfile", "procfile", "cmakelists.txt",
        "agents.md", "claude.md", "skill.md", "copilot-instructions.md",
        "setup.py", "setup.cfg", "install.py", "build.py", "bootstrap.py", "conftest.py", "sitecustomize.py", "usercustomize.py",
        "bin", "sbin", "scripts", "script", "hooks", "hook", "build", "dist",
        "node_modules", "vendor", "venv", "target", "ci", "deploy", "deployment",
    ]
    private static let sensitiveWords: Set<String> = [
        "secret", "secrets", "credential", "credentials", "password", "passwords",
        "token", "tokens", "private", "key", "keys", "keystore", "keychain",
        "config", "configuration", "settings", "environment", "env", "ssh", "aws",
        "auth", "oauth", "certificate", "certificates", "rsa", "ed25519",
        "setup", "install", "bootstrap", "build", "deploy", "hook", "hooks",
    ]
}
