import CoreLocation
import MapKit
import SwiftUI

/// Shows one photo's grouped metadata, plus a map when it carries GPS coordinates.
struct DetailView: View {
    let item: PhotoItem
    @AppStorage(Prefs.showMap) private var showMap = true

    var body: some View {
        List {
            if !item.hasMetadata {
                Label("No hidden metadata found — this photo is already clean.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            }
            if let coordinate = item.coordinate, showMap {
                Section("Location") {
                    LocationMap(coordinate: coordinate).id(item.id)
                }
            }
            ForEach(MetadataGroup.allCases) { group in
                if let entries = item.groups[group], !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            LabeledContent(entry.label) {
                                Text(entry.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                            }
                        }
                    } header: {
                        Label(group.rawValue, systemImage: group.symbol)
                    }
                }
            }
        }
        .navigationTitle(item.name)
    }
}

/// Small map with a pin; reverse-geocodes the address only when the user opted in (it contacts Apple).
struct LocationMap: View {
    let coordinate: CLLocationCoordinate2D
    @AppStorage(Prefs.lookUpAddress) private var lookUpAddress = false
    @State private var address: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500,
                                                            longitudinalMeters: 1500))) {
                Marker("Photo", coordinate: coordinate)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                .font(.caption.monospacedDigit()).textSelection(.enabled)
            if lookUpAddress {
                Text(address ?? "Looking up address…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: lookUpAddress) {
            guard lookUpAddress, address == nil else { return }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            address = placemark.map {
                [$0.name, $0.locality, $0.administrativeArea, $0.country].compactMap { $0 }.joined(separator: ", ")
            } ?? "Address unavailable"
        }
    }
}
