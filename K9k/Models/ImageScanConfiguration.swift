import Foundation

/// K9s ships an embedded Grype integration behind `imageScans.enable`. K9k
/// deliberately does not bundle, download, or guess at a scanner. Instead an
/// operator can opt into a locally installed scanner with an explicit command
/// description. The description contains no shell syntax and no credentials.
struct ImageScanConfiguration: Codable, Hashable {
    var executablePath: String = ""
    /// One process argument per line. `{{image}}` is replaced with the exact
    /// immutable image reference selected in the scan sheet.
    var argumentTemplate: String = "{{image}}"

    static let imagePlaceholder = "{{image}}"

    var arguments: [String] {
        argumentTemplate
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns a user-facing explanation when this configuration cannot be
    /// executed safely. The scanner owns any credentials through its own
    /// Keychain/configuration; K9k never persists them in this preference.
    func validationMessage(fileManager: FileManager = .default) -> String? {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "Choose the absolute path to a locally installed scanner." }
        guard path.hasPrefix("/") else { return "The scanner executable must be an absolute path." }
        guard fileManager.isExecutableFile(atPath: path) else { return "K9k cannot execute \(path). Check that the file exists and is executable." }
        guard !arguments.isEmpty else { return "Add one or more arguments, including \(Self.imagePlaceholder)." }
        guard arguments.contains(where: { $0.contains(Self.imagePlaceholder) }) else { return "The argument template must include \(Self.imagePlaceholder)." }
        guard !containsInlineSecret(executablePath), !containsInlineSecret(argumentTemplate) else {
            return "Credentials are not allowed in the scanner configuration. Configure the scanner's Keychain or its own credential store instead."
        }
        return nil
    }

    func expandedArguments(for image: String) -> [String] {
        arguments.map { $0.replacingOccurrences(of: Self.imagePlaceholder, with: image) }
    }

    private func containsInlineSecret(_ value: String) -> Bool {
        let assignment = #"(?i)(?:authorization\s*[:=]|bearer\s+|(?:token|password|secret|api[-_]?key|credential|private[-_]?key)\s*=)"#
        let sensitiveFlag = #"(?i)(?:^|\s)--?(?:token|password|secret|api[-_]?key|authorization|credential|private[-_]?key)(?:$|\s|=)"#
        return value.range(of: assignment, options: .regularExpression) != nil ||
            value.range(of: sensitiveFlag, options: .regularExpression) != nil
    }
}

enum ImageScanPreferences {
    private static let key = "k9k.imageScanConfiguration.v1"

    static func load() -> ImageScanConfiguration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configuration = try? JSONDecoder().decode(ImageScanConfiguration.self, from: data) else {
            return ImageScanConfiguration()
        }
        return configuration
    }

    static func save(_ configuration: ImageScanConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// A single immutable workload image reference. The source is informational;
/// the scanner receives only the image reference, never a Pod manifest,
/// kubeconfig, environment credentials, or shell command.
struct ImageScanTarget: Identifiable, Hashable {
    let image: String
    let locations: [String]
    var id: String { image }
}
