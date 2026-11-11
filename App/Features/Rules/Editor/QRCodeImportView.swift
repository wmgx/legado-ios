import SwiftUI
import AVFoundation
import Vision
import VisionKit

struct QRCodeImportView: View {
    @Environment(\.dismiss) private var dismiss
    var subject = "书源或净化规则"
    let onValue: (String) -> Void
    @State private var cameraAuthorized = false
    @State private var cameraMessage = "正在检查相机…"
    @State private var values: [String] = []
    @State private var errorMessage: String?
    @State private var isReading = false
    @State private var scanError: String?
    @State private var delivered = false

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 16) {
                if cameraAuthorized, scanError == nil {
                    cameraScanner
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .bottom) {
                            Text("将\(subject)二维码放入取景框").font(.footnote)
                                .padding(10).background(.ultraThinMaterial, in: Capsule()).padding()
                        }
                } else {
                    ReadingUnavailableView("相机扫描暂不可用", systemImage: "qrcode.viewfinder",
                        description: Text(scanError ?? cameraMessage))
                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                        Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
                if isReading { ProgressView("识别图片中的二维码…") }
                ReadingPhotoPicker { data in
                    readPhoto(data)
                } onError: { error in
                    errorMessage = error.localizedDescription
                } label: {
                    Label("从照片选择二维码", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }.readingProminentButtonStyle().disabled(isReading)
                Text("支持 HTTP(S) 链接、Legado 导入深链和 JSON 内容。识别后进入导入流程。")
                    .font(.footnote).foregroundStyle(.secondary)
                if values.count > 1 {
                    List(values, id: \.self) { value in
                        Button { accept(value) } label: { Text(value).font(.caption).lineLimit(3) }
                    }.frame(maxHeight: 220)
                }
            }
            .padding()
            .navigationTitle("二维码导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: cameraAuthorized = true
                case .notDetermined: cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
                default: break
                }
                cameraMessage = cameraAuthorized ? "当前设备不支持实时扫描，请从照片选择二维码。" : "未获得相机权限，仍可从照片选择二维码。"
            }
            .alert("识别失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private var cameraScanner: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI,
           DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            QRScanner { accept($0) } onError: { scanError = $0 }
        } else {
            LegacyQRScanner { accept($0) } onError: { scanError = $0 }
        }
    }

    private func readPhoto(_ data: Data) {
        Task {
            isReading = true
            defer { isReading = false }
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try QRCodeDecoder().detect(in: data)
                }.value
                values = found
                if found.count == 1 { accept(found[0]) }
                else if found.isEmpty { errorMessage = "图片中没有识别到二维码，请选择清晰的原图。" }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func accept(_ value: String) {
        guard !delivered else { return }
        delivered = true
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            onValue(value)
        }
    }
}

@available(iOS 16.0, *)
private struct QRScanner: UIViewControllerRepresentable {
    let onValue: (String) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onValue: onValue) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        do { try scanner.startScanning() }
        catch { Task { @MainActor in onError(error.localizedDescription) } }
    }
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onValue: (String) -> Void
        init(onValue: @escaping (String) -> Void) { self.onValue = onValue }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    dataScanner.stopScanning()
                    onValue(value)
                    return
                }
            }
        }
    }
}

private struct LegacyQRScanner: UIViewControllerRepresentable {
    let onValue: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onValue: onValue, onError: onError)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.capture.stop()
    }

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        let capture = VideoCapture()
        let onValue: (String) -> Void
        let onError: (String) -> Void
        private var preview: AVCaptureVideoPreviewLayer?
        private var didDeliver = false

        init(onValue: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onValue = onValue
            self.onError = onError
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            do {
                guard let device = AVCaptureDevice.default(for: .video) else { throw AVError(.deviceNotConnected) }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                capture.session.beginConfiguration()
                defer { capture.session.commitConfiguration() }
                guard capture.session.canAddInput(input), capture.session.canAddOutput(output) else {
                    throw AVError(.deviceInUseByAnotherApplication)
                }
                capture.session.addInput(input)
                capture.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                let preview = AVCaptureVideoPreviewLayer(session: capture.session)
                preview.videoGravity = .resizeAspectFill
                view.layer.addSublayer(preview)
                self.preview = preview
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.onError(message) }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if preview != nil { capture.start() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            capture.stop()
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            Task { @MainActor [weak self] in
                guard let self, !didDeliver else { return }
                didDeliver = true
                capture.stop()
                onValue(value)
            }
        }
    }

    final class VideoCapture: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "com.epiboly.legado.qr-camera")
        func start() { queue.async { self.session.startRunning() } }
        func stop() { queue.async { self.session.stopRunning() } }
    }
}
