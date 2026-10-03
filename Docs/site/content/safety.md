+++
title = "Safety model"
weight = 30
+++

- Explicit confirmation for destructive and mutating operations.
- Native read-only mode disables mutation paths.
- Direct API client; no recurring `kubectl get` subprocesses.
- Port forwards bind to loopback only.
- Manifest edits can compare imported YAML with a UID-pinned live object through a server-side-apply dry run, then dry-run before apply; they preserve UID identity and never force field ownership.
- Kubeconfig credentials and endpoints remain opaque to the Swift UI: the helper owns Kubernetes authentication.

## Parity status

K9k is actively developed but is not yet complete K9s parity. Notable remaining areas include remote/OCI Helm sources, Kustomize rendering, truly progressive browsing of very large resource sets, modern live Event streams, and the remainder of K9s's specialised renderers. Host SSH is an explicit handoff to macOS OpenSSH. Image scanning is available only through an explicitly configured local scanner. Node Shell uses an explicitly configured, existing trusted DaemonSet rather than an automatically created privileged Pod.

See the [parity ledger](@/parity.md) for details.
