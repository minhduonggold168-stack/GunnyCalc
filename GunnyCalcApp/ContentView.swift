import ReplayKit
import SwiftUI
import UIKit

/// Quản lý trạng thái dùng chung trên màn hình chính và đồng bộ hóa với `SharedIPC` + `PiPOverlayManager`.
@MainActor
final class GunnyCalcViewModel: ObservableObject {
    @Published var telemetry: TelemetryData
    @Published var ballisticsConfig: BallisticsConfig
    @Published var roiConfig: ROIConfig
    @Published var lastUpdatedText: String = "Chưa có khung hình ReplayKit"

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
        updateTimestampLabel(for: savedTelemetry)
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
            PiPOverlayManager.shared.updateTelemetry(telemetry)
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
        PiPOverlayManager.shared.updateTelemetry(updated)
    }

    private func applyTelemetry(_ latest: TelemetryData?) {
        guard let latest else { return }
        telemetry = latest
        updateTimestampLabel(for: latest)
        PiPOverlayManager.shared.updateTelemetry(latest)
    }

    private func updateTimestampLabel(for data: TelemetryData) {
        guard data.timestamp > 0 else {
            lastUpdatedText = "Chờ dữ liệu từ ReplayKit"
            return
        }
        let date = Date(timeIntervalSince1970: data.timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        lastUpdatedText = "Cập nhật lúc \(formatter.string(from: date))"
    }
}

/// Màn hình chính Dark Mode của `GunnyCalcApp`.
struct ContentView: View {
    @ObservedObject var viewModel: GunnyCalcViewModel
    @ObservedObject var pipManager: PiPOverlayManager = .shared

    @State private var isShowingCalibrator = false
    @State private var isSwitchGuideExpanded = true

    private let presetAngles: [Double] = [20, 30, 50, 65]

    var body: some View {
        NavigationStack {
            ZStack {
                // Giữ AVSampleBufferDisplayLayer trong cây view hoạt động để PiP chạy nền ổn định.
                PiPHostView(manager: pipManager)
                    .frame(width: 220, height: 74)
                    .opacity(0.01)
                    .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        activationSection
                        liveTelemetrySection
                        quickTuningSection
                        calibratorAndGuideSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
            .navigationTitle("GunnyCalc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("iOS 16 - 18.7+")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .sheet(isPresented: $isShowingCalibrator) {
                ROICalibratorView { updatedROI in
                    viewModel.roiConfig = updatedROI
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Khu vực kích hoạt

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Kích hoạt hỗ trợ", icon: "bolt.circle.fill", tint: .green)

            HStack(spacing: 10) {
                Button {
                    pipManager.togglePiP()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.subheadline.weight(.bold))
                        Text(pipManager.isPiPActive ? "Tắt Cửa Sổ PiP" : "Bật Cửa Sổ Nổi PiP")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(pipManager.isPiPActive ? Color.orange.opacity(0.25) : Color.green.opacity(0.24))
                    .foregroundStyle(pipManager.isPiPActive ? Color.orange : Color.green)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(pipManager.isPiPActive ? Color.orange.opacity(0.6) : Color.green.opacity(0.6), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Tích hợp RPSystemBroadcastPickerView ngay trong app.
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                        )

                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                            .font(.subheadline.weight(.bold))
                        Text("Phát màn hình")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(Color.cyan)
                    .allowsHitTesting(false)

                    BroadcastPickerView(preferredExtension: "com.gunny.pipcalc.BroadcastExtension")
                        .opacity(0.02)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let message = pipManager.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .cardStyle()
    }

    // MARK: - 2. Bảng hiển thị trực tiếp thông số

    private var liveTelemetrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(title: "Thông số thời gian thực", icon: "waveform.path.ecg", tint: .cyan)
                Spacer()
                Text(viewModel.lastUpdatedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                telemetryTile(
                    title: "LỰC BẮN",
                    value: String(format: "%.1f", viewModel.telemetry.calculatedPower),
                    unit: "/ 100",
                    accent: Color(red: 0.22, green: 0.88, blue: 0.56)
                )

                telemetryTile(
                    title: "THỜI GIAN GIỮ",
                    value: String(format: "%.2f", viewModel.telemetry.holdSeconds),
                    unit: "giây",
                    accent: Color(red: 1.0, green: 0.78, blue: 0.24)
                )

                telemetryTile(
                    title: "GIÓ",
                    value: String(format: "%@%.1f", viewModel.telemetry.wind > 0 ? "+" : "", viewModel.telemetry.wind),
                    unit: viewModel.telemetry.wind == 0 ? "lặng" : (viewModel.telemetry.wind > 0 ? "thuận/phải" : "ngược/trái"),
                    accent: .cyan
                )

                telemetryTile(
                    title: "GÓC BẮN",
                    value: String(format: "%.0f°", viewModel.telemetry.angle),
                    unit: viewModel.ballisticsConfig.useOCRAngle ? "Tự đọc OCR" : "Cố định",
                    accent: .orange
                )
            }

            HStack {
                Text(String(format: "dx: %.3f", viewModel.telemetry.dx))
                Spacer()
                Text(String(format: "dy: %.3f", viewModel.telemetry.dy))
                Spacer()
                Text("App Group: \(AppGroupConfig.suiteName)")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func telemetryTile(title: String, value: String, unit: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 3. Bộ điều chỉnh nhanh

    private var quickTuningSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "Bộ điều chỉnh nhanh", icon: "slider.horizontal.3", tint: .orange)

            VStack(alignment: .leading, spacing: 8) {
                Text("Chọn nhanh góc bắn")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

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
                                    .background(isSelected ? Color.orange : Color.white.opacity(0.08))
                                    .foregroundStyle(isSelected ? .black : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }

                        Button {
                            viewModel.enableOCRAngleMode()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.viewfinder")
                                Text("Tự đọc OCR")
                            }
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(viewModel.ballisticsConfig.useOCRAngle ? Color.cyan : Color.white.opacity(0.08))
                            .foregroundStyle(viewModel.ballisticsConfig.useOCRAngle ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.1))

            tuningSlider(
                title: "Hệ số lực",
                value: Binding(
                    get: { viewModel.ballisticsConfig.powerFactor },
                    set: {
                        viewModel.ballisticsConfig.powerFactor = $0
                        viewModel.persistAndRecalculate()
                    }
                ),
                range: 0.50...2.00,
                step: 0.05,
                format: "%.2fx",
                tint: .green
            )

            tuningSlider(
                title: "Hệ số gió",
                value: Binding(
                    get: { viewModel.ballisticsConfig.windFactor },
                    set: {
                        viewModel.ballisticsConfig.windFactor = $0
                        viewModel.persistAndRecalculate()
                    }
                ),
                range: 0.00...2.50,
                step: 0.05,
                format: "%.2fx",
                tint: .cyan
            )

            tuningSlider(
                title: "Thời gian giữ Full 100 (giây)",
                value: Binding(
                    get: { viewModel.ballisticsConfig.maxHoldSeconds },
                    set: {
                        viewModel.ballisticsConfig.maxHoldSeconds = $0
                        viewModel.persistAndRecalculate()
                    }
                ),
                range: 1.00...4.00,
                step: 0.05,
                format: "%.2fs",
                tint: .yellow
            )
        }
        .cardStyle()
    }

    private func tuningSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(tint)
            }
            Slider(value: value, in: range, step: step)
                .tint(tint)
        }
    }

    // MARK: - 4. Cấu hình ROI & Hướng dẫn Switch Control

    private var calibratorAndGuideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isShowingCalibrator = true
            } label: {
                HStack {
                    Image(systemName: "crop")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Căn chỉnh vùng nhận diện (ROI)")
                            .font(.subheadline.weight(.bold))
                        Text("Chọn ảnh chụp trận đấu để đặt khung Minimap, Gió, Góc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.07))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            DisclosureGroup(isExpanded: $isSwitchGuideExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    guideStep(number: "1", text: "Vào Cài đặt iPhone > Trợ năng > Điều khiển công tắc (Switch Control) > Công thức (Recipes).")
                    guideStep(number: "2", text: "Tạo công thức mới, gắn cử chỉ tùy chỉnh (Custom Gesture) nhấn giữ đúng vị trí nút Bắn trên màn hình game.")
                    guideStep(number: "3", text: "Đo thời gian nạp đầy thanh lực 100 trong game rồi chỉnh thanh \"Thời gian giữ Full 100\" tương ứng ở trên.")
                    guideStep(number: "4", text: "Bật PiP + Phát màn hình, vào trận và giữ nút Bắn theo đúng số giây hiển thị trên cửa sổ nổi.")
                }
                .padding(.top, 8)
            } label: {
                Label("Hướng dẫn nhanh Switch Control iOS", systemImage: "hand.tap.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .tint(.secondary)
        }
        .cardStyle()
    }

    private func guideStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.25))
                .foregroundStyle(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader(title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
        }
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

// MARK: - Card Styling

private extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(Color(red: 0.10, green: 0.11, blue: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}
