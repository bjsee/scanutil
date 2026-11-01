// Fragt nur die von AVFoundation gemeldeten Fähigkeiten des CZUR ab (setzt nichts).
import AVFoundation
guard let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    .first(where: { $0.modelID.contains("VendorID_1276") }) else { print("CZUR nicht gefunden"); exit(1) }
print("Gerät:", d.localizedName)
for m in [AVCaptureDevice.ExposureMode.locked, .autoExpose, .continuousAutoExposure, .custom] { print("Belichtung \(m.rawValue): \(d.isExposureModeSupported(m))") }
for m in [AVCaptureDevice.FocusMode.locked, .autoFocus, .continuousAutoFocus] { print("Fokus \(m.rawValue): \(d.isFocusModeSupported(m))") }
for m in [AVCaptureDevice.WhiteBalanceMode.locked, .autoWhiteBalance, .continuousAutoWhiteBalance] { print("Weißabgleich \(m.rawValue): \(d.isWhiteBalanceModeSupported(m))") }
print("aktuell: Belichtung=\(d.exposureMode.rawValue) Fokus=\(d.focusMode.rawValue) WB=\(d.whiteBalanceMode.rawValue)")
