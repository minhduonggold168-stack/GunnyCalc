import PhotosUI
import SwiftUI
import UIKit

/// Màn hình chọn ảnh chụp trận đấu từ Thư viện ảnh và kéo thả căn chỉnh 3 vùng ROI chuẩn hóa `0.0 - 1.0`.
struct ROICalibratorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
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
                    selectedImage == nil ? "Chọn ảnh Gunny" : "Đổi ảnh mẫu",
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
