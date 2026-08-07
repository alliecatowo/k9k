# Apple Liquid Glass sample provenance

- **Sample:** Landmarks: Building an app with Liquid Glass
- **Apple documentation:** <https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass>
- **Retrieved:** 2026-08-06 (America/Los_Angeles)
- **Original archive:** `LandmarksBuildingAnAppWithLiquidGlass.zip`
- **Apple-hosted source:** <https://docs-assets.developer.apple.com/published/a88428e6793e/LandmarksBuildingAnAppWithLiquidGlass.zip>
- **SHA-256:** `f19ed0effbe8af975536034b2b5af98002f06f5d600854a95efb62ccc8303f41`
- **Sample Git revision:** `d4acf4ada7727b7374b6e67529863340d438bedc` (2026-06-12)
- **Original project/scheme:** `Landmarks/Landmarks.xcodeproj`, `Landmarks`
- **Original target:** Universal SwiftUI Landmarks application (iOS, iPadOS, macOS)

The original archive and extracted tree are retained locally under `.vendor/apple/` and excluded from Git because the archive is 320 MB. `APPLE_SAMPLE_LICENSE.txt` preserves the sample license distributed in the archive.

## Transformation into K9k

K9k began from the extracted `Landmarks.xcodeproj` itself, renamed to `K9k.xcodeproj`, not from an independently generated project. Its filesystem-synchronized target organization, macOS 26 build settings, SwiftUI app lifecycle, toolbar/navigation conventions, and project configuration descended directly from the Apple sample.

Removed sample material is retained locally in `.vendor/apple/removed-landmarks/` for auditability: travel models, maps, badges, artwork, localizable demo data, iPhone/iPad support, and tutorial-only views. K9k is macOS-only (`MACOSX_DEPLOYMENT_TARGET = 26.0`) with portable signing and no developer team identifier. Its application target now contains Kubernetes-specific app, models, services, IPC, features, assets, and an un-sandboxed entitlement file appropriate for direct kubeconfig access and a bundled helper.

