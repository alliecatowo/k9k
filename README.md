# K9k

K9k is a native macOS 26 Kubernetes cluster manager: K9s-style Kubernetes capability with an Apple Liquid Glass SwiftUI interface. The macOS app is backed by a bundled Go `client-go` helper, so normal resource operations do not require an installed `kubectl` or K9s.

## Requirements

- macOS Tahoe 26+
- Xcode 26.0+ (Apple-managed; checked by bootstrap)
- [mise](https://mise.jdx.dev/)

## Development

```sh
mise install
mise run bootstrap
mise run build
mise run test
mise run run
```

`mise run build` compiles `k9k-core`, builds `K9k.app`, then bundles the helper at `K9k.app/Contents/Resources/k9k-core`. The developer-facing app is at `DerivedData/Build/Products/Debug/K9k.app`.

For an isolated test cluster, use `mise run cluster:create`, `mise run cluster:seed`, and `mise run cluster:destroy`. These tasks target the disposable `k9k-test` Kind cluster. Kind makes `kind-k9k-test` the current kubeconfig context when it creates the cluster, so switch back to a production context before opening K9k against it.

## Current vertical slice

K9k currently provides direct kubeconfig/context handling, namespace selection, API discovery (including CRDs), generic dynamic resource list/get/watch, native sorting/filtering/table selection, resource metadata/raw-object/event inspection, streamed pod logs, command-palette resource navigation, destructive confirmation, and global read-only mode. The protocol foundation also supports generic patch/scale/delete operations and parses K9s aliases, hotkeys, views, and plugin declarations for migration work. See `Docs/K9S_PARITY.md` for candid parity status and `Docs/ARCHITECTURE.md` for design details.
