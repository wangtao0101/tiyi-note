#if !targetEnvironment(macCatalyst)
import AVFoundation
import UIKit
import Combine
import Vision

struct DocumentScanTracker {
    private(set) var selection: DocumentScanSelection?
    private(set) var stableFrames = 0
    private var lastDetectedAt: TimeInterval = 0
    var isStable: Bool { stableFrames >= 3 }

    mutating func update(_ crop: DocumentScanCrop?, imageSize: CGSize, at time: TimeInterval) {
        guard let crop, crop.isValid else {
            if time - lastDetectedAt > 0.4 { reset() }
            return
        }
        if let previous = selection, previous.imageSize == imageSize,
           zip(previous.crop.points, crop.points).allSatisfy({ hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < 0.025 }) {
            stableFrames += 1
        } else { stableFrames = 1 }
        // Show the actual detection coordinates. Animating/averaging them would make the visible
        // boundary differ from the selection frozen when the shutter is pressed.
        selection = DocumentScanSelection(crop: crop, imageSize: imageSize)
        lastDetectedAt = time
    }
    func freshSelection(at time: TimeInterval) -> DocumentScanSelection? {
        time - lastDetectedAt <= 0.4 ? selection : nil
    }
    mutating func reset() { selection = nil; stableFrames = 0; lastDetectedAt = 0 }
}

struct DocumentScanCapture: Sendable {
    var data: Data
    var selection: DocumentScanSelection?
}

/// UI properties/continuations are accessed on main; session configuration and mutable camera
/// settings are confined to the serial queue. AVFoundation owns photo delegate callbacks.
final class DocumentScanCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published private(set) var isReady = false
    @Published private(set) var isDenied = false
    @Published private(set) var isUnavailable = false
    @Published private(set) var liveSelection: DocumentScanSelection?
    @Published private(set) var isBoundaryStable = false
    @Published var errorMessage: String?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "tiyi.document-scan.camera")
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "tiyi.document-scan.edges", qos: .userInitiated)
    private var lastAnalysisAt: TimeInterval = 0 // confined to analysisQueue
    private var configured = false
    private var wantsRunning = false // confined to queue
    private var rotationAngle: CGFloat = 90 // confined to queue
    private var completion: CheckedContinuation<DocumentScanCapture, Error>?
    private var shutterSelection: DocumentScanSelection?
    private var tracker = DocumentScanTracker() // main thread
    private var acceptsFrames = false // main thread
    private var previewAngle: CGFloat = 90 // main thread
    private var boundaryRevision = UUID() // main thread
    private var interruptionObserver: NSObjectProtocol?
    private var interruptionBeganObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                self.configureAndStart()
            }
        }
        interruptionBeganObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.isReady = false
            self?.resetBoundary()
        }
    }
    deinit {
        for observer in [interruptionObserver, interruptionBeganObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        acceptsFrames = true
        queue.async { self.wantsRunning = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.wantsRunning = true; self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.queue.async { self.configureAndStart() } }
                else { DispatchQueue.main.async { self.isDenied = true; self.isReady = false } }
            }
        case .denied, .restricted: isDenied = true; isReady = false
        @unknown default: isDenied = true; isReady = false
        }
    }

    func stop() {
        acceptsFrames = false
        resetBoundary()
        isReady = false
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isReady = false }
        }
    }

    func setRotation(_ angle: CGFloat) {
        guard previewAngle != angle else { return }
        previewAngle = angle
        resetBoundary()
        queue.async {
            self.rotationAngle = angle
            self.configureVideoConnection()
        }
    }

    @MainActor func capture() async throws -> DocumentScanCapture {
        guard isReady, completion == nil else { throw CameraError.unavailable }
        shutterSelection = tracker.freshSelection(at: CACurrentMediaTime())
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            queue.async {
                guard self.session.isRunning, !self.session.isInterrupted else {
                    DispatchQueue.main.async { self.finish(.failure(CameraError.unavailable)) }
                    return
                }
                if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(self.rotationAngle) {
                    connection.videoRotationAngle = self.rotationAngle
                }
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configureAndStart() {
        guard wantsRunning else { return }
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input), session.canAddOutput(output), session.canAddOutput(videoOutput) else { throw CameraError.unavailable }
                session.addInput(input)
                session.addOutput(output)
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.automaticallyConfiguresOutputBufferDimensions = false
                videoOutput.deliversPreviewSizedOutputBuffers = true
                videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
                session.addOutput(videoOutput)
                configureVideoConnection()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self.isReady = true; self.isDenied = false; self.isUnavailable = false; self.errorMessage = nil }
        } catch {
            DispatchQueue.main.async { self.isReady = false; self.isUnavailable = true; self.errorMessage = error.localizedDescription }
        }
    }

    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle = rotationAngle }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisAt >= 0.12, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysisAt = now
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let angle = connection.videoRotationAngle
        let crop: DocumentScanCrop? = autoreleasepool {
            let request = VNDetectDocumentSegmentationRequest()
            guard (try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])) != nil,
                  let observation = request.results?.first, observation.confidence >= 0.5 else { return nil }
            func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: 1 - point.y) }
            return DocumentScanCrop(topLeft: flip(observation.topLeft), topRight: flip(observation.topRight),
                bottomRight: flip(observation.bottomRight), bottomLeft: flip(observation.bottomLeft))
        }
        DispatchQueue.main.async {
            guard self.acceptsFrames, self.isReady, self.completion == nil,
                  angle == self.previewAngle else { return }
            guard CACurrentMediaTime() - now <= 0.4 else { self.resetBoundary(); return }
            self.tracker.update(crop, imageSize: size, at: now)
            self.liveSelection = self.tracker.freshSelection(at: CACurrentMediaTime())
            self.isBoundaryStable = self.tracker.isStable
            self.boundaryRevision = UUID()
            let revision = self.boundaryRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.41) { [weak self] in
                guard let self, self.boundaryRevision == revision, self.completion == nil,
                      self.tracker.freshSelection(at: CACurrentMediaTime()) == nil else { return }
                self.resetBoundary()
            }
        }
    }
    private func resetBoundary() {
        tracker.reset()
        boundaryRevision = UUID()
        liveSelection = nil
        isBoundaryStable = false
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<Data, Error>
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data) }
        else { result = .failure(DocumentScanError.invalidImage) }
        DispatchQueue.main.async { self.finish(result) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { DispatchQueue.main.async { self.finish(.failure(error)) } }
    }
    private func finish(_ result: Result<Data, Error>) {
        let continuation = completion
        completion = nil
        let selection = shutterSelection
        shutterSelection = nil
        continuation?.resume(with: result.map { DocumentScanCapture(data: $0, selection: selection) })
    }
    private enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "相机暂不可用，可从相册添加图片，或稍后重试。" }
    }
}

final class DocumentScanPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onRotation: ((CGFloat) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        let angle: CGFloat
        switch window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        onRotation?(angle)
    }
}
#endif
