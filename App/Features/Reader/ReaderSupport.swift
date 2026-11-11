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
    var displayValue: Double

    init(id: String, title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double?, format: @escaping (Double) -> String) {
        self.id = id
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        displayValue = value.wrappedValue
    }
}

struct ReadingSearchExitButton: View {
    @Environment(\.dismissSearch) private var dismissSearch
    let action: () -> Void

    var body: some View {
        Button("定位当前章节", systemImage: "location") {
            dismissSearch()
            action()
        }
    }
}

struct ReadingSliderRow: View {
    let preview: ReadingSliderPreview
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onValueChanged: (Double) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            Text(preview.title)
                .font(.subheadline)
                .frame(minWidth: 42, alignment: .leading)
            ReadingSliderControl(preview: preview, onEditingChanged: onEditingChanged, onValueChanged: onValueChanged)
                .frame(maxWidth: .infinity, minHeight: 44)
            Text(preview.format(preview.displayValue))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 40, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }
}

private struct ReadingSliderControl: UIViewRepresentable {
    let preview: ReadingSliderPreview
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.change(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(preview.range.lowerBound)
        slider.maximumValue = Float(preview.range.upperBound)
        if !slider.isTracking { slider.value = Float(preview.displayValue) }
        slider.accessibilityIdentifier = preview.id
        slider.accessibilityLabel = preview.id
        slider.accessibilityValue = preview.format(preview.displayValue)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ReadingSliderControl
        private var editing = false

        init(parent: ReadingSliderControl) { self.parent = parent }

        @objc func begin(_ slider: UISlider) {
            guard !editing else { return }
            editing = true
            parent.onEditingChanged(true)
        }

        @objc func change(_ slider: UISlider) {
            let preview = parent.preview
            var value = Double(slider.value)
            if let step = preview.step, step > 0 {
                value = preview.range.lowerBound + ((value - preview.range.lowerBound) / step).rounded() * step
            }
            value = min(max(value, preview.range.lowerBound), preview.range.upperBound)
            preview.value.wrappedValue = value
            slider.value = Float(value)
            slider.accessibilityValue = preview.format(value)
            parent.onValueChanged(value)
        }

        @objc func end(_ slider: UISlider) {
            change(slider)
            guard editing else { return }
            editing = false
            parent.onEditingChanged(false)
        }
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
        ReadingSliderRow(preview: preview, onEditingChanged: { editing in
            if editing {
                activeSlider = preview
            } else if activeSlider?.id == id {
                activeSlider = nil
            }
            onEditingChanged(editing)
        }, onValueChanged: { newValue in
            guard var active = activeSlider, active.id == id else { return }
            active.displayValue = newValue
            activeSlider = active
        })
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
                            RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)).padding(-10)
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
    var expanded = false
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = max(geometry.size.height * (expanded ? 0.82 : 0.55), 280)
            ZStack(alignment: .bottom) {
                Color.black.opacity(activeSlider == nil ? 0.18 : 0)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)
                    Color.clear.frame(height: panelHeight).allowsHitTesting(false)
                }
                content()
                    .frame(height: panelHeight)
                    .clipShape(ReadingPanelOutline())
                    .overlay { ReadingPanelOutline().stroke(ReadingTheme.separator, lineWidth: 1).allowsHitTesting(false) }
                    .background(alignment: .top) {
                        ReadingPanelOutline()
                            .fill(ReadingTheme.canvas)
                            .padding(.bottom, -geometry.safeAreaInsets.bottom)
                    }
                    // UIKit stops hit testing below 0.01, which can cancel the
                    // slider before it delivers its end-of-drag callback.
                    .opacity(activeSlider == nil ? 1 : 0.02)
            }
            .modifier(ReadingSliderPreviewLayer(preview: activeSlider))
        }
    }
}

private struct ReadingPanelOutline: Shape {
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: 20, height: 20)).cgPath)
    }
}

private struct ReadingSliderAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderTapZoneEditor: View {
    @Binding var x1: Double
    @Binding var x2: Double
    @Binding var y1: Double
    @Binding var y2: Double
    let actions: [Int]
    let choices: [(Int, String)]
    let actionBinding: (Int) -> Binding<Int>
    let done: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ForEach(0..<9, id: \.self) { index in region(index, size: geometry.size) }
                verticalDivider($x1, minimum: 0.12, maximum: x2 - 0.12, size: geometry.size, label: "左侧分界线")
                verticalDivider($x2, minimum: x1 + 0.12, maximum: 0.88, size: geometry.size, label: "右侧分界线")
                horizontalDivider($y1, minimum: 0.12, maximum: y2 - 0.12, size: geometry.size, label: "上方分界线")
                horizontalDivider($y2, minimum: y1 + 0.12, maximum: min(0.88, 1 - 60 / Double(max(geometry.size.height, 1))), size: geometry.size, label: "下方分界线")
                VStack {
                    Text("拖动分界线调整大小，点击区块设置动作")
                        .font(.caption).padding(8).background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
                    Spacer()
                    HStack {
                        Button("恢复等分") { x1 = 1.0 / 3; x2 = 2.0 / 3; y1 = 1.0 / 3; y2 = 2.0 / 3 }
                        Spacer()
                        Button("完成", action: done).font(.body.weight(.semibold))
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }.padding(8)
            }
            .coordinateSpace(name: "reader-tap-zones")
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("reader.tapZoneEditor")
    }

    private func region(_ index: Int, size: CGSize) -> some View {
        let xs = [0, x1, x2, 1], ys = [0, y1, y2, 1]
        let column = index % 3, row = index / 3
        let width = size.width * (xs[column + 1] - xs[column])
        let height = size.height * (ys[row + 1] - ys[row])
        let title = ["左上", "上中", "右上", "左中", "中央", "右中", "左下", "下中", "右下"][index]
        let action = index == 4 ? "菜单（固定）" : choices.first(where: { $0.0 == actions[index] })?.1 ?? "无动作"
        return Menu {
            Picker("\(title)动作", selection: actionBinding(index)) {
                ForEach(choices, id: \.0) { choice in Text(choice.1).tag(choice.0) }
            }
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.caption)
                Text(action).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(width: max(width, 1), height: max(height, 1))
            .background(Color.blue.opacity(index == 4 ? 0.14 : 0.08))
            .overlay { Rectangle().strokeBorder(Color.blue.opacity(0.5), lineWidth: 0.5) }
        }
        .buttonStyle(.plain).disabled(index == 4)
        .position(x: size.width * xs[column] + width / 2, y: size.height * ys[row] + height / 2)
        .accessibilityLabel("\(title)：\(action)")
    }

    private func verticalDivider(_ value: Binding<Double>, minimum: Double, maximum: Double, size: CGSize, label: String) -> some View {
        ZStack {
            Rectangle().fill(Color.blue.opacity(0.8)).frame(width: 2)
            Image(systemName: "arrow.left.and.right").font(.caption.bold()).padding(8).background(.regularMaterial, in: Capsule())
        }
        .frame(width: 28, height: size.height).contentShape(Rectangle())
        .position(x: size.width * value.wrappedValue, y: size.height / 2)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("reader-tap-zones")).onChanged {
            value.wrappedValue = min(max(Double($0.location.x / max(size.width, 1)), minimum), maximum)
        })
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            value.wrappedValue = min(max(value.wrappedValue + (direction == .increment ? 0.02 : -0.02), minimum), maximum)
        }
    }

    private func horizontalDivider(_ value: Binding<Double>, minimum: Double, maximum: Double, size: CGSize, label: String) -> some View {
        ZStack {
            Rectangle().fill(Color.blue.opacity(0.8)).frame(height: 2)
            Image(systemName: "arrow.up.and.down").font(.caption.bold()).padding(8).background(.regularMaterial, in: Capsule())
        }
        .frame(width: size.width, height: 28).contentShape(Rectangle())
        .position(x: size.width / 2, y: size.height * value.wrappedValue)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("reader-tap-zones")).onChanged {
            value.wrappedValue = min(max(Double($0.location.y / max(size.height, 1)), minimum), maximum)
        })
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            value.wrappedValue = min(max(value.wrappedValue + (direction == .increment ? 0.02 : -0.02), minimum), maximum)
        }
    }
}
