+++
title = "Getting started"
weight = 10
+++

K9k is a macOS Tahoe 26+ Kubernetes manager built with SwiftUI and a bundled Go `client-go` helper. It talks directly to the active kubeconfig context. There is no Electron shell, webview, or embedded TUI, and `kubectl` is not required for normal cluster operations.

## Install

There is no packaged release yet: no signed or notarized build, no Homebrew cask, and no GitHub release. Today K9k is built from source. A Developer ID signed release is tracked in the repository's backlog.

## Requirements

- macOS Tahoe 26+
- Xcode 26+
- [mise](https://mise.jdx.dev/)

## Build and run

```sh
git clone https://github.com/alliecatowo/k9k
cd k9k
mise trust
mise install
mise run bootstrap
mise run build
mise run test
mise run run
```

The Debug app is built at `DerivedData/Build/Products/Debug/K9k.app`. `mise run build` compiles and bundles `k9k-core` into the app.

## Try it on a disposable cluster

```sh
mise run cluster:create
mise run cluster:seed
mise run run
```

These tasks use the disposable `kind-k9k-test` context. Switch back to your production context before opening K9k against a real environment.
