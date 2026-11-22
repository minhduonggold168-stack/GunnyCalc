# GunnyCalc - Kế Hoạch Kiến Trúc & Quy Chuẩn Kỹ Thuật (iOS 16.0 - 18.7+)

## 1. Tổng quan dự án (Project Overview)
- **Tên dự án:** `GunnyCalc`
- **Bundle ID gốc:** `com.gunny.pipcalc`
- **App Group dùng chung:** `group.com.gunny.pipcalc`
- **Phiên bản iOS hỗ trợ:** Tương thích hoàn toàn từ **iOS 16.0 đến iOS 18.7+** (iPhone).
- **Công cụ quản lý dự án:** `XcodeGen` (`project.yml`) + GitHub Actions CI/CD (`.github/workflows/build-ipa.yml`).
- **Mô hình hoạt động:**
  1. **BroadcastExtension** (`ReplayKit` - `RPBroadcastSampleHandler`) nhận khung hình màn hình thụ động từ hệ thống iOS.
  2. Khung hình được cắt theo các vùng ROI chuẩn hóa (`0.0 - 1.0`) bằng `CoreGraphics` và nhận diện ký tự/chỉ số (gió, góc, lực, thước bản đồ) bằng `Vision`.
  3. Kết quả được đồng bộ hóa tức thời qua App Group `group.com.gunny.pipcalc`.
  4. **GunnyCalcApp** tính toán thông số bắn và hiển thị kết quả lên cửa sổ nổi Picture-in-Picture (`AVKit` / `AVFoundation`) để người dùng quan sát trực tiếp khi chơi game.

---

## 2. Các quy tắc ràng buộc bắt buộc (Mandatory Constraints)

> [!IMPORTANT]
> Mọi thay đổi mã nguồn và kiến trúc trong dự án **BẮT BUỘC** phải tuân thủ nghiêm ngặt các quy tắc dưới đây.

### 2.1. Chỉ sử dụng Framework chính thức của Apple
Dự án chỉ được phép import và sử dụng các framework gốc do Apple cung cấp:
- `SwiftUI` (Giao diện ứng dụng chính và công cụ căn chỉnh ROI)
- `ReplayKit` (Thu nhận khung hình màn hình thông qua Broadcast Upload Extension)
- `Vision` (Nhận diện văn bản / chỉ số OCR trên ảnh cắt từ màn hình)
- `AVKit` & `AVFoundation` (Quản lý phiên chạy nền và hiển thị cửa sổ nổi Picture-in-Picture)
- `CoreGraphics` (Thao tác cắt ảnh, chuyển đổi tọa độ và xử lý buffer nhẹ)

### 2.2. Tuyệt đối không dùng OpenCV & Giới hạn RAM dưới 25MB
- **Cấm tuyệt đối** tích hợp `OpenCV` hay bất kỳ thư viện xử lý ảnh bên thứ ba nặng nề nào.
- iOS áp đặt giới hạn bộ nhớ cực kỳ khắt khe (Jetsam limit ~50MB, thực tế an toàn cần giữ dưới **25MB**) đối với **Broadcast Upload Extension**. Nếu vượt ngưỡng, hệ điều hành sẽ ép tắt Extension ngay lập tức.
- Mọi thao tác xử lý khung hình trong `BroadcastExtension` phải giải phóng bộ nhớ tức thì (sử dụng `autoreleasepool`, giảm tần suất lấy mẫu khung hình hợp lý, tránh cấp phát `UIImage`/`CIImage` dư thừa).

### 2.3. Không dùng Private API & Không can thiệp Game
- **Tuyệt đối không sử dụng Private API** của Apple (đảm bảo tính ổn định xuyên suốt các bản cập nhật từ iOS 16.0 đến iOS 18.7+ và an toàn khi cài đặt/ký IPA).
- **Không can thiệp tiến trình hay gói tin mạng của game:** Không đọc/ghi bộ nhớ tiến trình khác (memory hook/injection), không thiết lập VPN/proxy nội bộ để bắt hay sửa gói tin mạng. Ứng dụng hoạt động hoàn toàn thụ động thông qua luồng hình ảnh ReplayKit do người dùng chủ động cấp quyền quay màn hình.

### 2.4. Tọa độ vùng cắt (ROI) chuẩn hóa (`0.0 - 1.0`)
- Mọi vùng nhận diện (Region of Interest - ROI) như vùng chỉ số gió, góc bắn, thanh lực, bản đồ nhỏ đều phải được lưu trữ dưới dạng **tỉ lệ chuẩn hóa `0.0 - 1.0`** theo chiều rộng và chiều cao của khung hình (`NormalizedROI`).
- Không lưu tọa độ pixel cứng (hardcoded pixels) nhằm đảm bảo hoạt động chính xác trên mọi kích thước màn hình và độ phân giải iPhone (từ iPhone SE, dòng tiêu chuẩn, Plus, đến Pro/Pro Max qua các thế hệ).

---

## 3. Cấu trúc thư mục & Targets

```text
GunnyCalc/
├── PLAN.md                                      # Tài liệu kiến trúc & ràng buộc bắt buộc
├── project.yml                                  # Cấu hình XcodeGen sinh GunnyCalc.xcodeproj
├── .github/
│   └── workflows/
│       └── build-ipa.yml                        # Workflow CI/CD build & đóng gói GunnyCalc.ipa
├── Shared/                                      # Mã nguồn dùng chung giữa 2 targets
│   ├── Models.swift                             # NormalizedRect, ROIConfig, BallisticsConfig, TelemetryData
│   ├── SharedIPC.swift                          # App Group UserDefaults JSON + Darwin Notification Center
│   ├── VisionProcessor.swift                    # Cắt ROI CoreGraphics, tìm tâm HSV & OCR Vision (.fast)
│   └── BallisticsEngine.swift                   # Thuật toán ném xiên 2D & thời gian giữ lực bắn
├── GunnyCalcApp/                                # Target 1: Ứng dụng chính (com.gunny.pipcalc)
│   ├── GunnyCalcApp.swift                       # Entry point SwiftUI & lắng nghe Darwin IPC
│   ├── ContentView.swift                        # Giao diện Dark Mode điều khiển PiP, ReplayKit & thông số
│   ├── ROICalibratorView.swift                  # Công cụ chọn ảnh & kéo thả căn chỉnh vùng ROI (0.0 - 1.0)
│   ├── PiPOverlayManager.swift                  # Trình quản lý Picture-in-Picture (AVKit / CoreGraphics)
│   └── GunnyCalcApp.entitlements                # App Group: group.com.gunny.pipcalc
└── BroadcastExtension/                          # Target 2: App Extension (com.gunny.pipcalc.BroadcastExtension)
    ├── SampleHandler.swift                      # RPBroadcastSampleHandler xử lý buffer & Vision OCR
    └── BroadcastExtension.entitlements          # App Group: group.com.gunny.pipcalc
```

### Chi tiết Targets
1. **Target 1: `GunnyCalcApp`**
   - **Type:** `application` (`com.gunny.pipcalc`), Deployment Target: `iOS 16.0`.
   - **Background Modes:** `audio`, `picture-in-picture` (duy trì hoạt động PiP liên tục khi chuyển sang game).
   - **Quyền truy cập:** `NSPhotoLibraryUsageDescription` để người dùng chọn ảnh chụp màn hình game thực tế phục vụ căn chỉnh các khung ROI chuẩn hóa.
   - **Liên kết:** Nhúng `BroadcastExtension`, sử dụng thư mục `Shared/` và `GunnyCalcApp.entitlements`.

2. **Target 2: `BroadcastExtension`**
   - **Type:** `app-extension` (`com.gunny.pipcalc.BroadcastExtension`), Deployment Target: `iOS 16.0`.
   - **Extension Point:** `com.apple.broadcast-services-upload`.
   - **Liên kết:** Sử dụng thư mục `Shared/` và `BroadcastExtension.entitlements`.
   - **Ràng buộc:** `APPLICATION_EXTENSION_API_ONLY = YES`, RAM luôn duy trì `< 25MB`.

---

## 4. Quy trình Build & Đóng gói (CI/CD)
- Workflow `.github/workflows/build-ipa.yml` chạy trên runner `macos-latest`:
  1. Cài đặt `xcodegen` thông qua Homebrew và thực thi `xcodegen generate`.
  2. Build scheme `GunnyCalcApp` (tự động nhúng `BroadcastExtension`) với cấu hình `Release`, SDK `iphoneos`, tham số `CODE_SIGNING_ALLOWED=NO`.
  3. Đóng gói `GunnyCalcApp.app` vào cấu trúc `Payload/GunnyCalcApp.app`, nén thành tệp `GunnyCalc.ipa` và tải lên GitHub Artifacts.
