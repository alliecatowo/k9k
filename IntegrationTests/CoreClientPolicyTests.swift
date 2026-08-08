import Foundation

/// Exercises the app-wide policy gate with a tiny deterministic NDJSON helper.
/// The helper records request order, which proves that each CoreClient writes
/// `policy.readOnly` before it can send its first ordinary operation.
@main
struct CoreClientPolicyTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("k9k-core-client-policy-\(UUID().uuidString)", isDirectory: true)
        let helper = directory.appendingPathComponent("fake-core")
        let trace = directory.appendingPathComponent("trace.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        set -eu
        : "${K9K_POLICY_TEST_LOG:?}"
        while IFS= read -r line; do
          case "$line" in
            *'"operation":"policy.readOnly"'*)
              case "$line" in
                *'"enabled":true'*) enabled=true ;;
                *) enabled=false ;;
              esac
              printf 'policy:%s\n' "$enabled" >> "$K9K_POLICY_TEST_LOG"
              ;;
            *)
              operation=$(printf '%s' "$line" | sed -n 's/.*"operation":"\([^"]*\)".*/\1/p')
              printf '%s\n' "$operation" >> "$K9K_POLICY_TEST_LOG"
              ;;
          esac
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
          printf '{"version":1,"id":"%s","type":"response","result":{}}\n' "$id"
        done
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("K9K_CORE_PATH", helper.path, 1)
        setenv("K9K_POLICY_TEST_LOG", trace.path, 1)
        defer {
            unsetenv("K9K_CORE_PATH")
            unsetenv("K9K_POLICY_TEST_LOG")
        }

        try await runAssertions(trace: trace)
    }

    @MainActor
    private static func runAssertions(trace: URL) async throws {
        CoreClient.setApplicationReadOnlyPolicy(true)
        let primary = CoreClient()
        let secondary = CoreClient()
        defer {
            primary.stop()
            secondary.stop()
            CoreClient.setApplicationReadOnlyPolicy(false)
        }

        _ = try await primary.request("health")
        assertTrace(trace, equals: ["policy:true", "health"], message: "a fresh primary helper must receive policy before health")

        _ = try await secondary.request("helm.history")
        assertTrace(trace, equals: ["policy:true", "health", "policy:true", "helm.history"], message: "a fresh secondary helper must receive policy before Helm history")

        CoreClient.setApplicationReadOnlyPolicy(false)
        _ = try await primary.request("discovery.list")
        assertTrace(trace, equals: ["policy:true", "health", "policy:true", "helm.history", "policy:false", "discovery.list"], message: "the next primary operation must replay a changed policy")

        primary.stop()
        CoreClient.setApplicationReadOnlyPolicy(true)
        _ = try await primary.request("resource.listPage")
        assertTrace(trace, equals: ["policy:true", "health", "policy:true", "helm.history", "policy:false", "discovery.list", "policy:true", "resource.listPage"], message: "a relaunched helper must receive policy before its first operation")

        _ = try await secondary.request("exec.open")
        assertTrace(trace, equals: ["policy:true", "health", "policy:true", "helm.history", "policy:false", "discovery.list", "policy:true", "resource.listPage", "policy:true", "exec.open"], message: "an existing secondary helper must replay the latest policy before an interactive operation")
    }

    private static func assertTrace(_ url: URL, equals expected: [String], message: String) {
        let trace = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
        precondition(trace == expected, "\(message). trace=\(trace), expected=\(expected)")
    }
}
