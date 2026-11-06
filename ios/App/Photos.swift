import SwiftUI
import PhotosUI
import ImageIO
import ProjKitCore

// Photos for projects and tasks: take one with the camera or pick one in Photos, add a note, save.
// Files are JPEGs in the project's Photos/ folder (see SPEC.md); thumbnails load off the main thread.

/// What a new photo is for, and where it comes from.
struct PhotoRequest: Identifiable, Equatable {
    enum Source { case camera, library }
    let task: Int?                 // nil: the project itself
    let source: Source
    var id: String { "\(task.map(String.init) ?? "project")-\(source)" }
}

/// A photo taken or picked, waiting for its note.
struct PendingPhoto: Identifiable {
    let id = UUID()
    let task: Int?
    let jpeg: Data
}

enum PhotoPrep {
    /// Longest edge of saved photos: plenty for viewing, and keeps iCloud usage reasonable.
    static let maxDimension: CGFloat = 2560

    /// JPEG data of image data in any format iOS reads (HEIC from Photos, PNG…), upright and scaled down.
    static func jpeg(from data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image)
        #else
        // ImageIO: decode (HEIC, PNG…), apply the orientation, scale down, encode as JPEG.
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
        #endif
    }

    #if os(iOS)
    static func jpeg(from image: UIImage) -> Data? {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))     // also applies the orientation
        }
        return drawn.jpegData(compressionQuality: 0.82)
    }
    #endif
}

// MARK: - adding: camera or Photos, then a note

extension View {
    /// Presents the camera or the Photos picker for `request`, then a note sheet; `save` gets the JPEG.
    func photoAdding(_ request: Binding<PhotoRequest?>,
                     save: @escaping (_ jpeg: Data, _ note: String, _ task: Int?) async -> Void) -> some View {
        modifier(PhotoAdding(request: request, save: save))
    }
}

private struct PhotoAdding: ViewModifier {
    @Binding var request: PhotoRequest?
    let save: (Data, String, Int?) async -> Void
    @Environment(AppModel.self) private var model
    @State private var camera = false
    @State private var library = false
    @State private var picked: PhotosPickerItem?
    @State private var task: Int?
    @State private var pending: PendingPhoto?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, r in
                guard let r else { return }
                task = r.task
                request = nil
                switch r.source {
                case .camera: camera = true
                case .library: library = true
                }
            }
            .cameraPicker(isPresented: $camera) { jpeg in pending = PendingPhoto(task: task, jpeg: jpeg) }
            .photosPicker(isPresented: $library, selection: $picked, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                let forTask = task
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let jpeg = await Task.detached(priority: .userInitiated) { data.flatMap(PhotoPrep.jpeg(from:)) }.value
                    if let jpeg {
                        pending = PendingPhoto(task: forTask, jpeg: jpeg)
                    } else {
                        model.errorMessage = "Couldn't read that photo. If it's in iCloud Photos, wait for it to download and try again."
                    }
                }
            }
            .sheet(item: $pending) { p in
                PhotoNoteSheet(jpeg: p.jpeg, title: p.task == nil ? "Add Photo" : "Add Photo to Task") { note in
                    await save(p.jpeg, note, p.task)
                }
            }
    }
}

/// The new photo with a note field.
struct PhotoNoteSheet: View {
    let jpeg: Data
    let title: String
    let save: (String) async -> Void
    @State private var note = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    #if os(iOS)
                    let decoded = UIImage(data: jpeg).map { Image(uiImage: $0) }
                    #else
                    let decoded = NSImage(data: jpeg).map { Image(nsImage: $0) }
                    #endif
                    if let image = decoded {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 360)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("The new photo")
                    }
                }
                .listRowBackground(Color.clear)
                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                } footer: {
                    Text("Shown with the photo. One line; it's saved in the project's README.")
                }
            }
            .navigationTitle(title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task { await save(note); dismiss() }
                    }
                    .disabled(saving)
                }
            }
        }
        .sheetSize(width: 480, height: 560)
        .onAppear { focused = true }
    }
}

// MARK: - showing

/// A photo thumbnail, read with file coordination (downloads it from iCloud if needed) and scaled down.
struct PhotoThumbnail: View {
    let url: URL
    var size: CGFloat = 96
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.object(forKey: url as NSURL) { image = cached.image; return }
        guard let ws = model.workspace else { failed = true; return }
        let px = size * 3
        let thumb = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? ws.fs.readData(url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: px]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        if let thumb {
            ThumbnailCache.shared.setObject(ThumbnailBox(image: thumb), forKey: url as NSURL)
            image = thumb
        } else {
            failed = true
        }
    }
}

final class ThumbnailBox: @unchecked Sendable {
    let image: CGImage
    init(image: CGImage) { self.image = image }
}

enum ThumbnailCache {
    nonisolated(unsafe) static let shared: NSCache<NSURL, ThumbnailBox> = {
        let c = NSCache<NSURL, ThumbnailBox>()
        c.countLimit = 300
        return c
    }()
}

/// A thumbnail with its note underneath (project photos grid).
struct PhotoTile: View {
    let url: URL
    let note: String
    var size: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PhotoThumbnail(url: url, size: size)
            Text(note.isEmpty ? "No note" : note)
                .font(.caption)
                .foregroundStyle(note.isEmpty ? .tertiary : .secondary)
                .lineLimit(2)
                .frame(width: size, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.isEmpty ? "Photo" : "Photo: \(note)")
        .accessibilityHint("Double-tap to view")
    }
}
