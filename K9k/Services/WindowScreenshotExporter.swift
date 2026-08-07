import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the actual K9k window through WindowServer rather than rendering a
/// second SwiftUI view. This keeps exports faithful to the current window
/// size, sidebar/inspector state, selection, accessibility settings, and the
/// system appearance chosen by the user.
@MainActor
enum WindowScreenshotExporter {
    enum CaptureError: LocalizedError {
        case noApplicationWindow
        case captureFailed
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .noApplicationWindow:
                "K9k could not find an application window to capture."
            case .captureFailed:
                "macOS could not capture the K9k window."
            case .pngEncodingFailed:
                "K9k could not encode the screenshot as a PNG."
            }
        }
    }

    static func saveCurrentWindow(named defaultName: String = "k9k-window.png") async throws {
        // Capture before the save panel becomes the key window. The WindowServer
        // image includes the real app content and native chrome, unlike a
        // separate off-screen renderer or a synthetic SwiftUI snapshot.
        let png = try await captureCurrentWindowPNG()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try png.write(to: url, options: .atomic)
    }

    static func captureCurrentWindowPNG() async throws -> Data {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            throw CaptureError.noApplicationWindow
        }

        let windowID = CGWindowID(window.windowNumber)
        let content = try await SCShareableContent.currentProcess
        guard let shareableWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.captureFailed
        }

        let scale = max(window.backingScaleFactor, 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((shareableWindow.frame.width * scale).rounded()))
        configuration.height = max(1, Int((shareableWindow.frame.height * scale).rounded()))
        configuration.scalesToFit = false
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }
        return png
    }
}
