# PhotoMetaScrub — specification

**Tagline:** Drop photos to see their hidden EXIF, GPS and camera data, then strip it all before you share.

**Category:** Files & Conversion

**Inspired by (paid):** Metapho ($19.99 /year)

**Frameworks:** SwiftUI, AppKit, ImageIO, MapKit, UniformTypeIdentifiers, CoreLocation

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Metapho shows the metadata inside photos and lets you share a copy with all metadata stripped or only the location removed, on iPhone, iPad and Mac, sold as 19.99 per year or a larger one-time option. Privacy sites recommend it, and cheaper Mac App Store options such as EXIF Cleaner PRO also sell, because photos quietly carry GPS coordinates, camera serial numbers and timestamps. Our free version does the two core jobs locally: inspect and scrub.

Feature set for PhotoMetaScrub: a window app with a drop zone for one or many images (JPEG, HEIC, PNG, TIFF). Selecting an image shows grouped metadata in a readable list: File, Camera and Lens, Exposure, Date and Time, GPS, and Other. If GPS exists, a small map shows the pin and the address text. Scrub options are Remove Everything, Remove Location Only, and Custom, where the user toggles groups. Output either writes copies with a suffix to a chosen folder, or replaces the originals after a confirmation dialog, with a Trash backup. The image data is copied without recompression so there is no quality loss. A batch summary reports how many files had location data.

UI spec: a main window with a sidebar list of loaded files with thumbnails and a small pin icon for those that contain GPS, a detail pane with the metadata list and map, and a bottom bar with the scrub mode picker and Scrub button. Menu commands: Open, Remove Location From All, Scrub All, Copy Metadata as Text. Settings: default scrub mode, output suffix, output folder, replace originals toggle with confirm, and show map toggle. Empty state: Drop photos to see what they reveal. The Dock icon also accepts dropped files.

Technical approach: read with CGImageSourceCopyPropertiesAtIndex, which returns dictionaries for EXIF, TIFF, GPS, IPTC and maker notes. Display keys with friendly names mapped from the constant keys in ImageIO. Write cleaned copies using CGImageDestinationCreateWithURL, adding the source image with CGImageDestinationAddImageFromSource and passing a properties dictionary where removed keys are set to kCFNull so they are deleted, which keeps pixels untouched for JPEG and HEIC where supported. For location-only removal, delete the GPS dictionary and keep the others. Orientation is preserved by retaining the orientation property in all modes. The map uses MapKit Map with a Marker and CLGeocoder for the place name, with the geocoding clearly optional because it contacts Apple, so a toggle defaults to off and only the pin is shown. No special permissions beyond user-chosen files and output folders.

Edge cases and error handling: images without metadata show a friendly message. Unsupported formats are skipped with a note. If writing fails because the format cannot be rewritten without recompression, fall back to re-encoding at maximum quality and tell the user. Never overwrite originals without confirmation, and keep a backup in the Trash. Handle name collisions with a counter, large batches with progress, and read-only folders with an alert. Converting file dates is out of scope, but offer a toggle to reset the file modification date to now.
