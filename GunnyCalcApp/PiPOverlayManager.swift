import AVFoundation
import AVKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Network
import SwiftUI
import UIKit

/// Container UIView sử dụng `AVSampleBufferDisplayLayer` làm lớp nền cho Picture-in-Picture.
final class PiPSampleBufferView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}

/// Bridge SwiftUI gắn `PiPSampleBufferView` vào hệ thống phân cấp UIKit để `AVPictureInPictureController` hoạt động ổn định.
struct PiPHostView: UIViewRepresentable {
    @ObservedObject var manager: PiPOverlayManager

    func makeUIView(context: Context) -> PiPSampleBufferView {
        let view = manager.sampleBufferView
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PiPSampleBufferView, context: Context) {
        manager.configureIfNeeded()
    }
}

/// Bộ lắng nghe UDP IPv4 (`0.0.0.0:45678`) độc lập khỏi `@MainActor` để chạy trên hàng đợi riêng không xung đột actor isolation.
private final class UDPTelemetryReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gunny.pipcalc.app.udp.listener", qos: .userInteractive)
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var onTelemetry: (@Sendable (TelemetryData) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    func start(
        port: UInt16,
        onTelemetry: @escaping @Sendable (TelemetryData) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        self.onTelemetry = onTelemetry
        self.onError = onError
        lock.unlock()

        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }

            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            if let nwPort = NWEndpoint.Port(rawValue: port) {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host("0.0.0.0"),
                    port: nwPort
                )
            }

            do {
                let newListener = try NWListener(using: parameters)
                newListener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        self?.listener = nil
                    }
                }
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.acceptConnection(connection)
                }
                newListener.start(queue: self.queue)
                self.listener = newListener
            } catch {
                self.lock.lock()
                let errorCallback = self.onError
                self.lock.unlock()
                errorCallback?("Lỗi mở cổng UDP \(port): \(error.localizedDescription)")
            }
        }
    }

    private func acceptConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        if activeConnections.count > 12 {
            let stale = activeConnections.removeFirst()
            stale.cancel()
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveNextMessage(on: connection)
            case .failed, .cancelled:
                self.activeConnections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let telemetry = try? JSONDecoder().decode(TelemetryData.self, from: data) {
                self.lock.lock()
                let callback = self.onTelemetry
                self.lock.unlock()
                callback?(telemetry)
            }
            if error == nil, let connection {
                self.receiveNextMessage(on: connection)
            }
        }
    }
}

/// Quản lý cửa sổ nổi Picture-in-Picture (`640 x 210`) mô phỏng đường ngắm 2 tia kiểu tool Gunny PC,
/// lắng nghe UDP IPv4 `0.0.0.0:45678` qua `NWListener` và duy trì chạy nền bằng âm thanh câm lặp vô hạn.
@MainActor
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var statusMessage: String?

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 640, height: 210))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .placeholder
    private var lastPacketReceivedAt: TimeInterval = 0
    private var keepAliveTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?
    private let udpReceiver = UDPTelemetryReceiver()

    private let renderSize = CGSize(width: 640, height: 210)
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let ballisticsEngine = BallisticsEngine()
    private let defaultFallbackPower: Double = 45.0
    private let liveTimeoutSeconds: TimeInterval = 1.5

    private override init() {
        super.init()
        configureAudioSessionAndSilentLoop()
    }

    func configureIfNeeded() {
        startSilentAudioLoopIfNeeded()
        startUDPListenerIfNeeded()

        guard pipController == nil else { return }

        sampleBufferView.displayLayer.videoGravity = .resizeAspect
        enqueueHUDFrame(for: currentTelemetry)

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPSupported = false
            statusMessage = "Thiết bị này không hỗ trợ Picture-in-Picture."
            return
        }

        isPiPSupported = true
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferView.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        pipController = controller
    }

    func togglePiP() {
        configureIfNeeded()
        configureAudioSessionAndSilentLoop()

        guard let pipController else {
            statusMessage = "Không thể khởi tạo bộ điều khiển PiP."
            return
        }

        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            enqueueHUDFrame(for: currentTelemetry)
            pipController.startPictureInPicture()
        }
    }

    func startPiP() {
        configureIfNeeded()
        configureAudioSessionAndSilentLoop()
        guard let pipController, !pipController.isPictureInPictureActive else { return }
        enqueueHUDFrame(for: currentTelemetry)
        pipController.startPictureInPicture()
    }

    func stopPiP() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    func updateOverlay(with telemetry: TelemetryData) {
        if telemetry.frameCount > 0 || telemetry.timestamp > 0 {
            lastPacketReceivedAt = Date().timeIntervalSince1970
        }
        currentTelemetry = telemetry
        configureIfNeeded()
        enqueueHUDFrame(for: telemetry)
    }

    func updateTelemetry(_ telemetry: TelemetryData) {
        updateOverlay(with: telemetry)
    }

    // MARK: - Background Silent Audio Keep-Alive

    private func configureAudioSessionAndSilentLoop() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusMessage = "Không thể cấu hình Audio Session nền: \(error.localizedDescription)"
        }
        startSilentAudioLoopIfNeeded()
    }

    private func startSilentAudioLoopIfNeeded() {
        if let player = silentAudioPlayer {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        let silentData = makeSilentWAVData(durationSeconds: 1.0, sampleRate: 8000)
        do {
            let player = try AVAudioPlayer(data: silentData, fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()
            silentAudioPlayer = player
        } catch {
            statusMessage = "Không thể khởi tạo âm thanh nền giữ sống: \(error.localizedDescription)"
        }
    }

    private func makeSilentWAVData(durationSeconds: Double, sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let dataByteSize = UInt32(sampleCount * Int(numChannels) * Int(bitsPerSample / 8))
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let riffSize: UInt32 = 36 + dataByteSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataByteSize))
        data.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: riffSize.littleEndian) { data.append(contentsOf: $0) }
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: dataByteSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(count: Int(dataByteSize)))
        return data
    }

    // MARK: - UDP IPv4 NWListener (0.0.0.0:45678)

    private func startUDPListenerIfNeeded() {
        udpReceiver.start(
            port: SharedIPC.udpPort,
            onTelemetry: { [weak self] telemetry in
                Task { @MainActor [weak self] in
                    self?.updateOverlay(with: telemetry)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.statusMessage = message
                }
            }
        )
    }

    // MARK: - Keep-Alive Refresh Timer

    private func startKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPiPActive else { return }
                self.enqueueHUDFrame(for: self.currentTelemetry)
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - CoreGraphics HUD Frame Rendering (640 x 210)

    private func enqueueHUDFrame(for telemetry: TelemetryData) {
        let displayLayer = sampleBufferView.displayLayer
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        guard let sampleBuffer = renderHUDSampleBuffer(telemetry: telemetry) else { return }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func renderHUDSampleBuffer(telemetry: TelemetryData) -> CMSampleBuffer? {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBufferOut
        )

        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let cgContext = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: rgbColorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        cgContext.translateBy(x: 0, y: CGFloat(height))
        cgContext.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(cgContext)
        drawHUD(in: CGRect(origin: .zero, size: renderSize), telemetry: telemetry)
        UIGraphicsPopContext()

        var formatDescription: CMVideoFormatDescription?
        let descStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descStatus == noErr, let formatDescription else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBufferOut: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBufferOut
        )
        guard sbStatus == noErr, let sampleBuffer = sampleBufferOut else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }

    private func resolveDisplayTelemetry(_ telemetry: TelemetryData) -> (data: TelemetryData, isLive: Bool) {
        let now = Date().timeIntervalSince1970
        let hasLiveSignal = lastPacketReceivedAt > 0
            && (now - lastPacketReceivedAt) <= liveTimeoutSeconds

        let effectivePower = telemetry.calculatedPower > 0.0 ? telemetry.calculatedPower : defaultFallbackPower
        let effectiveAngle = telemetry.angle > 0.0 ? telemetry.angle : 65.0
        let effectiveDx = abs(telemetry.dx) > 0.0001 ? telemetry.dx : 0.48
        let effectiveHold = telemetry.calculatedPower > 0.0
            ? telemetry.holdSeconds
            : ballisticsEngine.calculateHoldSeconds(
                power: effectivePower,
                maxHoldSeconds: BallisticsConfig.default.maxHoldSeconds
            )

        let points: [TrajectoryPoint]
        if telemetry.trajectoryPoints.count >= 2 && telemetry.calculatedPower > 0.0 {
            points = telemetry.trajectoryPoints
        } else {
            points = ballisticsEngine.generateTrajectoryPoints(
                dx: effectiveDx,
                dy: telemetry.dy,
                angleDeg: effectiveAngle,
                wind: telemetry.wind,
                power: effectivePower
            )
        }

        let resolved = TelemetryData(
            dx: effectiveDx,
            dy: telemetry.dy,
            wind: telemetry.wind,
            windDirection: telemetry.windDirection,
            angle: effectiveAngle,
            calculatedPower: effectivePower,
            holdSeconds: effectiveHold,
            timestamp: telemetry.timestamp,
            frameCount: telemetry.frameCount,
            trajectoryPoints: points
        )
        return (resolved, hasLiveSignal)
    }

    private func drawHUD(in rect: CGRect, telemetry: TelemetryData) {
        let cgContext = UIGraphicsGetCurrentContext()
        let (displayTelemetry, isLive) = resolveDisplayTelemetry(telemetry)

        // Nền tối bán trong suốt & viền sáng sắc nét kích thước 640 x 210.
        UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 0.90).setFill()
        UIRectFill(rect)

        let outerRect = rect.insetBy(dx: 2, dy: 2)
        let outerPath = UIBezierPath(roundedRect: outerRect, cornerRadius: 14)
        UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.95).setFill()
        outerPath.fill()

        UIColor(white: 1.0, alpha: 0.42).setStroke()
        outerPath.lineWidth = 1.8
        outerPath.stroke()

        // Chia 2 vùng gọn gàng: phần trên 152px (chiến trường 2 tia) & sát cạnh dưới 58px (thước đo lực 0-100).
        let splitY: CGFloat = 152.0
        let dividerPath = UIBezierPath()
        dividerPath.move(to: CGPoint(x: 12, y: splitY))
        dividerPath.addLine(to: CGPoint(x: rect.width - 12, y: splitY))
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        dividerPath.lineWidth = 1.0
        dividerPath.stroke()

        drawBattlefieldSection(
            in: CGRect(x: 0, y: 0, width: rect.width, height: splitY),
            telemetry: displayTelemetry,
            isLive: isLive,
            cgContext: cgContext
        )

        drawBottomPowerRuler(
            in: CGRect(x: 0, y: splitY, width: rect.width, height: rect.height - splitY),
            telemetry: displayTelemetry,
            cgContext: cgContext
        )
    }

    // MARK: - Battlefield 2-Ray PC Aiming Section (152px)

    private func drawBattlefieldSection(
        in sectionRect: CGRect,
        telemetry: TelemetryData,
        isLive: Bool,
        cgContext: CGContext?
    ) {
        // 1. Góc trên trái: Góc | Gió (< hoặc >) | Giữ.
        let arrowChar = telemetry.windDirection < 0 ? "<" : ">"
        let headerText = String(
            format: "Góc: %.0f° | Gió: %@ %.1f | Giữ: %.2fs",
            telemetry.angle,
            arrowChar,
            abs(telemetry.wind),
            telemetry.holdSeconds
        )
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let attrHeader = NSAttributedString(string: headerText, attributes: headerAttrs)
        let headerSize = attrHeader.size()
        let leftPill = CGRect(
            x: 12,
            y: 7,
            width: min(sectionRect.width - 170, headerSize.width + 18),
            height: 22
        )
        let leftPillPath = UIBezierPath(roundedRect: leftPill, cornerRadius: 6)
        UIColor(red: 0.11, green: 0.14, blue: 0.21, alpha: 0.95).setFill()
        leftPillPath.fill()
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        leftPillPath.lineWidth = 1.0
        leftPillPath.stroke()
        attrHeader.draw(at: CGPoint(x: leftPill.minX + 9, y: leftPill.minY + (leftPill.height - headerSize.height) / 2.0))

        // 2. Góc trên phải: LIVE #[frameCount] (xanh lá) hoặc CHỜ TÍN HIỆU (vàng).
        let statusColor = isLive
            ? UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
            : UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0)
        let statusText = isLive ? "LIVE #\(telemetry.frameCount)" : "CHỜ TÍN HIỆU"
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .heavy),
            .foregroundColor: statusColor
        ]
        let attrStatus = NSAttributedString(string: statusText, attributes: statusAttrs)
        let statusSize = attrStatus.size()
        let statusPillW = statusSize.width + 24.0
        let statusPill = CGRect(
            x: sectionRect.width - statusPillW - 12.0,
            y: 7,
            width: statusPillW,
            height: 22
        )
        let statusPillPath = UIBezierPath(roundedRect: statusPill, cornerRadius: 6)
        UIColor(red: 0.09, green: 0.12, blue: 0.18, alpha: 0.95).setFill()
        statusPillPath.fill()
        statusColor.withAlphaComponent(0.55).setStroke()
        statusPillPath.lineWidth = 1.0
        statusPillPath.stroke()

        let dotCenter = CGPoint(x: statusPill.minX + 10.0, y: statusPill.midY)
        statusColor.withAlphaComponent(0.35).setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 6.0, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        statusColor.setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 3.5, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

        attrStatus.draw(at: CGPoint(x: statusPill.minX + 18.0, y: statusPill.minY + (statusPill.height - statusSize.height) / 2.0))

        // 3. Khung vẽ chiến trường 2 tia.
        let plotRect = CGRect(
            x: 12,
            y: 33,
            width: sectionRect.width - 24,
            height: sectionRect.height - 39
        )
        let plotBg = UIBezierPath(roundedRect: plotRect, cornerRadius: 9)
        UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.88).setFill()
        plotBg.fill()
        UIColor(white: 1.0, alpha: 0.10).setStroke()
        plotBg.lineWidth = 1.0
        plotBg.stroke()

        cgContext?.saveGState()
        plotBg.addClip()

        // Lưới tọa độ mờ.
        let gridPath = UIBezierPath()
        for idx in 1..<8 {
            let gx = plotRect.minX + (plotRect.width * CGFloat(idx) / 8.0)
            gridPath.move(to: CGPoint(x: gx, y: plotRect.minY))
            gridPath.addLine(to: CGPoint(x: gx, y: plotRect.maxY))
        }
        for idx in 1..<3 {
            let gy = plotRect.minY + (plotRect.height * CGFloat(idx) / 3.0)
            gridPath.move(to: CGPoint(x: plotRect.minX, y: gy))
            gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: gy))
        }
        UIColor(white: 1.0, alpha: 0.07).setStroke()
        gridPath.lineWidth = 0.8
        gridPath.stroke()

        let mappedPoints: [CGPoint] = telemetry.trajectoryPoints.map { pt in
            CGPoint(
                x: plotRect.minX + CGFloat(pt.x) * plotRect.width,
                y: plotRect.minY + CGFloat(pt.y) * plotRect.height
            )
        }

        let playerPoint: CGPoint
        let targetPoint: CGPoint
        if let first = mappedPoints.first, let last = mappedPoints.last, mappedPoints.count >= 2 {
            playerPoint = first
            targetPoint = last
        } else {
            let shootsRight = telemetry.dx >= 0.0
            let leftX = plotRect.minX + plotRect.width * 0.12
            let rightX = plotRect.minX + plotRect.width * 0.88
            let baselineY = plotRect.minY + plotRect.height * 0.80
            playerPoint = CGPoint(x: shootsRight ? leftX : rightX, y: baselineY)
            targetPoint = CGPoint(x: shootsRight ? rightX : leftX, y: baselineY)
        }

        // Đường mặt đất ngang tại cao độ người chơi.
        let groundY = min(max(playerPoint.y, plotRect.minY + 12), plotRect.maxY - 8)
        let groundPath = UIBezierPath()
        groundPath.move(to: CGPoint(x: plotRect.minX, y: groundY))
        groundPath.addLine(to: CGPoint(x: plotRect.maxX, y: groundY))
        UIColor(red: 0.35, green: 0.75, blue: 0.55, alpha: 0.28).setStroke()
        groundPath.lineWidth = 1.1
        groundPath.stroke()

        // TIA 1 (Tia ngắm góc): Đường thẳng nét mảnh màu vàng chiếu từ chấm xanh theo đúng góc bắn.
        let safeAngleRad = CGFloat(min(max(telemetry.angle, 1.0), 89.0) * .pi / 180.0)
        let directionSign: CGFloat = telemetry.dx >= 0.0 ? 1.0 : -1.0
        let rayLength: CGFloat = 240.0
        let rayEnd = CGPoint(
            x: playerPoint.x + directionSign * cos(safeAngleRad) * rayLength,
            y: playerPoint.y - sin(safeAngleRad) * rayLength
        )
        let angleRay = UIBezierPath()
        angleRay.move(to: playerPoint)
        angleRay.addLine(to: rayEnd)
        UIColor(red: 1.0, green: 0.84, blue: 0.10, alpha: 0.92).setStroke()
        angleRay.lineWidth = 1.4
        angleRay.stroke()

        // TIA 2 (Quỹ đạo đạn): Đường cong parabol nét đứt màu đỏ/xanh neon bay vồng tới trúng chấm đỏ.
        if mappedPoints.count >= 2 {
            let curvePath = UIBezierPath()
            curvePath.move(to: mappedPoints[0])
            for pt in mappedPoints.dropFirst() {
                curvePath.addLineToPoint(pt)
            }

            let dashPattern: [CGFloat] = [7.0, 5.0]
            curvePath.lineCapStyle = .round
            curvePath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)

            // Lớp viền phát sáng đỏ rực bên ngoài.
            UIColor(red: 1.0, green: 0.22, blue: 0.18, alpha: 0.42).setStroke()
            curvePath.lineWidth = 4.8
            curvePath.stroke()

            // Lõi đường cong nét đứt xanh lá neon sắc nét.
            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0).setStroke()
            curvePath.lineWidth = 2.2
            curvePath.stroke()
        }

        // Chấm xanh (người chơi).
        UIColor(red: 0.16, green: 0.62, blue: 1.0, alpha: 0.32).setFill()
        UIBezierPath(arcCenter: playerPoint, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        let playerCircle = UIBezierPath(arcCenter: playerPoint, radius: 5.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 0.16, green: 0.65, blue: 1.0, alpha: 1.0).setFill()
        playerCircle.fill()
        UIColor.white.setStroke()
        playerCircle.lineWidth = 1.4
        playerCircle.stroke()

        // Chấm đỏ (địch) có tâm ngắm.
        UIColor(red: 1.0, green: 0.20, blue: 0.20, alpha: 0.30).setFill()
        UIBezierPath(arcCenter: targetPoint, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        let enemyCircle = UIBezierPath(arcCenter: targetPoint, radius: 6.0, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 0.96).setFill()
        enemyCircle.fill()
        UIColor.white.setStroke()
        enemyCircle.lineWidth = 1.3
        enemyCircle.stroke()

        let reticle = UIBezierPath()
        let arm: CGFloat = 9.5
        reticle.move(to: CGPoint(x: targetPoint.x - arm, y: targetPoint.y))
        reticle.addLine(to: CGPoint(x: targetPoint.x + arm, y: targetPoint.y))
        reticle.move(to: CGPoint(x: targetPoint.x, y: targetPoint.y - arm))
        reticle.addLine(to: CGPoint(x: targetPoint.x, y: targetPoint.y + arm))
        UIColor(red: 1.0, green: 0.85, blue: 0.85, alpha: 0.95).setStroke()
        reticle.lineWidth = 1.1
        reticle.stroke()

        cgContext?.restoreGState()
    }

    // MARK: - Bottom Power Ruler (58px: 0 — 25 — 50 — 75 — 100)

    private func drawBottomPowerRuler(in sectionRect: CGRect, telemetry: TelemetryData, cgContext: CGContext?) {
        let barMarginX: CGFloat = 20.0
        let barRect = CGRect(
            x: barMarginX,
            y: sectionRect.minY + 18.0,
            width: sectionRect.width - barMarginX * 2.0,
            height: 16.0
        )

        let clampedPower = CGFloat(min(max(telemetry.calculatedPower, 0.0), 100.0))
        let fillWidth = barRect.width * (clampedPower / 100.0)
        let markerX = barRect.minX + fillWidth

        // Nền thước lực.
        let trackPath = UIBezierPath(roundedRect: barRect, cornerRadius: 5)
        UIColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 1.0).setFill()
        trackPath.fill()

        // Tô dải màu Vàng -> Cam -> Đỏ từ 0 đến lực cần bắn.
        if fillWidth > 0.5, let cgContext {
            cgContext.saveGState()
            trackPath.addClip()
            cgContext.clip(to: CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height))

            let colors = [
                UIColor(red: 1.0, green: 0.90, blue: 0.12, alpha: 1.0).cgColor,
                UIColor(red: 1.0, green: 0.52, blue: 0.05, alpha: 1.0).cgColor,
                UIColor(red: 1.0, green: 0.16, blue: 0.05, alpha: 1.0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.55, 1.0]
            if let gradient = CGGradient(colorsSpace: rgbColorSpace, colors: colors, locations: locations) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: barRect.minX, y: barRect.midY),
                    end: CGPoint(x: barRect.maxX, y: barRect.midY),
                    options: []
                )
            }
            cgContext.restoreGState()
        }

        UIColor(white: 1.0, alpha: 0.35).setStroke()
        trackPath.lineWidth = 1.0
        trackPath.stroke()

        // Vạch chia 0 — 25 — 50 — 75 — 100.
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: UIColor(white: 0.78, alpha: 1.0)
        ]
        for step in stride(from: 0, through: 100, by: 5) {
            let tx = barRect.minX + barRect.width * (CGFloat(step) / 100.0)
            let isMajor = step % 25 == 0
            let tick = UIBezierPath()
            if isMajor {
                tick.move(to: CGPoint(x: tx, y: barRect.minY))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 3))
                UIColor(white: 1.0, alpha: 0.75).setStroke()
                tick.lineWidth = 1.2
                tick.stroke()

                let label = NSAttributedString(string: "\(step)", attributes: tickAttrs)
                let labelSize = label.size()
                let labelX: CGFloat
                if step == 0 {
                    labelX = tx
                } else if step == 100 {
                    labelX = tx - labelSize.width
                } else {
                    labelX = tx - labelSize.width / 2.0
                }
                label.draw(at: CGPoint(x: labelX, y: barRect.maxY + 4))
            } else {
                tick.move(to: CGPoint(x: tx, y: barRect.maxY - 4))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY))
                UIColor(white: 1.0, alpha: 0.24).setStroke()
                tick.lineWidth = 0.8
                tick.stroke()
            }
        }

        // Vạch chỉ thị đỏ nổi bật tại vị trí lực cần bắn.
        let redLine = UIBezierPath()
        redLine.move(to: CGPoint(x: markerX, y: barRect.minY - 4))
        redLine.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 4))
        redLine.lineCapStyle = .round
        UIColor(red: 1.0, green: 0.16, blue: 0.14, alpha: 1.0).setStroke()
        redLine.lineWidth = 4.2
        redLine.stroke()

        let whiteCore = UIBezierPath()
        whiteCore.move(to: CGPoint(x: markerX, y: barRect.minY - 3))
        whiteCore.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 3))
        whiteCore.lineCapStyle = .round
        UIColor.white.setStroke()
        whiteCore.lineWidth = 1.6
        whiteCore.stroke()

        // Con số lực cần bắn ngay phía trên vạch chỉ thị.
        let powerText = String(format: "%.1f", clampedPower)
        let powerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let attrPower = NSAttributedString(string: powerText, attributes: powerAttrs)
        let powerSize = attrPower.size()
        let desiredX = markerX - powerSize.width / 2.0
        let clampedX = min(max(desiredX, barRect.minX), barRect.maxX - powerSize.width)
        let badgeY = sectionRect.minY + 1.0

        let badgeRect = CGRect(x: clampedX - 6, y: badgeY, width: powerSize.width + 12, height: 16)
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 4)
        UIColor(red: 0.90, green: 0.16, blue: 0.12, alpha: 0.96).setFill()
        badgePath.fill()
        UIColor(white: 1.0, alpha: 0.80).setStroke()
        badgePath.lineWidth = 0.8
        badgePath.stroke()
        attrPower.draw(at: CGPoint(x: clampedX, y: badgeY + (16.0 - powerSize.height) / 2.0))
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPOverlayManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.statusMessage = nil
            self.startKeepAliveTimer()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            self.stopKeepAliveTimer()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isPiPActive = false
            self.stopKeepAliveTimer()
            self.statusMessage = "Không thể mở PiP: \(error.localizedDescription)"
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPOverlayManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
