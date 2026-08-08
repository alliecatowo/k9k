# K9k release audit and implementation backlog

Audit date: 2026-08-07  
Audited revision: `0e5069e`  
Target: macOS Tahoe 26+, Swift 6, Go 1.25, Kubernetes client libraries 0.35

## Decision

K9k is a substantial native Kubernetes client, not a prototype shell: discovery, projected list/watch, inspectors, direct exec/attach/logs, port forwarding, manifests, Helm lifecycle, RBAC, topology, metrics, node workflows, and K9s configuration all have working implementations. The current revision builds and its Go suites pass.

It is **not yet a release candidate**. The audit initially found four release blockers that could violate an operator's expectation about which cluster or safety policy is active, or make the primary browser unusable at an ordinary window size:

1. A failed context switch can publish the requested context while retaining clients for the previous cluster.
2. A successful context switch does not fence every watch/log/exec/attach stream from the previous cluster.
3. Read-only policy is process-local but several features create their own helper process, and a restarted helper starts writable.
4. The system floating sidebar can occlude the first resource-table column in the default three-column layout.

The first implementation wave closed those four blockers and added deterministic regressions plus live native UI evidence. Modern event streaming and true large-cluster progressive loading remain the two open P0 operational priorities; signed/notarized distribution is also still required before a public release artifact.

## Wave 1 implementation result

- Context selection now constructs every replacement client before one atomic commit, serializes queued selections, cancels and generation-fences every old watch/log/exec/attach/forward, and restores the authoritative old browser after failure.
- One app-wide read-only policy generation is replayed before every ordinary request on every primary, secondary, fresh, or relaunched helper process.
- The 1280-point native workspace contract keeps a wide 340-point minimum sidebar and 360-point minimum inspector without forcing a detail-frame constraint. The latter was A/B-proven to shift Tahoe's sidebar List to a negative origin and was removed.
- Repeated live validation covered four sidebar hide/reveal cycles, six inspector hide/reveal cycles, the four inspector tabs, the minimum-width toolbar, and the original restored split state without deleting user preferences.
- Pull-request CI now performs non-mutating format checks, Go race tests/vet/helper build, the macOS app build, focused Swift harnesses, and bundled-helper verification. Signing, notarization, SBOM, and release publication remain open parts of K9K-REL-016.
- Inspector selection hydration no longer pays a fixed 300 ms delay. It is cancellation- and identity-bound; prepared overview content survives repeat reveal, only an unprepared hidden selection defers until the native transition settles, and Reduce Motion bypasses that defer.

Final integration evidence for this wave:

| Gate | Result |
| --- | --- |
| Non-mutating Go format check | Pass |
| Go unit tests, vet, and race detector | Pass |
| CoreClient read-only replay harness | Pass |
| Workspace geometry harness | Pass |
| Bounded benchmark-history/export harness | Pass (and corrected ISO-8601 round-trip decoding) |
| Helper and macOS app build | Pass |
| Debug bundle seal and exact bundled-helper health request | Pass |
| Diff check, CI YAML parse, focused credential-pattern scan | Pass |
| Computer Use: sidebar/table/inspector/tabs/toolbar/reveal | Pass; final captures are checked into `Documentation/Media` |

## Audit method and baseline

The audit combined:

- source inspection of the SwiftUI app, NDJSON boundary, Go API dispatcher, Kubernetes clients, tests, build scripts, and documentation;
- a source-pinned comparison with `.vendor/k9s` and the existing [parity ledger](K9S_PARITY.md);
- live inspection of the Kind-backed app with its sidebar, resource table, inspector, command palette, help, and toolbar;
- Apple guidance for [designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility);
- `go test ./...`, `go vet ./...`, `go test -race ./...`, app/helper builds, and diff checks.

Baseline evidence:

| Gate | Result at audit start |
| --- | --- |
| Debug app and bundled helper | Pass |
| Go tests and vet | Pass |
| Go race detector | Pass |
| Go statement coverage | API 72.4%, config 71.1%, kube 36.2%, protocol 100% |
| Swift test target | Missing; the project has one application target |
| Pull-request CI | Missing; no checked-in GitHub Actions workflow |
| Live Kind browse/inspect | Pass, with the layout finding in K9K-UI-004 |

## Ticket index

Status meanings: **Done** has implementation and verification evidence; **Assigned** is in the current implementation wave; **Partial** has a bounded subset completed; **Open** is audited and ready to schedule; **Deferred** needs an explicit product/security decision before implementation.

| Ticket | Priority | Status | Outcome |
| --- | --- | --- | --- |
| K9K-CTX-001 | P0 | Done | Context/client replacement is atomic on success only. |
| K9K-SEC-002 | P0 | Done | Read-only policy applies to every helper, including restarts. |
| K9K-CTX-003 | P0 | Done | Context switching is a hard stream barrier. |
| K9K-UI-004 | P0 | Done | Sidebar, table, and inspector never occlude each other. |
| K9K-OPS-005 | P0 | Open | Modern UID-scoped live Kubernetes events. |
| K9K-PERF-006 | P0 | Open | Progressive large-cluster loading and batched watch publication. |
| K9K-MUT-007 | P1 | Open | Generic mutations are protected against delete/recreate and stale writes. |
| K9K-IPC-008 | P1 | Open | Unary IPC work has deadlines, concurrency limits, and cancellation. |
| K9K-PERF-009 | P1 | Open | Service forwarding resolves one Pod without returning a raw Pod list. |
| K9K-UI-010 | P1 | Open | Primary toolbar actions remain discoverable without opaque overflow. |
| K9K-UI-011 | P1 | Open | Command Palette supports reliable keyboard result navigation. |
| K9K-UI-012 | P1 | Done | Inspector values remain readable and reveal work is latency-aware. |
| K9K-MAN-013 | P1 | Open | Manifest Workspace safely renders bounded local Kustomizations. |
| K9K-NAV-014 | P1 | Open | Aggregate workload browsing and direct Show Pods navigation. |
| K9K-LOG-015 | P1 | Open | Opt-in merged logs for sidecar-heavy Pods. |
| K9K-REL-016 | P1 | Partial | Non-mutating CI and a signed/notarized release path. |
| K9K-QA-017 | P1 | Partial | Swift behavioral and UI regression tests cover safety-critical state. |
| K9K-LOCAL-018 | P2 | Open | Local plugin/scanner output and process lifecycle remain bounded. |
| K9K-A11Y-019 | P2 | Open | Reduced Motion/Transparency, contrast, and VoiceOver are verified. |
| K9K-UI-020 | P2 | Open | Operational sheets use consistent, resizable native presentation. |
| K9K-SEC-021 | P2 | Deferred | Secret reveal is explicit, ephemeral, bounded, and never cached/exported implicitly. |
| K9K-OPS-022 | P2 | Open | Completed/failed Pod cleanup has a safe preview and UID preconditions. |
| K9K-HELM-023 | P2 | Open | Helm storage driver support is not hard-coded to Secrets. |
| K9K-DOC-024 | P2 | Done | Architecture, README, notices, and parity claims match the product. |
| K9K-APP-025 | P2 | Open | The New Cluster Window command works or is removed. |
| K9K-UI-026 | P3 | Open | Content surfaces remain flat; glass/material stays in navigation controls. |
| K9K-REN-027 | P3 | Open | Remaining K9s custom renderer compatibility is explicit and tested. |

## P0 tickets

### K9K-CTX-001 — Make context switching atomic

Finding: `Cluster.reload` assigns `config` and `context` before `ClientConfig()` and all typed/dynamic/discovery/metrics clients have been created. If any construction step fails, `Contexts()` can describe the requested context as active while resource operations still hold the previous clients. In a production tool, mixed identity is a wrong-cluster risk.

Acceptance criteria:

- Construct the candidate deferred config, REST config, and every replacement client in local values.
- Swap `config`, `context`, `rest`, `dynamic`, `typed`, `discovery`, and `metrics` together only after all construction succeeds.
- A failed switch preserves the complete previous state and still reports the previous context active.
- Unit tests exercise invalid/missing context selection and a client-construction failure.

Primary files: `Backend/internal/kube/cluster.go`, `Backend/internal/kube/cluster_test.go`.

### K9K-SEC-002 — Replay read-only policy for every helper process

Finding: helper policy is deliberately process-local. `ClusterStore` synchronizes its private `CoreClient`, but Helm history/inspection/upgrade, rollout history, repository inspection, and Pod transfer create separate clients. A helper restart also starts with `readOnly=false`. A UI-disabled button is not the security boundary promised by the architecture.

Acceptance criteria:

- There is one app-wide current read-only policy shared by all `CoreClient` instances.
- Every new or relaunched helper applies that policy before its first non-policy operation.
- Changing the toggle updates live helper instances or makes their next operation synchronize first.
- Secondary helpers reject protected exec, port-forward, context/config writes, manifest/Helm mutations, and generic mutations with `read_only`.
- Tests cover a fresh secondary client and a helper relaunch while read-only is enabled.

Primary files: `K9k/IPC/CoreClient.swift`, `K9k/Services/ClusterStore.swift`, secondary-client feature views/controllers, protocol lifecycle tests.

### K9K-CTX-003 — Treat context selection as a stream barrier

Finding: the Store closes port forwards before a switch, but not its resource watch, logs, exec, or attach session. The backend changes clients without cancelling registered streams, so old-context events and interactive I/O can outlive the visible context.

Acceptance criteria:

- The helper cancels and fences every registered stream before committing a context change.
- Swift clears or cancels matching watch, log, exec/attach, and forward state before the request.
- No event from an old stream can mutate new-context state after a successful switch.
- A failed switch preserves the old context and may safely re-establish only the old-context browser watch.
- Tests cover watch, log, exec/attach, and port-forward cancellation/late events.

Primary files: `Backend/internal/api/server.go`, `Backend/internal/api/server_test.go`, `K9k/Services/ClusterStore.swift`.

### K9K-UI-004 — Prevent split-view table occlusion

Finding: live inspection at the default 1280×800 window showed the Tahoe floating sidebar over the beginning of the resource table. The first Name values were obscured even though accessibility reported a 348-point sidebar column. Current fixed minimums do not prove a usable content width across default, restored, and full-screen states.

Acceptance criteria:

- At default, minimum, restored, and full-screen window sizes, sidebar content, the complete first table column, and inspector content never overlap or clip.
- The sidebar remains system-managed and resizable; the wide inspector remains resizable and collapsible, while compact layouts use a contained native sheet.
- The Name column has a usable minimum after both navigation surfaces are visible.
- Add deterministic screenshot/geometry regression coverage for sidebar shown/hidden and inspector shown/hidden.

Resolution evidence: restored frames are normalized against the active display's visible frame without discarding valid Mac window restoration. Compact workspaces keep the wide operational sidebar and browser in the system-negotiated split lanes, while the inspector opens in a contained native sheet. Roomy windows use a resizable in-flow trailing split panel; SwiftUI's native `.inspector` was rejected after live testing showed Tahoe allocating part of its declared minimum beyond the owning window even at full-screen. The in-flow panel stays mounted at zero width when collapsed, preserving its selected tab and prepared details instead of rebuilding on every toggle. Like K9s, the native table computes its budget from measured split widths, quantized to avoid per-pixel rebuilds during divider drags, and drops lower-priority columns when its lane cannot hold them. Name, Status, and then Age stay ahead of optional projections instead of horizontally scrolling Name under the sidebar. The geometry harness covers oversized restored frames, compact screens, negative-origin displays, wide in-flow inspector sizing, measurement quantization, and the compact four-column/five-column threshold. Live validation exercises repeated sidebar and inspector presentation cycles at compact and wide sizes.

Primary files: `K9k/Features/K9kRootView.swift`, `K9k/Features/ResourceBrowserView.swift`, `K9k/Features/ResourceInspectorView.swift`, `K9k/Services/ClusterStore.swift`, `K9k/App/K9kApp.swift`, and `K9k/App/WindowSizeConfigurator.swift`.

### K9K-OPS-005 — Stream modern Kubernetes Events

Finding: K9k polls legacy `core/v1` Events every five seconds. K9s uses `events.k8s.io/v1`, whose series semantics are the modern event source. Snapshot polling is slower during scheduling/image-pull/rollout incidents and spends more API calls while the tab is open.

Acceptance criteria:

- Prefer `events.k8s.io/v1`, with an explicit `core/v1` fallback only when the API is unavailable.
- Add a UID-scoped cancellable `events.watch` stream that exists only while the Events tab is visible.
- Normalize series/count/time fields into stable `ClusterEvent` identities and deterministic newest-first ordering.
- Reconnect with bounded policy and show forbidden/unavailable diagnostics rather than an empty timeline.
- Tests cover v1, fallback, RBAC denial, cancellation, reconnect, and live Kind delivery.

Primary files: Kubernetes client, API dispatcher/types, `ClusterStore`, `ResourceInspectorView`, protocol/parity docs.

### K9K-PERF-006 — Progressive loading and watch batching

Finding: `resource.listPage` is capped and pages now append without quadratic snapshot reconstruction, but `ClusterStore.loadResources` still drains every continuation before starting its watch. Each watch event can trigger indexed mutation plus immediate sort/filter publication on the main actor.

Acceptance criteria:

- The first 250 projected rows become interactive before later pages complete.
- Continuations load in a generation-bound cancellable task with visible progress/Load More semantics.
- The watch begins from a consistent snapshot resourceVersion without a list-to-watch event gap.
- High-rate watch mutations are coalesced into bounded UI commits and search is debounced for large lists.
- Preserve selection, custom sort, export, filters, history, and context switching.
- Stress-test at least 10,000 projected rows and a 1,000-event burst with no duplicate/lost IDs.

Primary files: `K9k/Services/ClusterStore.swift`, `K9k/Features/ResourceBrowserView.swift`, list/watch models and focused test harness.

## P1 tickets

### K9K-MUT-007 — Add identity preconditions to generic mutation

Generic delete, patch, and scale accept no expected UID/resourceVersion. Require selected identity, use a UID precondition for delete, and return stable stale/conflict errors for delete/recreate or concurrent updates. Cover stale scale and recreated-name deletion.

### K9K-IPC-008 — Bound unary IPC work

The helper spawns one goroutine per ordinary request with no shared concurrency cap, and most Kubernetes calls have no deadline. Add an in-flight semaphore, per-operation deadlines, wire-visible `busy`/`deadline_exceeded`, Swift task cancellation, and delayed-client/shutdown tests.

### K9K-PERF-009 — Replace raw Service-forward Pod lookup

The Service forward resolver uses unpaginated `resource.list` and returns matching raw Pods before selecting one. Add a dedicated bounded backend resolver that returns one eligible Pod and resolved target port; never send a broad raw Pod list across IPC. Also cap every projected scalar value.

### K9K-UI-010 — Make the operational toolbar overflow-safe

At ordinary width, Command Palette, Help, inspector toggle, import, and the resource-action menu collapse into an opaque overflow item. Keep Refresh, Command Palette, inspector toggle, and selected-resource actions discoverable; move low-frequency commands to `.secondaryAction` and ensure every toolbar command also has a menu-bar command, per Apple guidance.

### K9K-UI-011 — Fix Command Palette keyboard navigation

The focused text field consumes Up/Down before the current `onKeyPress` handlers update the active row. `⌘K` must focus search; Up/Down must visibly and accessibly change one result; Return activates it; Escape closes it. Add an AX smoke test.

### K9K-UI-012 — Make inspector detail readable without reintroducing reveal jank

Long RBAC reasons, metric errors, names, and label values truncate in 360–420-point inspectors. At the same time, selection hydration waits 300 ms and detail construction waits another 260 ms. Start safe data work promptly, defer only expensive view construction during an actual reveal, honor Reduce Motion, wrap/select long diagnostics, and measure selection-to-header/detail timing.

### K9K-MAN-013 — Add bounded local Kustomize plans

Detect `kustomization.yaml`, `kustomization.yml`, and `Kustomization`; render with a bundled Go implementation, never `kubectl` or a shell. Show the bounded result before any Kubernetes request, then reuse mixed-GVR discovery, all-document dry run, UID safety, non-force SSA, and confirmation. Reject remote bases/plugins and unsupported generators by default.

### K9K-NAV-014 — Add aggregate Workloads and direct Show Pods

Provide a native aggregate route for Deployments, StatefulSets, DaemonSets, ReplicaSets, and optionally ReplicationControllers. Add direct Show Pods actions for Services/controllers/Jobs and `spec.nodeName` for Nodes, using the normal browser selectors and Back/Forward history. Never guess a selector-less Service.

### K9K-LOG-015 — Add opt-in merged sidecar logs

The current single-container viewer now supports regular, init, and ephemeral containers well. Add an explicit All Running Containers mode with source labels, bounded concurrent streams, deterministic timestamp merge, per-container errors, total line/output caps, and complete cancellation. Copy/save must retain source labels.

### K9K-REL-016 — Establish CI and a distributable release path

There is no checked-in CI workflow. `mise check` mutates source with `gofmt -w`; the current script builds an unsigned Debug app and copies the helper after Xcode build. Add non-mutating format checks, Go test/vet/race, app build, and integration gates for pull requests. For tags, bundle before signing, archive, sign, verify, notarize/staple, and publish checksums plus an SBOM. Add a real app icon and verify the final bundle has no development override.

### K9K-QA-017 — Add Swift behavioral and UI tests

The Xcode project has only the app target. Add focused tests for CoreClient fragmentation/restart/policy replay, context state generation, resource paging/watch coalescing, port-forward reconnect, local process caps, navigation, and split-view/inspector geometry. Keep Kind acceptance separate from deterministic unit/UI tests.

## P2/P3 tickets

### K9K-LOCAL-018 — Bound local process output

Cap K9s plugin output by bytes and lines with an explicit truncation marker; clean up file-handle callbacks on every exit. Bound aggregate image-scan results across many images, not only each child. Add noisy-process tests and a documented terminal scrollback policy.

### K9K-A11Y-019 — Honor accessibility environments

Audit and test Reduced Motion, Reduced Transparency, Increase Contrast, Differentiate Without Color, Full Keyboard Access, and VoiceOver. Status must never rely on color alone. Navigation Help rows and dynamic table rows need deterministic individual labels and values.

### K9K-UI-020 — Standardize operational sheets

Replace brittle fixed frames with sane min/ideal/max sizing, use `NavigationStack` and native toolbars where appropriate, and give every sheet a consistent Close/Cancel/Escape path. Preserve flat content surfaces and system sheet chrome.

### K9K-SEC-021 — Design an intentional Secret reveal workflow

Keep values hidden by default. If implemented, require a visible acknowledgement, fresh UID validation, explicit key selection, bounded decode, no persistence/cache/history, deliberate copy, and immediate clearing on dismissal. This remains deferred until the product accepts the screenshot/clipboard threat model.

### K9K-OPS-022 — Preview and clean completed Pods safely

Preview only Succeeded/Failed Pods in the chosen scope, access-review every target before the first write, require typed confirmation, use UID-preconditioned deletes, and report per-Pod outcomes. Never include Running/Pending/Unknown Pods.

### K9K-HELM-023 — Support Helm storage drivers explicitly

Abstract release history/identity/lifecycle over Secret and ConfigMap storage without silent fallback. Keep remote HTTP/OCI and credentialed repository fetching out of scope until a separate credential-isolation and digest-pinning design is approved.

### K9K-DOC-024 — Reconcile product and legal documentation

The architecture still calls reconnect/relist unfinished while the parity ledger describes it as present; it names unimplemented diagnostic streams; README's remaining-gap paragraph predates local Helm upgrade and Manifest Workspace; third-party notices omit the direct Helm SDK dependency. Make one tested lifecycle contract authoritative and update notices/provenance.

### K9K-APP-025 — Fix the New Cluster Window command

`New Cluster Window` currently has an empty action. Implement genuine independent per-window cluster state with standard window commands, or remove the command until that architecture exists. Never create two windows that misleadingly share selection/context state.

### K9K-UI-026 — Keep Liquid Glass out of dense content

Remove `.regularMaterial` and decorative capsule/card treatments from diff, RBAC, and topology content where they compete with legibility. Continue using native `NavigationSplitView`, toolbar, inspector, sheet, Table, Form, and window backgrounds; verify normal and Reduced Transparency appearances.

### K9K-REN-027 — Complete or explicitly bound custom renderers

Inventory every K9s renderer symbol/config expression still skipped by `K9sViewColumns`. Implement safe scalar renderers with projection tests, and keep unsupported array/filter/programmatic renderers visibly diagnosed instead of producing blank columns.

## Implementation waves

### Wave 1 — release blockers (completed)

| Owner | Tickets | Integration boundary |
| --- | --- | --- |
| Production safety agent | K9K-CTX-001, K9K-CTX-003 | Go cluster/API plus context lifecycle in Store |
| Helper-policy agent | K9K-SEC-002 | CoreClient and secondary helper users |
| macOS UI agent | K9K-UI-004 | Split-view/window/table geometry only |
| Primary integrator | Audit, validation, docs, CI preparation | Avoids shared source until agent handoff |

### Wave 2 — operator speed

K9K-OPS-005, K9K-PERF-006, K9K-PERF-009, K9K-UI-010, and K9K-UI-012.

### Wave 3 — parity and distribution

K9K-MAN-013, K9K-NAV-014, K9K-LOG-015, K9K-REL-016, and K9K-QA-017, followed by the P2/P3 backlog.

## Release gate

A release candidate requires:

- every P0 ticket closed with an automated regression test;
- one serialized clean app/helper build plus Go test/vet/race and diff checks;
- a fresh Kind smoke covering context switch, browse/watch, inspect/events, logs, exec cancellation, a loopback forward, dry-run manifest, and read-only rejection;
- normal, sidebar-hidden, inspector-hidden, minimum-size, full-screen, Reduced Motion, Reduced Transparency, Increase Contrast, keyboard-only, and VoiceOver UI passes;
- signed/notarized artifact verification, checksums/SBOM, complete notices, and no development override or secret in the repository/bundle.
