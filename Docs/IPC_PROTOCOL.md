# K9k core protocol v1

`K9k.app` starts `Contents/Resources/k9k-core` as its child process. The app communicates on stdin/stdout with one UTF-8 JSON object per line. Stderr is reserved for diagnostics and never parsed as protocol data.

Every request and envelope has `version: 1`. Requests contain a caller-generated `id`, operation name, optional `streamID`, and structured parameters. Responses echo `id`; asynchronous events echo `streamID`. Errors use a stable `code`, human-readable `message`, and optional structured details.

Implemented v1 operations are `health.ping`, `context.list`, `context.select`, `namespace.list`, `discovery.list`, `resource.list`, `resource.get`, `resource.watch`, `stream.cancel`, `resource.patch`, `resource.scale`, and `resource.delete`. Generic resource operations carry group/version/resource plus explicit scope, namespace, name, selector, and raw Kubernetes object information. Watches emit incremental `resource.added`, `resource.modified`, `resource.deleted`, and `stream.closed` events.

The helper owns client-go's kubeconfig merge/auth behavior and Kubernetes network I/O. Swift owns process supervision, request correlation, main-actor state, and presentation. Closing the app terminates the child; changing context or resource scope cancels the preceding watch.

