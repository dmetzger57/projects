import SwiftUI

// iOS-only APIs live here so the rest of the app also compiles for macOS
// (used to type-check the app on a Mac without full Xcode).

extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func decimalField() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    func urlField() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// Presents the VisionKit document camera; delivers the scan as a PDF.
    func documentScanner(isPresented: Binding<Bool>, onScan: @escaping (Data) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            DocumentScannerView(onScan: { data in
                isPresented.wrappedValue = false
                onScan(data)
            }, onCancel: { isPresented.wrappedValue = false })
            .ignoresSafeArea()
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Presents the camera for a photo; delivers it as JPEG data (upright, scaled down).
    func cameraPicker(isPresented: Binding<Bool>, onPhoto: @escaping (Data) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            CameraPickerView(onImage: { image in
                isPresented.wrappedValue = false
                if let jpeg = PhotoPrep.jpeg(from: image) { onPhoto(jpeg) }
            }, onCancel: { isPresented.wrappedValue = false })
            .ignoresSafeArea()
        }
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Leading end of the toolbar (top-left on iPhone/iPad, navigation area on the Mac).
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}

extension Color {
    #if os(iOS)
    static var groupedBackground: Color { Color(.systemGroupedBackground) }
    static var secondaryGroupedBackground: Color { Color(.secondarySystemGroupedBackground) }
    #else
    static var groupedBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var secondaryGroupedBackground: Color { Color(nsColor: .controlBackgroundColor) }
    #endif
}

extension View {
    /// Lists that are always reorderable (iOS needs edit mode for drag handles; the Mac drags anyway).
    func alwaysEditing() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }

    /// Mac sheets size themselves to their content, and a List or Form has none: give them a real size.
    func sheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    func liftOnHover() -> some View {
        #if os(iOS)
        hoverEffect(.lift)
        #else
        self
        #endif
    }
}

func copyToClipboard(_ s: String) {
    #if os(iOS)
    UIPasteboard.general.string = s
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #endif
}

#if os(iOS)
import UIKit
import VisionKit

@MainActor
enum DocumentScanner {
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (Data) -> Void
        let onCancel: () -> Void
        init(onScan: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan(Self.pdf(from: scan))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onCancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onCancel() }

        /// One page per scanned image, US Letter width, JPEG-compressed to keep receipts small.
        static func pdf(from scan: VNDocumentCameraScan) -> Data {
            let pageWidth: CGFloat = 612
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            let first = pages.first?.size ?? CGSize(width: 612, height: 792)
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth,
                                                                height: pageWidth * first.height / max(first.width, 1)))
            return renderer.pdfData { ctx in
                for image in pages {
                    let h = pageWidth * image.size.height / max(image.size.width, 1)
                    let rect = CGRect(x: 0, y: 0, width: pageWidth, height: h)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    let jpeg = image.jpegData(compressionQuality: 0.6).flatMap(UIImage.init(data:)) ?? image
                    jpeg.draw(in: rect)
                }
            }
        }
    }
}

@MainActor
enum Camera {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}

struct CameraPickerView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void
        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) } else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}
#else
enum DocumentScanner {
    static var isAvailable: Bool { false }
}

enum Camera {
    static var isAvailable: Bool { false }
}
#endif
