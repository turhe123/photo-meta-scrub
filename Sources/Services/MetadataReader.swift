import AppKit
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

/// The readable sections the metadata list is grouped into; also the unit of "Custom" scrubbing.
enum MetadataGroup: String, CaseIterable, Identifiable, Hashable {
    case file = "File", camera = "Camera & Lens", exposure = "Exposure"
    case dateTime = "Date & Time", gps = "GPS", other = "Other"

    var id: String { rawValue }

    /// Groups the user may strip (file-level facts such as pixel size are always kept).
    static let removable: [MetadataGroup] = [.camera, .exposure, .dateTime, .gps, .other]

    var symbol: String {
        switch self {
        case .file: "doc"
        case .camera: "camera"
        case .exposure: "camera.aperture"
        case .dateTime: "calendar"
        case .gps: "location"
        case .other: "ellipsis.circle"
        }
    }
}

/// A single label/value row shown in the metadata list.
struct MetadataEntry: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
}

/// A loaded photo: its location on disk, thumbnail and grouped metadata.
struct PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage?
    let groups: [MetadataGroup: [MetadataEntry]]
    let coordinate: CLLocationCoordinate2D?

    var name: String { url.lastPathComponent }
    var hasGPS: Bool { coordinate != nil || !(groups[.gps] ?? []).isEmpty }
    /// True when the photo carries anything beyond basic file facts.
    var hasMetadata: Bool { MetadataGroup.removable.contains { !(groups[$0] ?? []).isEmpty } }

    /// Plain-text dump used by "Copy Metadata as Text".
    var asText: String {
        var lines = [name]
        for group in MetadataGroup.allCases {
            guard let entries = groups[group], !entries.isEmpty else { continue }
            lines.append("\n[\(group.rawValue)]")
            lines += entries.map { "\($0.label): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Reads image properties through ImageIO and maps them into friendly, grouped entries.
enum MetadataReader {
    static let supportedTypes: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    /// Loads one photo; returns nil when ImageIO cannot open it.
    static func load(_ url: URL) -> PhotoItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        var groups: [MetadataGroup: [MetadataEntry]] = [:]
        func add(_ group: MetadataGroup, _ label: String, _ value: String) {
            groups[group, default: []].append(MetadataEntry(label: label, value: value))
        }

        add(.file, "Name", url.lastPathComponent)
        if let type = CGImageSourceGetType(source), let ut = UTType(type as String) {
            add(.file, "Format", ut.localizedDescription ?? ut.identifier)
        }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            add(.file, "File Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }

        for key in props.keys.sorted() {
            let value = props[key] as Any
            if let dict = value as? [String: Any] {
                for sub in dict.keys.sorted() {
                    guard let subValue = dict[sub], !(subValue is [String: Any]) else { continue }
                    add(classify(dictionary: key, key: sub), label(for: sub), format(subValue, key: sub))
                }
            } else {
                add(.file, label(for: key), format(value, key: key))
            }
        }

        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        return PhotoItem(url: url, thumbnail: thumbnail(source), groups: groups, coordinate: coordinate(from: gps))
    }

    // MARK: Classification

    private static let cameraKeys: Set<CFString> = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFHostComputer, kCGImagePropertyTIFFArtist,
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifBodySerialNumber,
        kCGImagePropertyExifCameraOwnerName,
    ]
    private static let exposureKeys: Set<CFString> = [
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
        kCGImagePropertyExifExposureProgram, kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifExposureMode,
        kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifFlash,
        kCGImagePropertyExifMeteringMode, kCGImagePropertyExifWhiteBalance, kCGImagePropertyExifShutterSpeedValue,
        kCGImagePropertyExifApertureValue, kCGImagePropertyExifBrightnessValue, kCGImagePropertyExifSceneType,
        kCGImagePropertyExifSceneCaptureType, kCGImagePropertyExifSensingMethod, kCGImagePropertyExifDigitalZoomRatio,
    ]
    private static let dateKeys: Set<CFString> = [
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyTIFFDateTime,
        kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifSubsecTimeDigitized,
        kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
        kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated, kCGImagePropertyIPTCDigitalCreationDate,
        kCGImagePropertyIPTCDigitalCreationTime,
        "CreateDate" as CFString, "ModifyDate" as CFString, "MetadataDate" as CFString,
    ]

    /// Technical keys needed to decode/display the image; they reveal nothing and are always kept.
    private static let structuralKeys: Set<CFString> = [
        kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace,
        kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
        kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
        kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
        kCGImagePropertyPNGGamma, kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGInterlaceType,
        kCGImagePropertyPNGsRGBIntent,
    ]

    /// Maps a key inside a property dictionary (e.g. "{Exif}") to its display group.
    static func classify(dictionary: String, key: String) -> MetadataGroup {
        let k = key as CFString
        if structuralKeys.contains(k) { return .file }
        switch dictionary as CFString {
        case kCGImagePropertyJFIFDictionary: return .file
        case kCGImagePropertyGPSDictionary: return .gps
        case kCGImagePropertyExifAuxDictionary: return .camera
        case kCGImagePropertyTIFFDictionary where k == kCGImagePropertyTIFFOrientation: return .file
        default:
            if cameraKeys.contains(k) { return .camera }
            if exposureKeys.contains(k) { return .exposure }
            if dateKeys.contains(k) { return .dateTime }
            return .other
        }
    }

    /// Maps an XMP tag (prefix + name) to the same groups used for property dictionaries.
    static func classify(xmpPrefix prefix: String, name: String) -> MetadataGroup {
        switch prefix {
        case "exif" where name.hasPrefix("GPS"): return .gps
        case "exif", "exifEX": return classify(dictionary: kCGImagePropertyExifDictionary as String, key: name)
        case "tiff": return classify(dictionary: kCGImagePropertyTIFFDictionary as String, key: name)
        case "aux": return .camera
        default: return dateKeys.contains(name as CFString) || name == "DateCreated" ? .dateTime : .other
        }
    }

    // MARK: Formatting

    private static let friendlyNames: [CFString: String] = [
        kCGImagePropertyPixelWidth: "Width (px)", kCGImagePropertyPixelHeight: "Height (px)",
        kCGImagePropertyDPIWidth: "Horizontal DPI", kCGImagePropertyDPIHeight: "Vertical DPI",
        kCGImagePropertyColorModel: "Color Model", kCGImagePropertyProfileName: "Color Profile",
        kCGImagePropertyDepth: "Bit Depth", kCGImagePropertyOrientation: "Orientation",
        kCGImagePropertyTIFFMake: "Camera Make", kCGImagePropertyTIFFModel: "Camera Model",
        kCGImagePropertyExifLensModel: "Lens", kCGImagePropertyExifBodySerialNumber: "Camera Serial Number",
        kCGImagePropertyExifISOSpeedRatings: "ISO", kCGImagePropertyExifFNumber: "Aperture",
        kCGImagePropertyExifFocalLenIn35mmFilm: "Focal Length (35mm)",
        kCGImagePropertyExifDateTimeOriginal: "Date Taken", kCGImagePropertyExifDateTimeDigitized: "Date Digitized",
        kCGImagePropertyTIFFDateTime: "Date Modified", kCGImagePropertyGPSHPositioningError: "Position Error (m)",
    ]

    /// Friendly label from ImageIO's constant keys, falling back to splitting CamelCase.
    static func label(for key: String) -> String {
        if let name = friendlyNames[key as CFString] { return name }
        var result = ""
        for (i, ch) in key.enumerated() {
            if i > 0, ch.isUppercase, let prev = result.last, prev.isLowercase { result.append(" ") }
            result.append(ch)
        }
        return result
    }

    static func format(_ value: Any, key: String) -> String {
        if let number = value as? Double {
            switch key as CFString {
            case kCGImagePropertyExifExposureTime where number > 0 && number < 1:
                return "1/\(Int((1 / number).rounded())) s"
            case kCGImagePropertyExifExposureTime: return "\(number) s"
            case kCGImagePropertyExifFNumber: return "f/\(number)"
            case kCGImagePropertyExifFocalLength: return "\(number) mm"
            default: break
            }
        }
        switch value {
        case let array as [Any]: return array.map { format($0, key: "") }.joined(separator: ", ")
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let data as Data: return "\(data.count) bytes"
        default: return String(describing: value)
        }
    }

    // MARK: Helpers

    private static func coordinate(from gps: [String: Any]?) -> CLLocationCoordinate2D? {
        guard let gps,
              var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return CLLocationCoordinate2DIsValid(coord) ? coord : nil
    }

    private static func thumbnail(_ source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
