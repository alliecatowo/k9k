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
    /// Parsing is opt-in. Selecting a format never changes the scanner
    /// command: the operator must configure that tool's output themselves.
    var reportFormat: ImageScanReportFormat = .raw

    static let imagePlaceholder = "{{image}}"

    private enum CodingKeys: String, CodingKey { case executablePath, argumentTemplate, reportFormat }

    init(executablePath: String = "", argumentTemplate: String = "{{image}}", reportFormat: ImageScanReportFormat = .raw) {
        self.executablePath = executablePath
        self.argumentTemplate = argumentTemplate
        self.reportFormat = reportFormat
    }

    /// Old preferences preceded report normalisation. Decode them as raw
    /// rather than discarding the operator's configured scanner.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        argumentTemplate = try container.decodeIfPresent(String.self, forKey: .argumentTemplate) ?? Self.imagePlaceholder
        reportFormat = try container.decodeIfPresent(ImageScanReportFormat.self, forKey: .reportFormat) ?? .raw
    }

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

enum ImageScanReportFormat: String, Codable, CaseIterable, Identifiable {
    case raw
    case grypeJSON

    var id: String { rawValue }
    var title: String {
        switch self {
        case .raw: "Raw output only"
        case .grypeJSON: "Grype JSON"
        }
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

/// A redaction-safe projection of a machine-readable vulnerability result.
/// It deliberately excludes package locations, URLs, advisory descriptions,
/// scanner metadata, and any raw scanner fields that may carry credentials.
struct ImageScanFinding: Identifiable, Hashable {
    let image: String
    let vulnerabilityID: String
    let severity: String
    let package: String
    let installedVersion: String
    let fixedIn: String?
    var id: String { "\(image)|\(vulnerabilityID)|\(package)|\(installedVersion)" }

    var severityRank: Int {
        switch severity.uppercased() {
        case "CRITICAL": 0
        case "HIGH": 1
        case "MEDIUM", "MODERATE": 2
        case "LOW": 3
        case "NEGLIGIBLE": 4
        default: 5
        }
    }
}

struct ImageScanNormalizedReport: Identifiable, Hashable {
    let image: String
    let findings: [ImageScanFinding]
    let diagnostic: String?
    var id: String { image }
}

/// The sole supported machine-readable scanner format. It fails closed: an
/// unparseable report is never presented as partial vulnerability data.
enum ImageScanReportNormalizer {
    private struct GrypeDocument: Decodable {
        let matches: [Match]
    }

    private struct Match: Decodable {
        let artifact: Artifact?
        let vulnerability: Vulnerability?
    }

    private struct Artifact: Decodable {
        let name: String?
        let version: String?
    }

    private struct Vulnerability: Decodable {
        let id: String?
        let severity: String?
        let fix: Fix?
    }

    private struct Fix: Decodable {
        let versions: [String]?
    }

    static func normalizeGrypeJSON(_ output: String, image: String) -> ImageScanNormalizedReport {
        guard let data = output.data(using: .utf8) else {
            return ImageScanNormalizedReport(image: image, findings: [], diagnostic: "The scanner output could not be decoded as Grype JSON.")
        }
        do {
            let document = try JSONDecoder().decode(GrypeDocument.self, from: data)
            let findings = document.matches.compactMap { match -> ImageScanFinding? in
                guard let id = match.vulnerability?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
                let severity = match.vulnerability?.severity?.trimmingCharacters(in: .whitespacesAndNewlines)
                let package = match.artifact?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let version = match.artifact?.version?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fixes = match.vulnerability?.fix?.versions?.filter { !$0.isEmpty } ?? []
                return ImageScanFinding(
                    image: image,
                    vulnerabilityID: id,
                    severity: severity?.isEmpty == false ? severity! : "Unknown",
                    package: package?.isEmpty == false ? package! : "Unknown package",
                    installedVersion: version?.isEmpty == false ? version! : "Unknown version",
                    fixedIn: fixes.isEmpty ? nil : fixes.joined(separator: ", ")
                )
            }
            return ImageScanNormalizedReport(image: image, findings: findings, diagnostic: nil)
        } catch {
            return ImageScanNormalizedReport(image: image, findings: [], diagnostic: "The scanner output was not valid Grype JSON. Check the configured output arguments, then review Raw Output.")
        }
    }
}
