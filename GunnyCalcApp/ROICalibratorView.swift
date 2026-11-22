import PhotosUI
import SwiftUI
import UIKit

/// Màn hình chọn ảnh chụp trận đấu từ Thư viện ảnh và kéo thả căn chỉnh 3 vùng ROI chuẩn hóa `0.0 - 1.0`.
struct ROICalibratorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage? = ROICalibratorView.generateBuiltInGunnyReferenceImage(
        size: CGSize(width: 1300, height: 600)
    )
    @State private var roiConfig: ROIConfig = SharedIPC.shared.loadROIConfig()
    @State private var activeField: ROIField = .minimap
    @State private var testResult: VisionObservationResult?
    @State private var savedBannerVisible = false
    @State private var errorMessage: String?

    var onSave: ((ROIConfig) -> Void)?

    enum ROIField: String, CaseIterable, Identifiable {
        case minimap = "Minimap"
        case wind = "Ô Gió"
        case angle = "Ô Góc"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .minimap: return .green
            case .wind: return .blue
            case .angle: return .orange
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                headerControls

                canvasArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                activeRectReadout

                if let testResult {
                    testPreviewBar(result: testResult)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                bottomActionBar
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Căn chỉnh vùng ROI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mặc định") {
                        roiConfig = .default
                        selectedImage = Self.generateBuiltInGunnyReferenceImage(size: CGSize(width: 1300, height: 600))
                        testResult = nil
                    }
                    .foregroundStyle(.orange)
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: selectedItem) { newItem in
                loadPhoto(from: newItem)
            }
        }
    }

    // MARK: - Subviews

    private var headerControls: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                Label(
                    "Đổi ảnh mẫu",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.22))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(ROIField.allCases) { field in
                    Button {
                        activeField = field
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(field.color)
                                .frame(width: 8, height: 8)
                            Text(field.rawValue)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            activeField == field
                                ? field.color.opacity(0.24)
                                : Color.white.opacity(0.08)
                        )
                        .foregroundStyle(activeField == field ? field.color : .secondary)
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            let imageAspect = selectedImage.map { $0.size.width / max($0.size.height, 1) } ?? (16.0 / 9.0)
            let imageFrame = aspectFitFrame(aspectRatio: imageAspect, in: geo.size)

            ZStack {
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                } else {
                    placeholderCanvas(in: imageFrame)
                }

                // 3 khung ROI tương tác trên cùng hệ tọa độ khung ảnh.
                ZStack(alignment: .topLeading) {
                    ROIBoxOverlay(
                        title: "Minimap",
                        color: .green,
                        isActive: activeField == .minimap,
                        containerSize: imageFrame.size,
                        normalizedRect: $roiConfig.minimapRect,
                        onSelect: { activeField = .minimap }
                    )

                    ROIBoxOverlay(
                        title: "Gió",
                        color: .blue,
                        isActive: activeField == .wind,
                        containerSize: imageFrame.size,
                        normalizedRect: $roiConfig.windRect,
                        onSelect: { activeField = .wind }
                    )

                    ROIBoxOverlay(
                        title: "Góc",
                        color: .orange,
                        isActive: activeField == .angle,
                        containerSize: imageFrame.size,
                        normalizedRect: $roiConfig.angleRect,
                        onSelect: { activeField = .angle }
                    )
                }
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholderCanvas(in frame: CGRect) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Chọn 1 ảnh chụp màn hình trận đấu Gunny Mobi\nđể kéo thả căn chỉnh 3 khung ROI (tỉ lệ 0.0 - 1.0)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(width: frame.width, height: frame.height)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(Color.white.opacity(0.2))
        )
        .position(x: frame.midX, y: frame.midY)
    }

    private var activeRectReadout: some View {
        let rect = rectForField(activeField)
        return HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(activeField.color)
                    .frame(width: 8, height: 8)
                Text(activeField.rawValue)
                    .font(.caption.weight(.semibold))
            }

            Spacer()

            Text(String(
                format: "x: %.3f  y: %.3f  w: %.3f  h: %.3f",
                rect.x, rect.y, rect.width, rect.height
            ))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func testPreviewBar(result: VisionObservationResult) -> some View {
        HStack(spacing: 12) {
            Label(
                result.hasValidMinimap
                    ? String(format: "dx: %.3f | dy: %.3f", result.dx, result.dy)
                    : "Chưa thấy chấm xanh/đỏ",
                systemImage: result.hasValidMinimap ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(result.hasValidMinimap ? .green : .yellow)

            Spacer()

            Text("Gió: \(result.wind.map { String(format: "%.1f", $0) } ?? "--")")
            Text("Góc: \(result.angle.map { String(format: "%.0f°", $0) } ?? "--")")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            if selectedImage != nil {
                Button {
                    runPreviewOCR()
                } label: {
                    Label("Thử đọc", systemImage: "viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(Color.white.opacity(0.12))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            Button {
                saveConfiguration()
            } label: {
                HStack {
                    Image(systemName: savedBannerVisible ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                    Text(savedBannerVisible ? "Đã lưu cấu hình ROI!" : "Lưu cấu hình vùng cắt")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(savedBannerVisible ? Color.green : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Actions & Helpers

    private func rectForField(_ field: ROIField) -> NormalizedRect {
        switch field {
        case .minimap: return roiConfig.minimapRect
        case .wind: return roiConfig.windRect
        case .angle: return roiConfig.angleRect
        }
    }

    private func saveConfiguration() {
        let normalized = ROIConfig(
            minimapRect: NormalizedRect(
                x: roiConfig.minimapRect.x,
                y: roiConfig.minimapRect.y,
                width: roiConfig.minimapRect.width,
                height: roiConfig.minimapRect.height
            ),
            windRect: NormalizedRect(
                x: roiConfig.windRect.x,
                y: roiConfig.windRect.y,
                width: roiConfig.windRect.width,
                height: roiConfig.windRect.height
            ),
            angleRect: NormalizedRect(
                x: roiConfig.angleRect.x,
                y: roiConfig.angleRect.y,
                width: roiConfig.angleRect.width,
                height: roiConfig.angleRect.height
            )
        )
        roiConfig = normalized
        SharedIPC.shared.saveROIConfig(normalized)
        onSave?(normalized)

        withAnimation(.easeInOut(duration: 0.2)) {
            savedBannerVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                savedBannerVisible = false
            }
        }
    }

    private func runPreviewOCR() {
        guard let cgImage = selectedImage?.cgImage else { return }
        let processor = VisionProcessor()
        testResult = processor.process(cgImage: cgImage, roiConfig: roiConfig)
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else { return }
        errorMessage = nil
        testResult = nil

        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let rawImage = UIImage(data: data) {
                    let normalizedImage = normalizeOrientation(rawImage)
                    await MainActor.run {
                        self.selectedImage = normalizedImage
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Không thể tải ảnh từ Thư viện: \(error.localizedDescription)"
                }
            }
        }
    }

    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func aspectFitFrame(aspectRatio: CGFloat, in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, aspectRatio > 0 else {
            return .zero
        }

        let containerAspect = containerSize.width / containerSize.height
        let fittedSize: CGSize
        if aspectRatio > containerAspect {
            let width = containerSize.width
            fittedSize = CGSize(width: width, height: width / aspectRatio)
        } else {
            let height = containerSize.height
            fittedSize = CGSize(width: height * aspectRatio, height: height)
        }

        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2.0,
            y: (containerSize.height - fittedSize.height) / 2.0,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    // MARK: - Built-in Gunny Mobi Reference Image Generator (19.5:9)

    /// Tự động vẽ ảnh mẫu giao diện trận đấu Gunny Mobi chuẩn tỉ lệ màn hình iPhone 19.5:9
    /// gồm ô Gió ở giữa trên, Minimap ở góc trên phải, vùng chữ `Góc 31°` ở giữa và thanh lực 0 - 100 ở cạnh dưới.
    static func generateBuiltInGunnyReferenceImage(size: CGSize) -> UIImage {
        let safeSize = CGSize(width: max(size.width, 650), height: max(size.height, 300))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: safeSize, format: format)
        return renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            let w = safeSize.width
            let h = safeSize.height
            let fullRect = CGRect(origin: .zero, size: safeSize)

            // 1. Nền trời chiến trường Gunny Mobi.
            let skyColors = [
                UIColor(red: 0.08, green: 0.16, blue: 0.30, alpha: 1.0).cgColor,
                UIColor(red: 0.13, green: 0.27, blue: 0.42, alpha: 1.0).cgColor,
                UIColor(red: 0.16, green: 0.35, blue: 0.36, alpha: 1.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: skyColors,
                locations: [0.0, 0.55, 1.0]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: h),
                    options: []
                )
            }

            // Đảo & thềm đất chiến trường ở phần giữa - dưới.
            let islandPath = UIBezierPath()
            islandPath.move(to: CGPoint(x: 0, y: h * 0.66))
            islandPath.addQuadCurve(to: CGPoint(x: w * 0.34, y: h * 0.57), controlPoint: CGPoint(x: w * 0.17, y: h * 0.56))
            islandPath.addQuadCurve(to: CGPoint(x: w * 0.68, y: h * 0.60), controlPoint: CGPoint(x: w * 0.51, y: h * 0.67))
            islandPath.addQuadCurve(to: CGPoint(x: w, y: h * 0.54), controlPoint: CGPoint(x: w * 0.85, y: h * 0.52))
            islandPath.addLine(to: CGPoint(x: w, y: h))
            islandPath.addLine(to: CGPoint(x: 0, y: h))
            islandPath.close()
            UIColor(red: 0.18, green: 0.33, blue: 0.22, alpha: 1.0).setFill()
            islandPath.fill()

            let grassStrip = UIBezierPath()
            grassStrip.move(to: CGPoint(x: 0, y: h * 0.66))
            grassStrip.addQuadCurve(to: CGPoint(x: w * 0.34, y: h * 0.57), controlPoint: CGPoint(x: w * 0.17, y: h * 0.56))
            grassStrip.addQuadCurve(to: CGPoint(x: w * 0.68, y: h * 0.60), controlPoint: CGPoint(x: w * 0.51, y: h * 0.67))
            grassStrip.addQuadCurve(to: CGPoint(x: w, y: h * 0.54), controlPoint: CGPoint(x: w * 0.85, y: h * 0.52))
            UIColor(red: 0.32, green: 0.64, blue: 0.28, alpha: 1.0).setStroke()
            grassStrip.lineWidth = h * 0.025
            grassStrip.stroke()

            // 2. Ô Gió ở chính giữa trên cùng (khớp windROI: x: 0.44, y: 0.01, w: 0.12, h: 0.09).
            let windBox = CGRect(x: w * 0.44, y: h * 0.01, width: w * 0.12, height: h * 0.09)
            let windBg = UIBezierPath(roundedRect: windBox.insetBy(dx: 3, dy: 2), cornerRadius: 10)
            UIColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 0.90).setFill()
            windBg.fill()
            UIColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 0.85).setStroke()
            windBg.lineWidth = 2
            windBg.stroke()

            let windPara = NSMutableParagraphStyle()
            windPara.alignment = .center
            let windText = NSAttributedString(
                string: "+1.5",
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: h * 0.044, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: windPara
                ]
            )
            windText.draw(in: CGRect(
                x: windBox.minX,
                y: windBox.midY - h * 0.027,
                width: windBox.width,
                height: h * 0.055
            ))

            // 3. Ô Minimap ở góc trên bên phải (khớp minimapROI: x: 0.67, y: 0.03, w: 0.30, h: 0.28).
            let miniBox = CGRect(x: w * 0.67, y: h * 0.03, width: w * 0.30, height: h * 0.28)
            let miniBg = UIBezierPath(roundedRect: miniBox, cornerRadius: 10)
            UIColor(red: 0.08, green: 0.11, blue: 0.15, alpha: 0.88).setFill()
            miniBg.fill()
            UIColor(white: 1.0, alpha: 0.38).setStroke()
            miniBg.lineWidth = 2
            miniBg.stroke()

            // Địa hình mô phỏng trên minimap (độ bão hòa thấp để bộ lọc HSV chỉ bắt 2 chấm Xanh/Đỏ).
            let miniTerrain = UIBezierPath()
            miniTerrain.move(to: CGPoint(x: miniBox.minX + 6, y: miniBox.maxY - miniBox.height * 0.28))
            miniTerrain.addLine(to: CGPoint(x: miniBox.minX + miniBox.width * 0.38, y: miniBox.maxY - miniBox.height * 0.38))
            miniTerrain.addLine(to: CGPoint(x: miniBox.minX + miniBox.width * 0.68, y: miniBox.maxY - miniBox.height * 0.30))
            miniTerrain.addLine(to: CGPoint(x: miniBox.maxX - 6, y: miniBox.maxY - miniBox.height * 0.42))
            miniTerrain.addLine(to: CGPoint(x: miniBox.maxX - 6, y: miniBox.maxY - 6))
            miniTerrain.addLine(to: CGPoint(x: miniBox.minX + 6, y: miniBox.maxY - 6))
            miniTerrain.close()
            UIColor(red: 0.20, green: 0.24, blue: 0.26, alpha: 0.90).setFill()
            miniTerrain.fill()

            // Chấm xanh dương (Người chơi) và chấm đỏ (Mục tiêu địch) trên Minimap.
            let blueDotCenter = CGPoint(x: miniBox.minX + miniBox.width * 0.26, y: miniBox.minY + miniBox.height * 0.56)
            let redDotCenter = CGPoint(x: miniBox.minX + miniBox.width * 0.76, y: miniBox.minY + miniBox.height * 0.46)
            let dotRadius: CGFloat = max(6.0, miniBox.height * 0.055)

            UIColor(red: 0.05, green: 0.48, blue: 1.0, alpha: 1.0).setFill()
            UIBezierPath(
                arcCenter: blueDotCenter,
                radius: dotRadius,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: true
            ).fill()

            UIColor(red: 1.0, green: 0.12, blue: 0.12, alpha: 1.0).setFill()
            UIBezierPath(
                arcCenter: redDotCenter,
                radius: dotRadius,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: true
            ).fill()

            // 4. Nhân vật, địch và chữ "Góc 31°" trong vùng trung tâm chiến trường (angleROI: 0.22, 0.18, 0.56, 0.48).
            let playerPos = CGPoint(x: w * 0.30, y: h * 0.54)
            let enemyPos = CGPoint(x: w * 0.69, y: h * 0.54)

            // Nhân vật người chơi.
            let playerBody = UIBezierPath(ovalIn: CGRect(x: playerPos.x - 18, y: playerPos.y - 44, width: 36, height: 44))
            UIColor(red: 0.20, green: 0.68, blue: 1.0, alpha: 1.0).setFill()
            playerBody.fill()
            UIColor.white.setStroke()
            playerBody.lineWidth = 2
            playerBody.stroke()

            // Mục tiêu địch.
            let enemyBody = UIBezierPath(ovalIn: CGRect(x: enemyPos.x - 20, y: enemyPos.y - 48, width: 40, height: 48))
            UIColor(red: 0.96, green: 0.24, blue: 0.24, alpha: 1.0).setFill()
            enemyBody.fill()
            UIColor.white.setStroke()
            enemyBody.lineWidth = 2
            enemyBody.stroke()

            // Nhãn góc bắn nổi cạnh nhân vật: "Góc 31°".
            let angleBadgeRect = CGRect(x: w * 0.35, y: h * 0.36, width: w * 0.13, height: h * 0.085)
            let angleBadgePath = UIBezierPath(roundedRect: angleBadgeRect, cornerRadius: 8)
            UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 0.88).setFill()
            angleBadgePath.fill()
            UIColor(red: 1.0, green: 0.80, blue: 0.22, alpha: 0.95).setStroke()
            angleBadgePath.lineWidth = 2
            angleBadgePath.stroke()

            let anglePara = NSMutableParagraphStyle()
            anglePara.alignment = .center
            let angleText = NSAttributedString(
                string: "Góc 31°",
                attributes: [
                    .font: UIFont.systemFont(ofSize: h * 0.044, weight: .heavy),
                    .foregroundColor: UIColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 1.0),
                    .paragraphStyle: anglePara
                ]
            )
            angleText.draw(in: CGRect(
                x: angleBadgeRect.minX,
                y: angleBadgeRect.midY - h * 0.026,
                width: angleBadgeRect.width,
                height: h * 0.055
            ))

            // 5. Thanh lực 0 - 100 ở cạnh dưới & nút điều khiển game mô phỏng.
            let powerBarRect = CGRect(x: w * 0.22, y: h * 0.88, width: w * 0.56, height: h * 0.055)
            let barBg = UIBezierPath(roundedRect: powerBarRect, cornerRadius: 8)
            UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 0.90).setFill()
            barBg.fill()
            UIColor(white: 1.0, alpha: 0.45).setStroke()
            barBg.lineWidth = 2
            barBg.stroke()

            let fillRect = CGRect(
                x: powerBarRect.minX + 2,
                y: powerBarRect.minY + 2,
                width: (powerBarRect.width - 4) * 0.62,
                height: powerBarRect.height - 4
            )
            let barFill = UIBezierPath(roundedRect: fillRect, cornerRadius: 6)
            UIColor(red: 1.0, green: 0.58, blue: 0.12, alpha: 0.95).setFill()
            barFill.fill()

            let tickAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: h * 0.026, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            for value in [0, 25, 50, 75, 100] {
                let ratio = CGFloat(value) / 100.0
                let tx = powerBarRect.minX + powerBarRect.width * ratio
                let tick = UIBezierPath()
                tick.move(to: CGPoint(x: tx, y: powerBarRect.minY))
                tick.addLine(to: CGPoint(x: tx, y: powerBarRect.maxY))
                UIColor(white: 1.0, alpha: 0.65).setStroke()
                tick.lineWidth = 1.5
                tick.stroke()

                let label = NSAttributedString(string: "\(value)", attributes: tickAttrs)
                let labelSize = label.size()
                label.draw(at: CGPoint(x: tx - labelSize.width * 0.5, y: powerBarRect.minY - labelSize.height - 4))
            }

            // Nút Bắn mô phỏng góc dưới phải & D-pad góc dưới trái.
            let fireCenter = CGPoint(x: w * 0.90, y: h * 0.80)
            let fireCircle = UIBezierPath(arcCenter: fireCenter, radius: h * 0.09, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor(red: 0.90, green: 0.28, blue: 0.16, alpha: 0.78).setFill()
            fireCircle.fill()
            UIColor.white.setStroke()
            fireCircle.lineWidth = 2.5
            fireCircle.stroke()

            let fireText = NSAttributedString(
                string: "BẮN",
                attributes: [
                    .font: UIFont.systemFont(ofSize: h * 0.036, weight: .heavy),
                    .foregroundColor: UIColor.white
                ]
            )
            let fireSize = fireText.size()
            fireText.draw(at: CGPoint(x: fireCenter.x - fireSize.width * 0.5, y: fireCenter.y - fireSize.height * 0.5))

            let dpadCenter = CGPoint(x: w * 0.10, y: h * 0.80)
            let dpadCircle = UIBezierPath(arcCenter: dpadCenter, radius: h * 0.09, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor(white: 1.0, alpha: 0.14).setFill()
            dpadCircle.fill()
            UIColor(white: 1.0, alpha: 0.35).setStroke()
            dpadCircle.lineWidth = 2
            dpadCircle.stroke()

            _ = fullRect
        }
    }
}

// MARK: - Interactive Draggable & Resizable ROI Overlay Box

private struct ROIBoxOverlay: View {
    let title: String
    let color: Color
    let isActive: Bool
    let containerSize: CGSize
    @Binding var normalizedRect: NormalizedRect
    let onSelect: () -> Void

    @State private var dragStartRect: NormalizedRect?
    @State private var resizeStartRect: NormalizedRect?

    private let minNormalizedSize = 0.03

    var body: some View {
        let boxWidth = max(12, normalizedRect.width * containerSize.width)
        let boxHeight = max(12, normalizedRect.height * containerSize.height)
        let originX = normalizedRect.x * containerSize.width
        let originY = normalizedRect.y * containerSize.height

        ZStack(alignment: .topLeading) {
            // Thân khung cho phép kéo di chuyển vị trí.
            Rectangle()
                .fill(color.opacity(isActive ? 0.22 : 0.12))
                .overlay(
                    Rectangle()
                        .stroke(color, lineWidth: isActive ? 2.5 : 1.75)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onSelect()
                            let base = dragStartRect ?? normalizedRect
                            if dragStartRect == nil {
                                dragStartRect = base
                            }
                            guard containerSize.width > 0, containerSize.height > 0 else { return }

                            let deltaX = value.translation.width / containerSize.width
                            let deltaY = value.translation.height / containerSize.height

                            let newX = min(max(base.x + deltaX, 0.0), 1.0 - base.width)
                            let newY = min(max(base.y + deltaY, 0.0), 1.0 - base.height)
                            normalizedRect = NormalizedRect(
                                x: newX,
                                y: newY,
                                width: base.width,
                                height: base.height
                            )
                        }
                        .onEnded { _ in
                            dragStartRect = nil
                        }
                )

            // Nhãn tên vùng ở góc trên-trái.
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .offset(x: 2, y: 2)
                .allowsHitTesting(false)

            // Tay cầm kéo góc dưới-phải để thay đổi kích thước mượt mà.
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(x: boxWidth, y: boxHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSelect()
                        let base = resizeStartRect ?? normalizedRect
                        if resizeStartRect == nil {
                            resizeStartRect = base
                        }
                        guard containerSize.width > 0, containerSize.height > 0 else { return }

                        let deltaW = value.translation.width / containerSize.width
                        let deltaH = value.translation.height / containerSize.height

                        let maxW = 1.0 - base.x
                        let maxH = 1.0 - base.y
                        let newW = min(max(base.width + deltaW, minNormalizedSize), maxW)
                        let newH = min(max(base.height + deltaH, minNormalizedSize), maxH)

                        normalizedRect = NormalizedRect(
                            x: base.x,
                            y: base.y,
                            width: newW,
                            height: newH
                        )
                    }
                    .onEnded { _ in
                        resizeStartRect = nil
                    }
            )
        }
        .frame(width: boxWidth, height: boxHeight)
        .offset(x: originX, y: originY)
        .zIndex(isActive ? 2 : 1)
    }
}
