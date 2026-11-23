import ReplayKit
import SwiftUI
import UIKit

/// Giao diện tối giản tuyệt đối: nền tối, trạng thái nhận khung hình/giây (FPS) thời gian thực và đúng 2 nút bấm lớn.
struct ContentView: View {
    @ObservedObject var pipManager: PiPOverlayManager = .shared

    private let neonGreen = Color(red: 0.0, green: 1.0, blue: 0.533)

    var body: some View {
        ZStack {
            // Giữ AVSampleBufferDisplayLayer gắn trong cây view hoạt động để PiP chạy nền ổn định.
            PiPHostView(manager: pipManager)
                .frame(width: 240, height: 80)
                .opacity(0.01)
                .allowsHitTesting(false)

            Color(red: 0.03, green: 0.04, blue: 0.07)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                statusIndicatorView

                Spacer()

                VStack(spacing: 14) {
                    // Nút 1: RPSystemBroadcastPickerView phủ toàn bộ nút với nhãn "1. Bật Đọc Màn Hình".
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
                        .allowsHitTesting(false)

                        BroadcastPickerView(preferredExtension: "com.gunny.pipcalc.BroadcastExtension")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(0.02)
                    }
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
