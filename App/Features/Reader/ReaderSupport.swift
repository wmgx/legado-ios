import SwiftUI
import UIKit

struct ReaderInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePopIfAvailable()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Void) {
        uiViewController.restoreInteractivePopDelegate()
    }

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var releasedDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopIfAvailable()
        }

        func enableInteractivePopIfAvailable() {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate != nil {
                previousDelegate = gesture.delegate
                gesture.delegate = nil
                releasedDelegate = true
            }
            gesture.isEnabled = true
            popGesture = gesture
        }

        func restoreInteractivePopDelegate() {
            guard releasedDelegate, let popGesture, popGesture.delegate == nil else { return }
            popGesture.delegate = previousDelegate
            previousDelegate = nil
            releasedDelegate = false
        }

    }
}

struct ReaderMenuDismissShape: Shape {
    var leadingExclusion: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: min(max(leadingExclusion, 0), rect.width),
            y: 0,
            width: max(rect.width - leadingExclusion, 0),
            height: rect.height
        ))
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}

// Shared by text reading, EPUB and every settings panel that adjusts a scalar.
struct ReadingSliderPreview {
    let id: String
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let format: (Double) -> String
}

struct ReadingSliderRow: View {
    let preview: ReadingSliderPreview
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            Text(preview.title)
                .font(.subheadline)
                .frame(minWidth: 42, alignment: .leading)
            Group {
                if let step = preview.step {
                    Slider(value: preview.value, in: preview.range, step: step, onEditingChanged: onEditingChanged)
                } else {
                    Slider(value: preview.value, in: preview.range, onEditingChanged: onEditingChanged)
                }
            }
            .accessibilityLabel(preview.id)
            .accessibilityValue(preview.format(preview.value.wrappedValue))
            Text(preview.format(preview.value.wrappedValue))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 40, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }
}

struct ReadingPreviewSlider: View {
    let title: String
    let id: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    @Binding var activeSlider: ReadingSliderPreview?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let preview = ReadingSliderPreview(id: id, title: title, value: value, range: range, step: step, format: format)
        ReadingSliderRow(preview: preview) { editing in
            if editing {
                activeSlider = preview
            } else if activeSlider?.id == id {
                activeSlider = nil
            }
            onEditingChanged(editing)
        }
        .anchorPreference(key: ReadingSliderAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

struct ReadingSliderPreviewLayer: ViewModifier {
    let preview: ReadingSliderPreview?

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ReadingSliderAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let preview, let anchor = anchors[preview.id] {
                    let rect = geometry[anchor]
                    ReadingSliderRow(preview: preview)
                        .background {
                            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial).padding(-10)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

struct ReadingPreviewPanel<Content: View>: View {
    @Binding var activeSlider: ReadingSliderPreview?
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(activeSlider == nil ? 0.18 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                content()
                    .frame(height: max(geometry.size.height * 0.55, 280))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .opacity(activeSlider == nil ? 1 : 0.001)
            }
            .modifier(ReadingSliderPreviewLayer(preview: activeSlider))
        }
    }
}

private struct ReadingSliderAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
