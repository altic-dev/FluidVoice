import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image for the model in Command Mode, from a tool call or one the user attached, resized for the model.
/// Held in memory only; saved chats keep the text result without it.
nonisolated struct CommandImageAttachment: Equatable {
    let jpeg: Data
    let width: Int
    let height: Int

    var dataURL: String {
        "data:image/jpeg;base64,\(self.jpeg.base64EncodedString())"
    }

    enum LoadError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path): return "Couldn't read an image at \(path)."
            }
        }
    }

    /// Vision models downscale larger images anyway, so sending more only costs tokens.
    private static let maxLongEdge = 1568

    @concurrent
    static func load(path: String) async throws -> CommandImageAttachment {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable(path) }
        return try self.resized(source, name: path)
    }

    @concurrent
    static func load(data: Data) async throws -> CommandImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw LoadError.unreadable("the dropped image") }
        return try self.resized(source, name: "the dropped image")
    }

    private static func resized(_ source: CGImageSource, name: String) throws -> CommandImageAttachment {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: self.maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LoadError.unreadable(name)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LoadError.unreadable(name)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LoadError.unreadable(name) }
        return CommandImageAttachment(jpeg: data as Data, width: image.width, height: image.height)
    }
}
