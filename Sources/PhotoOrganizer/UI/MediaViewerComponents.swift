import SwiftUI
import AppKit
import AVKit

/// Two-finger trackpad swipes arrive as `NSEvent` scroll-wheel events with
/// horizontal delta, not as a SwiftUI `DragGesture` (that only fires for
/// click-drag / single-finger touch). A local event monitor is the
/// reliable way to catch them regardless of SwiftUI view hit-testing.
@MainActor
final class TrackpadSwipeMonitor: ObservableObject {
    var onSwipeLeft: () -> Void = {}
    var onSwipeRight: () -> Void = {}

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var didTriggerThisGesture = false

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Ignore vertical scrolling and plain mouse-wheel scroll (no phase).
        guard event.phase != [] || event.momentumPhase != [] else { return }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }

        if event.phase.contains(.began) {
            accumulatedDeltaX = 0
            didTriggerThisGesture = false
        }
        accumulatedDeltaX += event.scrollingDeltaX

        guard !didTriggerThisGesture else { return }
        let threshold: CGFloat = 60
        if accumulatedDeltaX < -threshold {
            didTriggerThisGesture = true
            onSwipeLeft()
        } else if accumulatedDeltaX > threshold {
            didTriggerThisGesture = true
            onSwipeRight()
        }
    }
}

/// SwiftUI's `.onKeyPress` only fires while the exact view it's attached to
/// holds first-responder focus, which is easy to lose in a sheet with its
/// own buttons (clicking Previous/Next/Move to Trash hands focus to that
/// button, and arrow keys stop reaching the slideshow at all). A local
/// event monitor sidesteps that — same reasoning as `TrackpadSwipeMonitor`.
@MainActor
final class SlideshowKeyMonitor: ObservableObject {
    var onLeftArrow: () -> Void = {}
    var onRightArrow: () -> Void = {}
    var onDelete: () -> Void = {}

    private var monitor: Any?

    func start() {
        stop()
        print("SlideshowKeyMonitor: start() called")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            print("SlideshowKeyMonitor: keyDown keyCode=\(event.keyCode)")
            guard let self else { return event }
            switch event.keyCode {
            case 123: self.onLeftArrow(); return nil
            case 124: self.onRightArrow(); return nil
            case 51, 117: self.onDelete(); return nil
            default: return event
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

enum SlideDirection {
    case forward   // Next: new photo slides in from the right, old exits left
    case backward  // Previous: new photo slides in from the left, old exits right
}

struct FullSizePhoto: View {
    let url: URL
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            // Decodes a downsampled (not full-original-resolution) version,
            // off the main thread, through the same cache the list
            // thumbnails use — a 40MP photo decoded at full res just to
            // fit a ~1000px window is the slow part; nothing on screen
            // needs more than ~2400px on the long edge.
            nsImage = await MediaThumbnail.imageAsync(for: url, maxPixelSize: 2400)
        }
    }
}

/// Plays a video file with standard AVKit transport controls, instead of
/// trying to decode it as a still image (which silently never resolves).
struct VideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                AVPlayerContainerView(player: player)
                    .frame(minHeight: 300)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// Wraps AppKit's `AVPlayerView` directly instead of using SwiftUI's
/// `VideoPlayer` — on this toolchain, `VideoPlayer` crashes at runtime in a
/// bundle-less `swift run` executable (Swift can't resolve `AVPlayerView`'s
/// metadata via mangled-name demangling outside a proper .app bundle).
/// Going through `NSViewRepresentable` with the raw AppKit class avoids
/// whatever generic-specialization path `VideoPlayer` takes that trips it.
private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Renders a photo thumbnail, or a video-camera placeholder icon for
/// videos and any file whose thumbnail couldn't be decoded. `size`
/// defaults to a small list-row thumbnail; pass a larger value for a
/// gallery grid cell.
struct MediaThumbnailView: View {
    let url: URL?
    let kind: String
    var size: CGFloat = 40
    @State private var nsImage: NSImage?

    var body: some View {
        ZStack {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind == "video" ? "video.fill" : "photo")
                    .foregroundStyle(.secondary)
            }
            if kind == "video" {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .task(id: url) {
            guard let url else { return }
            nsImage = kind == "video"
                ? await MediaThumbnail.videoThumbnailAsync(for: url, maxPixelSize: Int(size * 2))
                : await MediaThumbnail.imageAsync(for: url, maxPixelSize: Int(size * 2))
        }
    }
}

/// Full-size, side-by-side-in-time viewer over any ordered list of
/// `MediaFile`s: prev/next through them, Move to Trash right there,
/// keyboard arrows/Delete, trackpad swipe, click-drag, slide animation.
/// Shared by the Duplicates cluster viewer and the per-source gallery.
struct MediaSlideshow: View {
    @State private var items: [MediaFile]
    @State private var index: Int
    let fileURL: (MediaFile) -> URL?
    let suggestedKeeperId: String?
    let onTrash: (MediaFile) throws -> Void
    @Binding var errorMessage: String?
    let onClose: () -> Void

    @State private var pendingTrash: MediaFile?
    @FocusState private var isFocused: Bool
    @StateObject private var swipeMonitor = TrackpadSwipeMonitor()
    @StateObject private var keyMonitor = SlideshowKeyMonitor()
    @State private var slideDirection: SlideDirection = .forward

    init(
        items: [MediaFile],
        startIndex: Int,
        fileURL: @escaping (MediaFile) -> URL?,
        suggestedKeeperId: String? = nil,
        onTrash: @escaping (MediaFile) throws -> Void,
        errorMessage: Binding<String?>,
        onClose: @escaping () -> Void
    ) {
        self._items = State(initialValue: items)
        self._index = State(initialValue: startIndex)
        self.fileURL = fileURL
        self.suggestedKeeperId = suggestedKeeperId
        self.onTrash = onTrash
        self._errorMessage = errorMessage
        self.onClose = onClose
    }

    private var current: MediaFile? {
        items.indices.contains(index) ? items[index] : nil
    }

    private func goToNext() {
        guard index < items.count - 1 else { return }
        slideDirection = .forward
        withAnimation(.easeInOut(duration: 0.22)) {
            index += 1
        }
    }

    private func goToPrevious() {
        guard index > 0 else { return }
        slideDirection = .backward
        withAnimation(.easeInOut(duration: 0.22)) {
            index -= 1
        }
    }

    private func trashCurrent() {
        guard let current else { return }
        pendingTrash = current
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Close") { onClose() }
                Spacer()
                if !items.isEmpty {
                    Text("\(index + 1) of \(items.count)")
                        .foregroundStyle(.secondary)
                }
            }

            if let current, let url = fileURL(current) {
                Group {
                    if current.kind == "video" {
                        VideoPreview(url: url)
                    } else {
                        FullSizePhoto(url: url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(current.id)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: slideDirection == .forward ? .trailing : .leading),
                        removal: .move(edge: slideDirection == .forward ? .leading : .trailing)
                    )
                    .combined(with: .opacity)
                )
                .clipped()
                .gesture(
                    // Click-drag fallback (mouse or single-finger touch).
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.width < -40 {
                                goToNext()
                            } else if value.translation.width > 40 {
                                goToPrevious()
                            }
                        }
                )

                HStack {
                    Text(current.relativePath)
                    if let sizeText = Self.formattedSize(current.fileSizeBytes) {
                        Text(sizeText)
                    }
                    if let width = current.width, let height = current.height {
                        Text("\(width)×\(height)")
                    }
                    if current.id == suggestedKeeperId {
                        Text("Suggested keeper").font(.caption).foregroundStyle(.green)
                    }
                }
                .foregroundStyle(.secondary)

                HStack {
                    Button("◀ Previous") { goToPrevious() }
                        .disabled(index == 0)
                    Spacer()
                    Button("Move to Trash", role: .destructive) { trashCurrent() }
                    Spacer()
                    Button("Next ▶") { goToNext() }
                        .disabled(index >= items.count - 1)
                }
            } else {
                Text("No files left.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 700, idealHeight: 800)
        .padding()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .task {
            isFocused = true
            swipeMonitor.onSwipeLeft = { goToNext() }
            swipeMonitor.onSwipeRight = { goToPrevious() }
            swipeMonitor.start()
            keyMonitor.onLeftArrow = { goToPrevious() }
            keyMonitor.onRightArrow = { goToNext() }
            keyMonitor.onDelete = { trashCurrent() }
            keyMonitor.start()
        }
        .onDisappear {
            swipeMonitor.stop()
            keyMonitor.stop()
        }
        .confirmationDialog(
            "Move this file to Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { file in
            Button("Move to Trash", role: .destructive) {
                do {
                    try onTrash(file)
                    items.removeAll { $0.id == file.id }
                    if index >= items.count { index = max(0, items.count - 1) }
                    if items.isEmpty { onClose() }
                } catch {
                    errorMessage = error.localizedDescription
                }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { file in
            Text("\(file.relativePath) will be moved to the Trash. This can be undone from the Trash until it's emptied.")
        }
    }

    static func formattedSize(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
