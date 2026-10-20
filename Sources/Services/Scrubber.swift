import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How much metadata to strip.
enum ScrubMode: String, CaseIterable, Identifiable {
    case everything, locationOnly, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: "Remove Everything"
        case .locationOnly: "Remove Location Only"
        case .custom: "Custom"
        }
    }

    func groupsToRemove(custom: Set<MetadataGroup>) -> Set<MetadataGroup> {
        switch self {
        case .everything: Set(MetadataGroup.removable)
        case .locationOnly: [.gps]
        case .custom: custom
        }
    }
}

/// Where cleaned files go.
enum ScrubDestination {
    case folder(URL, suffix: String)
    case replaceOriginals
}

/// Errors surfaced to the user in the batch summary.
enum ScrubError: LocalizedError {
    case unreadable, unwritable, readOnly(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read."
        case .unwritable: "The image could not be written in its original format."
        case .readOnly(let folder): "The folder “\(folder)” is read-only."
        }
    }
}

/// Writes metadata-stripped copies of images via ImageIO, without recompression whenever possible.
enum Scrubber {
    /// Processes one file. Returns true when a lossy image had to be re-encoded (lossless copy unsupported).
    static func process(_ url: URL, removing: Set<MetadataGroup>, to destination: ScrubDestination,
                        resetModificationDate: Bool) throws -> Bool {
        let fm = FileManager.default
        let originalDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let output: URL
        let reencoded: Bool

        switch destination {
        case let .folder(folder, suffix):
            guard fm.isWritableFile(atPath: folder.path) else { throw ScrubError.readOnly(folder.lastPathComponent) }
            output = uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent + suffix,
                               ext: url.pathExtension)
            reencoded = try write(from: url, to: output, removing: removing)
        case .replaceOriginals:
            let parent = url.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: parent.path) else { throw ScrubError.readOnly(parent.lastPathComponent) }
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            defer { try? fm.removeItem(at: temp) }
            reencoded = try write(from: url, to: temp, removing: removing)
            try fm.trashItem(at: url, resultingItemURL: nil) // backup of the original
            try fm.moveItem(at: temp, to: url)
            output = url
        }

        let date = resetModificationDate ? Date() : (originalDate ?? Date())
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: output.path)
        return reencoded
    }

    /// Writes `source` to `dest` with the given groups removed.
    static func write(from sourceURL: URL, to dest: URL, removing: Set<MetadataGroup>) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw ScrubError.unreadable }
        let count = CGImageSourceGetCount(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // 1) Lossless: copy compressed image data and replace the metadata block. ImageIO may report
        //    success yet keep some blocks (e.g. EXIF in PNG/TIFF), so the result is re-read and verified.
        if let dst = CGImageDestinationCreateWithURL(dest as CFURL, type, count, nil) {
            var options: [CFString: Any] = [
                kCGImageDestinationMetadata: filteredMetadata(source, removing: removing),
                kCGImageDestinationMergeMetadata: false,
            ]
            if removing.contains(.gps) { options[kCGImageMetadataShouldExcludeGPS] = true }
            if CGImageDestinationCopyImageSource(dst, source, options as CFDictionary, nil),
               isClean(dest, removing: removing) { return false }
        }

        // 2) Fallback: re-encode at maximum quality, nulling removed keys.
        try? FileManager.default.removeItem(at: dest)
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, type, count, nil) else {
            throw ScrubError.unwritable
        }
        var properties = nulledProperties(props, removing: removing)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        for index in 0..<count {
            CGImageDestinationAddImageFromSource(dst, source, index, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw ScrubError.unwritable }
        // Only lossy formats actually lose quality when rewritten.
        return [UTType.jpeg, .heic, .heif].contains { UTType(type as String)?.conforms(to: $0) == true }
    }

    /// True when the written file no longer contains any entries from the removed groups.
    private static func isClean(_ url: URL, removing: Set<MetadataGroup>) -> Bool {
        guard let item = MetadataReader.load(url) else { return false }
        return !removing.contains { !(item.groups[$0] ?? []).isEmpty }
    }

    /// Copies the source XMP/EXIF metadata, dropping tags in removed groups but always keeping orientation.
    private static func filteredMetadata(_ source: CGImageSource, removing: Set<MetadataGroup>) -> CGImageMetadata {
        guard let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let copy = CGImageMetadataCreateMutableCopy(original) else { return CGImageMetadataCreateMutable() }
        var doomed: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(original, nil, nil) { path, tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            let isOrientation = prefix == "tiff" && name == "Orientation"
            if !isOrientation, removing.contains(MetadataReader.classify(xmpPrefix: prefix, name: name)) {
                doomed.append(path as String)
            }
            return true
        }
        for path in doomed { CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString) }
        return copy
    }

    /// Builds a properties dictionary where removed keys/dictionaries are set to kCFNull.
    private static func nulledProperties(_ props: [String: Any], removing: Set<MetadataGroup>) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in props {
            guard let dict = value as? [String: Any] else { continue }
            var cleaned: [String: Any] = [:]
            for subKey in dict.keys where removing.contains(MetadataReader.classify(dictionary: key, key: subKey)) {
                cleaned[subKey] = kCFNull
            }
            if cleaned.count == dict.count { result[key] = kCFNull } else if !cleaned.isEmpty { result[key] = cleaned }
        }
        if let orientation = props[kCGImagePropertyOrientation as String] {
            result[kCGImagePropertyOrientation as String] = orientation
        }
        return result
    }

    /// "photo-clean.jpg", then "photo-clean 2.jpg", "photo-clean 3.jpg", …
    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
