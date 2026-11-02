import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGEncoding {
    /// Kodiert ein Bild verlustfrei als PNG.
    static func data(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScannerError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScannerError.encodingFailed }
        return data as Data
    }
}
