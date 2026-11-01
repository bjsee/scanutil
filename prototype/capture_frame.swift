// Nimmt ein einzelnes Frame im gewünschten UVC-Format auf und speichert es verlustfrei als PNG.
// Aufruf: capture_frame <Breite> <Höhe> <Ausgabedatei.png> [Frames_überspringen]
import AVFoundation
import CoreImage
import CoreMedia
import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let w = Int32(args[1]), let h = Int32(args[2]) else {
    FileHandle.standardError.write("Aufruf: capture_frame <Breite> <Höhe> <out.png> [skip]\n".data(using: .utf8)!); exit(2)
}
let outPath = args[3]
let skip = args.count > 4 ? Int(args[4]) ?? 3 : 3

func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
    sem.wait()
case .denied, .restricted: fail("Kamerazugriff verweigert (Systemeinstellungen > Datenschutz > Kamera)")
default: break
}

let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
guard let dev = found.first(where: { $0.modelID.contains("VendorID_1276") && $0.modelID.contains("ProductID_25395") }) else { fail("CZUR nicht gefunden") }
guard let fmt = dev.formats.first(where: {
    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width == w && d.height == h
}) else { fail("Format \(w)x\(h) nicht verfügbar") }

let session = AVCaptureSession()
session.beginConfiguration()
let input = try AVCaptureDeviceInput(device: dev)
guard session.canAddInput(input) else { fail("Input nicht hinzufügbar") }
session.addInput(input)
let output = AVCaptureVideoDataOutput()
guard session.canAddOutput(output) else { fail("Output nicht hinzufügbar") }
session.addOutput(output)
session.commitConfiguration()
try dev.lockForConfiguration()
dev.activeFormat = fmt
dev.unlockForConfiguration()

final class Grab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var n = 0; let skip: Int; let sem = DispatchSemaphore(value: 0); var buf: CVPixelBuffer?
    init(skip: Int) { self.skip = skip }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        n += 1
        if n > skip, buf == nil, let pb = CMSampleBufferGetImageBuffer(sb) { buf = pb; sem.signal() }
    }
}
let grab = Grab(skip: skip)
output.setSampleBufferDelegate(grab, queue: DispatchQueue(label: "grab"))
func fmtStr(_ f: AVCaptureDevice.Format) -> String {
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription); return "\(d.width)x\(d.height)"
}
print("activeFormat vor Start: \(fmtStr(dev.activeFormat))")
session.startRunning()
print("activeFormat nach Start: \(fmtStr(dev.activeFormat))")
if dev.activeFormat != fmt {
    try dev.lockForConfiguration(); dev.activeFormat = fmt; dev.unlockForConfiguration()
    Thread.sleep(forTimeInterval: 1.0)
    print("activeFormat nach erneutem Setzen: \(fmtStr(dev.activeFormat)) session.preset=\(session.sessionPreset.rawValue)")
}
if grab.sem.wait(timeout: .now() + 30) == .timedOut { session.stopRunning(); fail("Timeout: kein Frame erhalten") }
session.stopRunning()

let pb = grab.buf!
let sub = CVPixelBufferGetPixelFormatType(pb)
print("Pixelbuffer: \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fourcc=0x\(String(sub, radix: 16)) Frames bis Treffer=\(grab.n)")
let ci = CIImage(cvPixelBuffer: pb)
let ctx = CIContext()
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
try ctx.writePNGRepresentation(of: ci, to: URL(fileURLWithPath: outPath), format: .RGBA8, colorSpace: cs)
print("gespeichert: \(outPath)")
