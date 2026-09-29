// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public enum ScreenshotError: Error, Sendable {
    case noPicture
    case convert(OSStatus)
    case write
}

/// Still pictures as PNG, in square pixels at the picture's 4:3 shape
public enum Screenshot {
    /// Converts a displayed picture: its 704-sample 4:3 area (the clean
    /// aperture) is scaled by the pixel aspect ratio to 640×480 (768×576 for
    /// 625 lines) and converted from BT.601 to sRGB
    public static func image(from picture: CVPixelBuffer) throws -> CGImage {
        let height = CVPixelBufferGetHeight(picture)
        let size = height > 480 ? (768, 576) : (640, 480)
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var st = CVPixelBufferCreate(nil, size.0, size.1, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        guard st == kCVReturnSuccess, let out else { throw ScreenshotError.convert(st) }

        var session: VTPixelTransferSession?
        st = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard st == noErr, let session else { throw ScreenshotError.convert(st) }
        defer { VTPixelTransferSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationPixelAspectRatio, value: [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1,
        ] as CFDictionary)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                             value: kCVImageBufferTransferFunction_sRGB)
        st = VTPixelTransferSessionTransferImage(session, from: picture, to: out)
        guard st == noErr else { throw ScreenshotError.convert(st) }

        var image: CGImage?
        st = VTCreateCGImageFromCVPixelBuffer(out, options: nil, imageOut: &image)
        guard st == noErr, let image else { throw ScreenshotError.convert(st) }
        // BT.709 primaries with the sRGB curve is sRGB
        return image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? image
    }

    public static func writePNG(_ picture: CVPixelBuffer, to url: URL) throws {
        let image = try image(from: picture)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.write
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ScreenshotError.write }
    }
}
