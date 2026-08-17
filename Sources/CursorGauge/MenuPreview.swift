import AppKit
import SwiftUI

/// `CursorGauge --emit-menu-preview <file.png>` draws the menu's action rows in each state.
///
/// Same reason as `PreviewRenderer`: the menu bar dropdown cannot be screenshotted from a
/// terminal, so without this the only evidence for a busy state is that it compiled. It
/// exists to catch the row growing taller when the spinner appears, which would shift the
/// menu under the cursor mid-click.
enum MenuPreview {
    /// `ImageRenderer` is main-actor isolated. This runs before the app starts, on the main
    /// thread, so asserting that is accurate rather than a workaround.
    @MainActor
    static func run(path: String) -> Never {
        let rows = VStack(alignment: .leading, spacing: 2) {
            Text("IDLE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            MenuButton(title: "Refresh Now", key: "r") {}
            MenuButton(title: "Usage Report…", key: "e") {}
            MenuButton(title: "Settings…", key: ",") {}

            Text("BUILDING").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 8)
            MenuButton(title: "Refresh Now", key: "r") {}
            MenuButton(title: "Building report…", key: "e", busy: true) {}
            MenuButton(title: "Settings…", key: ",") {}

            Text("DISABLED (for contrast)").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary).padding(.top, 8)
            MenuButton(title: "Refresh Now", key: "r", disabled: true) {}
        }
        .padding(12)
        .frame(width: 268, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))

        // Drawn through a real window rather than `ImageRenderer`, deliberately.
        // `ImageRenderer` snapshots SwiftUI's own rendering and cannot capture an
        // AppKit-backed animating view, so it drew the spinner as a "prohibited" placeholder
        // — which looks exactly like a broken control and proves nothing either way. Going
        // through `cacheDisplay` exercises the drawing path the app actually uses.
        let hosting = NSHostingView(rootView: rows)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        // One turn of the run loop, so the spinner starts and has something to draw.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("error: could not allocate bitmap\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("error: could not render\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("menu preview written to \(path)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
