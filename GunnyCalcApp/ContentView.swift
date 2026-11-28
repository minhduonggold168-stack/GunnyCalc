import ReplayKit
import SwiftUI
import UIKit

/// Giao diện tối giản tuyệt đối: nền tối, trạng thái nhận khung hình/giây (FPS) thời gian thực và đúng 2 nút bấm lớn.
struct ContentView: View {
    @ObservedObject var pipManager: PiPOverlayManager = .shared

    private let neonGreen = Color(red: 0.0, green: 1.0, blue: 0.533)

    var body: some View {
        ZStack {
            // Giữ AVSampleBufferDisplayLayer gắn trong cây view hoạt động để PiP chạy nền ổn định (tỉ lệ 320x72).
            PiPHostView(manager: pipManager)
                .frame(width: 160, height: 36)
                .opacity(0.01)
                .allowsHitTesting(false)

            Color(red: 0.03, green: 0.04, blue: 0.07)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                statusIndicatorView

                Spacer()

                VStack(spacing: 14) {
                    // Nút 1: Nút SwiftUI "1. Bật Đọc Màn Hình" kích hoạt trực tiếp UIButton bên trong RPSystemBroadcastPickerView.
                    BroadcastStartButton()
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Nút 2: "2. Bật Khung Ngắm Thời Gian Thực" (kích hoạt âm thanh câm giữ chạy nền + mở PiP ngay).
                    Button {
                        pipManager.startRealTimeAimPiP()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "pip.enter")
                                .font(.system(size: 20, weight: .heavy))
                            Text("2. Bật Khung Ngắm Thời Gian Thực")
                                .font(.system(size: 17, weight: .heavy))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                        .background(
                            LinearGradient(
                                colors: [neonGreen, Color(red: 0.0, green: 0.82, blue: 0.44)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: neonGreen.opacity(0.38), radius: 14, y: 4)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 32)
        }
        .preferredColorScheme(.dark)
    }

    private var statusIndicatorView: some View {
        let isLive = pipManager.isReceivingLiveStream
        let accentColor = isLive ? neonGreen : Color.yellow

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accentColor.opacity(0.32), .clear],
                            center: .center,
                            startRadius: 6,
                            endRadius: 56
                        )
                    )
                    .frame(width: 112, height: 112)

                Circle()
                    .fill(Color(red: 0.08, green: 0.11, blue: 0.16))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .stroke(accentColor.opacity(0.75), lineWidth: 1.5)
                    )

                Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(spacing: 6) {
                Text("GunnyCalc")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)

                    Text(
                        isLive
                            ? "Đang nhận: \(pipManager.liveFPS) khung hình/giây • #\(pipManager.latestFrameId)"
                            : "Chờ luồng màn hình (\(pipManager.liveFPS) khung hình/giây)"
                    )
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(accentColor.opacity(0.35), lineWidth: 1)
                )
            }

            if let message = pipManager.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - RPSystemBroadcastPickerView Wrapper (iOS 18 + Sideloadly Safe)

private final class BroadcastPickerBridge: ObservableObject {
    weak var pickerView: RPSystemBroadcastPickerView?

    func triggerPicker() {
        guard let pickerView,
              let button = Self.findButton(in: pickerView)
        else {
            return
        }
        button.sendActions(for: .touchUpInside)
    }

    private static func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview) {
                return found
            }
        }
        return nil
    }
}

private struct BroadcastStartButton: View {
    @StateObject private var bridge = BroadcastPickerBridge()

    var body: some View {
        ZStack {
            BroadcastPickerButton(bridge: bridge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.02)
                .allowsHitTesting(false)

            Button {
                bridge.triggerPicker()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.09, green: 0.44, blue: 0.94), Color(red: 0.05, green: 0.30, blue: 0.76)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.cyan.opacity(0.55), lineWidth: 1.2)
                        )

                    HStack(spacing: 10) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                        Text("1. Bật Đọc Màn Hình")
                            .font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
    }
}

struct BroadcastPickerButton: UIViewRepresentable {
    fileprivate let bridge: BroadcastPickerBridge

    func makeUIView(context: Context) -> BroadcastPickerContainerView {
        let preferredExtension = Self.resolvePreferredExtension()
        let container = BroadcastPickerContainerView(preferredExtension: preferredExtension)
        bridge.pickerView = container.picker
        return container
    }

    func updateUIView(_ uiView: BroadcastPickerContainerView, context: Context) {
        uiView.picker.preferredExtension = Self.resolvePreferredExtension()
        uiView.picker.showsMicrophoneButton = false
        bridge.pickerView = uiView.picker
    }

    static func resolvePreferredExtension() -> String {
        "\(Bundle.main.bundleIdentifier ?? "com.gunny.pipcalc").BroadcastExtension"
    }
}

final class BroadcastPickerContainerView: UIView {
    let picker: RPSystemBroadcastPickerView

    init(preferredExtension: String?) {
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
