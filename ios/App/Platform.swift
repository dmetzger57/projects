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
#else
enum DocumentScanner {
    static var isAvailable: Bool { false }
}
#endif
