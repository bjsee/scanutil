// Listet alle AVFoundation-Formate des CZUR (VID 04fc / PID 6333). Nimmt nichts auf.
import AVFoundation
import CoreMedia

let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external, .builtInWideAngleCamera],
    mediaType: .video, position: .unspecified)
for d in discovery.devices {
    print("== \(d.localizedName)  [\(d.modelID)]  uid=\(d.uniqueID)")
    guard d.modelID.contains("1276") || d.localizedName.contains("CZUR") else { continue }
    for (i, f) in d.formats.enumerated() {
        let desc = f.formatDescription
        let dim = CMVideoFormatDescriptionGetDimensions(desc)
        let sub = CMFormatDescriptionGetMediaSubType(desc)
        let fourcc = String(bytes: [UInt8((sub >> 24) & 255), UInt8((sub >> 16) & 255), UInt8((sub >> 8) & 255), UInt8(sub & 255)], encoding: .ascii) ?? "?"
        let fps = f.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator: ",")
        print("  #\(i) \(dim.width)x\(dim.height) \(fourcc) fps=\(fps)")
    }
}
