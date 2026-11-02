// Spike: Dokumentrand (Vision) -> Perspektivkorrektur (Core Image) -> OCR und Winkelschätzung aus Textzeilen (Vision).
// Aufruf: spike_vision <eingabe.png> <ausgabe.png>
import Foundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 3 else { print("Aufruf: spike_vision <in> <out>"); exit(2) }
func t0() -> Date { Date() }
func ms(_ d: Date) -> String { String(format: "%.0f ms", -d.timeIntervalSinceNow * 1000) }

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("Bild nicht lesbar"); exit(1) }
let W = cg.width, H = cg.height
print("Eingabe \(W)x\(H)")

// 1) Dokumentsegmentierung
var t = t0()
let seg = VNDetectDocumentSegmentationRequest()
let h1 = VNImageRequestHandler(cgImage: cg, options: [:])
try h1.perform([seg])
print("Dokumentsegmentierung: \(ms(t))")
guard let obs = seg.results?.first else { print("kein Dokument erkannt"); exit(0) }
print(String(format: "  Konfidenz %.2f", obs.confidence))
func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * CGFloat(W), y: p.y * CGFloat(H)) }
let tl = px(obs.topLeft), tr = px(obs.topRight), bl = px(obs.bottomLeft), br = px(obs.bottomRight)
print("  Ecken (Pixel, Ursprung unten links): TL=\(tl) TR=\(tr) BL=\(bl) BR=\(br)")
let angTop = atan2(tr.y - tl.y, tr.x - tl.x) * 180 / .pi
print(String(format: "  Neigung der Oberkante laut Quadrat: %.2f°", angTop))

// 2) Perspektivkorrektur
t = t0()
let ci = CIImage(cgImage: cg)
let f = CIFilter(name: "CIPerspectiveCorrection")!
f.setValue(ci, forKey: kCIInputImageKey)
f.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft"); f.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
f.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft"); f.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
guard let outCI = f.outputImage else { print("Korrektur fehlgeschlagen"); exit(1) }
let ctx = CIContext()
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
try ctx.writePNGRepresentation(of: outCI, to: URL(fileURLWithPath: a[2]), format: .RGBA8, colorSpace: cs)
print("Perspektivkorrektur+Schreiben: \(ms(t)) -> \(Int(outCI.extent.width))x\(Int(outCI.extent.height))")

// 3) OCR auf dem korrigierten Bild und Winkelschätzung aus den Zeilen
t = t0()
guard let outCG = ctx.createCGImage(outCI, from: outCI.extent) else { exit(1) }
let ocr = VNRecognizeTextRequest()
ocr.recognitionLevel = .accurate
ocr.recognitionLanguages = ["de-DE"]
ocr.usesLanguageCorrection = true
try VNImageRequestHandler(cgImage: outCG, options: [:]).perform([ocr])
let lines = ocr.results ?? []
print("OCR: \(ms(t)), \(lines.count) Zeilen")
var angles: [Double] = []
for l in lines {
    guard let c = l.topCandidates(1).first, let r = try? c.boundingBox(for: c.string.startIndex..<c.string.endIndex) else { continue }
    let dx = Double(r.topRight.x - r.topLeft.x) * Double(outCG.width), dy = Double(r.topRight.y - r.topLeft.y) * Double(outCG.height)
    if dx > 100 { angles.append(atan2(dy, dx) * 180 / .pi) }
}
if !angles.isEmpty {
    let s = angles.sorted(); let med = s[s.count/2]
    print(String(format: "Zeilenwinkel: Median %.2f°, min %.2f°, max %.2f° (n=%d)", med, s.first!, s.last!, s.count))
}
// 4) Nachdrehen um den gemessenen Zeilenwinkel und erneut messen (beide Vorzeichen, das bessere zählt)
func lineAngle(_ img: CGImage) throws -> (Double, Int) {
    let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.recognitionLanguages = ["de-DE"]
    try VNImageRequestHandler(cgImage: img, options: [:]).perform([r])
    var v: [Double] = []
    for l in r.results ?? [] {
        guard let c = l.topCandidates(1).first, let b = try? c.boundingBox(for: c.string.startIndex..<c.string.endIndex) else { continue }
        let dx = Double(b.topRight.x - b.topLeft.x) * Double(img.width), dy = Double(b.topRight.y - b.topLeft.y) * Double(img.height)
        if dx > 100 { v.append(atan2(dy, dx) * 180 / .pi) }
    }
    guard !v.isEmpty else { return (0, 0) }
    return (v.sorted()[v.count/2], v.count)
}
if let med = angles.sorted().dropFirst(angles.count/2).first, abs(med) > 0.2 {
    var best: (Double, CGImage?, Double)? = nil
    for sign in [-1.0, 1.0] {
        let st = CIFilter(name: "CIStraightenFilter")!
        st.setValue(outCI, forKey: kCIInputImageKey); st.setValue(sign * med * .pi / 180, forKey: kCIInputAngleKey)
        guard let rot = st.outputImage, let rcg = ctx.createCGImage(rot, from: rot.extent) else { continue }
        let (res, _) = try lineAngle(rcg)
        print(String(format: "Nachdrehen mit %+.2f° -> Restwinkel %.2f°", sign * med, res))
        if best == nil || abs(res) < abs(best!.2) { best = (sign * med, rcg, res) }
    }
    if let b = best, let img = b.1 {
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2].replacingOccurrences(of: ".png", with: "_deskew.png")) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        print(String(format: "Deskew: gedreht um %+.2f°, Restwinkel %.2f°", b.0, b.2))
    }
}
if let path = ProcessInfo.processInfo.environment["OCR_OUT"] {
    let txt = lines.compactMap { l -> String? in
        guard let c = l.topCandidates(1).first else { return nil }
        return String(format: "%.3f %.3f %.3f %.3f\t%@", l.boundingBox.minX, l.boundingBox.minY, l.boundingBox.width, l.boundingBox.height, c.string)
    }.joined(separator: "\n")
    try? txt.write(toFile: path, atomically: true, encoding: .utf8)
}
let conf = lines.compactMap { $0.topCandidates(1).first?.confidence }
if !conf.isEmpty { print(String(format: "OCR-Konfidenz: Mittel %.2f", conf.reduce(0, +) / Float(conf.count))) }
for l in lines.prefix(6) { if let c = l.topCandidates(1).first { print("  »\(c.string)«") } }
