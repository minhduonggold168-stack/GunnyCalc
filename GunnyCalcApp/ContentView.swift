import ReplayKit
import SwiftUI
import UIKit

/// Quản lý trạng thái dùng chung và đồng bộ hóa với `SharedIPC` + `PiPOverlayManager`.
@MainActor
final class GunnyCalcViewModel: ObservableObject {
    @Published var telemetry: TelemetryData
    @Published var ballisticsConfig: BallisticsConfig
    @Published var roiConfig: ROIConfig

    private let engine = BallisticsEngine()
    private let ipc = SharedIPC.shared

    init() {
        let savedConfig = ipc.loadBallisticsConfig()
        let savedROI = ipc.loadROIConfig()
        let savedTelemetry = ipc.loadTelemetry() ?? TelemetryData(
            dx: 0.0,
            dy: 0.0,
            wind: 0.0,
            angle: savedConfig.selectedAngle,
            calculatedPower: 0.0,
            holdSeconds: 0.0,
            timestamp: 0
        )

        self.ballisticsConfig = savedConfig
        self.roiConfig = savedROI
        self.telemetry = savedTelemetry
    }

    func startListening() {
        refreshFromIPC()
        ipc.startObservingTelemetry { [weak self] latest in
            guard let self else { return }
            Task { @MainActor in
                self.applyTelemetry(latest)
            }
        }
        ipc.startObservingConfig { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.roiConfig = self.ipc.loadROIConfig()
                self.ballisticsConfig = self.ipc.loadBallisticsConfig()
            }
        }
    }

    func stopListening() {
        ipc.stopObservingTelemetry()
        ipc.stopObservingConfig()
    }

    func refreshFromIPC() {
        ballisticsConfig = ipc.loadBallisticsConfig()
        roiConfig = ipc.loadROIConfig()
        if let latest = ipc.loadTelemetry() {
            applyTelemetry(latest)
        } else {
            PiPOverlayManager.shared.updateOverlay(with: telemetry)
        }
    }

    func selectFixedAngle(_ angle: Double) {
        ballisticsConfig.useOCRAngle = false
        ballisticsConfig.selectedAngle = angle
        persistAndRecalculate()
    }

    func enableOCRAngleMode() {
        ballisticsConfig.useOCRAngle = true
        persistAndRecalculate()
    }

    func saveConfigOnly() {
        ipc.saveBallisticsConfig(ballisticsConfig)
    }

    func persistAndRecalculate() {
        ipc.saveBallisticsConfig(ballisticsConfig)

        let detectedAngle: Double? = ballisticsConfig.useOCRAngle ? telemetry.angle : nil
        let updated = engine.computeTelemetry(
            dx: telemetry.dx,
            dy: telemetry.dy,
            wind: telemetry.wind,
            detectedAngle: detectedAngle,
            config: ballisticsConfig,
            timestamp: telemetry.timestamp
        )

        telemetry = updated
        PiPOverlayManager.shared.updateOverlay(with: updated)
    }

    private func applyTelemetry(_ latest: TelemetryData?) {
        guard let latest else { return }
        telemetry = latest
        PiPOverlayManager.shared.updateOverlay(with: latest)
    }
}

/// Màn hình chính tối giản (Minimalist Dark Mode) gồm phần Giới thiệu/Hướng dẫn ở nửa trên
/// và đúng 3 nút điều khiển cốt lõi ở nửa dưới.
struct ContentView: View {
    @ObservedObject var viewModel: GunnyCalcViewModel
    @ObservedObject var pipManager: PiPOverlayManager = .shared

    @State private var isShowingCalibrator = false
    @State private var isShowingSettings = false
    @State private var launchFailureMessage: String?

    private let neonGreen = Color(red: 0.0, green: 1.0, blue: 0.533)

    var body: some View {
        ZStack {
            // Giữ AVSampleBufferDisplayLayer gắn trong hệ thống phân cấp view để PiP chạy nền ổn định.
            PiPHostView(manager: pipManager)
                .frame(width: 240, height: 105)
                .opacity(0.01)
                .allowsHitTesting(false)

            // Nền tối tối giản kèm ánh sáng nhẹ phía trên.
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.09),
                    Color(red: 0.02, green: 0.03, blue: 0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 8)

                heroAndGuideSection

                Spacer(minLength: 20)

                compactControlButtonsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 22)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingCalibrator) {
            ROICalibratorView { updatedROI in
                viewModel.roiConfig = updatedROI
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            QuickSettingsSheetView(viewModel: viewModel)
        }
        .alert("Không thể mở Gunny Mobi", isPresented: Binding(
            get: { launchFailureMessage != nil },
            set: { if !$0 { launchFailureMessage = nil } }
        )) {
            Button("Mở Cài đặt") {
                launchFailureMessage = nil
                isShowingSettings = true
            }
            Button("Đóng", role: .cancel) {
                launchFailureMessage = nil
            }
        } message: {
            Text(launchFailureMessage ?? "")
        }
    }

    // MARK: - Top Bar (Icon bánh răng góc trên bên phải)

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            }
            .accessibilityLabel("Cài đặt nâng cao")
        }
    }

    // MARK: - 1. Nửa trên: Giới thiệu & Hướng dẫn nhanh

    private var heroAndGuideSection: some View {
        VStack(spacing: 16) {
            // Biểu tượng tâm ngắm phát sáng.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [neonGreen.opacity(0.32), Color.clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 56
                        )
                    )
                    .frame(width: 112, height: 112)

                Circle()
                    .fill(Color(red: 0.08, green: 0.11, blue: 0.16))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .stroke(neonGreen.opacity(0.65), lineWidth: 1.5)
                    )
                    .shadow(color: neonGreen.opacity(0.45), radius: 14)

                Image(systemName: "scope")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(neonGreen)
            }

            VStack(spacing: 8) {
                Text("Gunny Aim Assist")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Circle()
                        .fill(neonGreen)
                        .frame(width: 6, height: 6)
                    Text("An toàn • Không can thiệp game")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }

            Text("Tự động phân tích góc, gió và khoảng cách từ màn hình để vẽ đường cong parabol cùng vạch lực bắn chuẩn xác qua cửa sổ nổi Picture-in-Picture.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 6)

            // Thẻ hướng dẫn 3 bước siêu gọn.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    stepPill("1. Căn khung Minimap")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    stepPill("2. Bấm Phát màn hình")
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    stepPill("3. Bấm Bật Ngắm & Vào Game", highlight: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func stepPill(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(highlight ? neonGreen : Color.white.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(highlight ? neonGreen.opacity(0.14) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 2. Nửa dưới: Khu vực Điều khiển tinh gọn (Duy nhất 3 nút bấm)

    private var compactControlButtonsSection: some View {
        VStack(spacing: 12) {
            // Nút 1 (Nền tối viền sáng): Căn khung Minimap & Gió
            Button {
                isShowingCalibrator = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "crop")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Căn khung Minimap & Gió")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(red: 0.09, green: 0.11, blue: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.32), lineWidth: 1.2)
                )
            }

            // Nút 2 (Nền xanh dương): Bật Phát Màn Hình (ReplayKit) phủ toàn bộ nút
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.44, blue: 0.94), Color(red: 0.05, green: 0.32, blue: 0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.cyan.opacity(0.45), lineWidth: 1)
                    )

                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text("Bật Phát Màn Hình (ReplayKit)")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .allowsHitTesting(false)

                BroadcastPickerView(preferredExtension: "com.gunny.pipcalc.BroadcastExtension")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.02)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Nút 3 (Nút chính nổi bật màu xanh lá neon): Bật Ngắm & Chuyển Sang Gunny Mobi
            Button {
                launchAimAndSwitchToGame()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 19, weight: .heavy))
                    Text("Bật Ngắm & Chuyển Sang Gunny Mobi")
                        .font(.system(size: 16, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    LinearGradient(
                        colors: [neonGreen, Color(red: 0.0, green: 0.84, blue: 0.44)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .shadow(color: neonGreen.opacity(0.38), radius: 14, y: 4)
            }
        }
    }

    // MARK: - Actions

    private func launchAimAndSwitchToGame() {
        pipManager.startPiP()

        let rawScheme = viewModel.ballisticsConfig.gameURLScheme
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !rawScheme.isEmpty, let url = URL(string: rawScheme) else {
                launchFailureMessage = "URL Scheme không hợp lệ. Bạn có thể gạt thanh Home để tự chuyển sang Gunny Mobi hoặc chỉnh lại URL Scheme trong mục Cài đặt."
                return
            }

            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    DispatchQueue.main.async {
                        launchFailureMessage = "Không mở được game bằng scheme \"\(rawScheme)\". Hãy gạt thanh Home để chuyển sang Gunny Mobi hoặc nhập URL Scheme tùy chỉnh trong Cài đặt."
                    }
                }
            }
        }
    }
}

// MARK: - Cửa sổ cài đặt phụ (Mở từ nút bánh răng góc trên bên phải)

private struct QuickSettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: GunnyCalcViewModel

    private let presetAngles: [Double] = [20, 30, 50, 65]
    private let presetURLSchemes: [String] = ["gunnymobi://", "vnggunny://", "garena://"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Góc bắn mặc định") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presetAngles, id: \.self) { angle in
                                let isSelected = !viewModel.ballisticsConfig.useOCRAngle
                                    && abs(viewModel.ballisticsConfig.selectedAngle - angle) < 0.1
                                Button {
                                    viewModel.selectFixedAngle(angle)
                                } label: {
                                    Text("\(Int(angle))°")
                                        .font(.subheadline.weight(.bold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(isSelected ? Color.orange : Color.white.opacity(0.10))
                                        .foregroundStyle(isSelected ? .black : .white)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                viewModel.enableOCRAngleMode()
                            } label: {
                                Text("Tự đọc OCR")
                                    .font(.subheadline.weight(.bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(viewModel.ballisticsConfig.useOCRAngle ? Color.cyan : Color.white.opacity(0.10))
                                    .foregroundStyle(viewModel.ballisticsConfig.useOCRAngle ? .black : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Hiệu chỉnh đạn đạo") {
                    sliderRow(
                        title: "Hệ số lực",
                        value: Binding(
                            get: { viewModel.ballisticsConfig.powerFactor },
                            set: {
                                viewModel.ballisticsConfig.powerFactor = $0
                                viewModel.persistAndRecalculate()
                            }
                        ),
                        range: 0.50...2.00,
                        format: "%.2fx",
                        tint: .green
                    )

                    sliderRow(
                        title: "Hệ số gió",
                        value: Binding(
                            get: { viewModel.ballisticsConfig.windFactor },
                            set: {
                                viewModel.ballisticsConfig.windFactor = $0
                                viewModel.persistAndRecalculate()
                            }
                        ),
                        range: 0.00...2.50,
                        format: "%.2fx",
                        tint: .cyan
                    )

                    sliderRow(
                        title: "Thời gian giữ Full 100",
                        value: Binding(
                            get: { viewModel.ballisticsConfig.maxHoldSeconds },
                            set: {
                                viewModel.ballisticsConfig.maxHoldSeconds = $0
                                viewModel.persistAndRecalculate()
                            }
                        ),
                        range: 1.00...4.00,
                        format: "%.2fs",
                        tint: .yellow
                    )
                }

                Section("URL Scheme mở game") {
                    TextField(
                        "gunnymobi://",
                        text: Binding(
                            get: { viewModel.ballisticsConfig.gameURLScheme },
                            set: {
                                viewModel.ballisticsConfig.gameURLScheme = $0
                                viewModel.saveConfigOnly()
                            }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .font(.system(.subheadline, design: .monospaced))

                    HStack(spacing: 8) {
                        ForEach(presetURLSchemes, id: \.self) { scheme in
                            let isSelected = viewModel.ballisticsConfig.gameURLScheme == scheme
                            Button {
                                viewModel.ballisticsConfig.gameURLScheme = scheme
                                viewModel.saveConfigOnly()
                            } label: {
                                Text(scheme)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.green.opacity(0.28) : Color.white.opacity(0.08))
                                    .foregroundStyle(isSelected ? Color.green : .secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Cài đặt nhanh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(tint)
            }
            Slider(value: value, in: range, step: 0.05)
                .tint(tint)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - RPSystemBroadcastPickerView Wrapper

struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String

    func makeUIView(context: Context) -> BroadcastPickerContainerView {
        BroadcastPickerContainerView(preferredExtension: preferredExtension)
    }

    func updateUIView(_ uiView: BroadcastPickerContainerView, context: Context) {
        uiView.picker.preferredExtension = preferredExtension
    }
}

final class BroadcastPickerContainerView: UIView {
    let picker: RPSystemBroadcastPickerView

    init(preferredExtension: String) {
        self.picker = RPSystemBroadcastPickerView(frame: .zero)
        super.init(frame: .zero)

        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        addSubview(picker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
        for subview in picker.subviews {
            subview.frame = picker.bounds
        }
    }
}
