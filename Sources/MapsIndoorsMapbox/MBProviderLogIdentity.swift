import Foundation
import MapboxMaps
import MapsIndoorsCore

/// Identity sent to `MPLogger` by the MapsIndoors Mapbox provider so uploaded
/// log packages are tagged with Mapbox as the active map framework and the
/// Mapbox SDK version currently linked into the host app.
struct MBProviderLogIdentity: MPMapProviderLogIdentity {
    let component = "iOS Mapbox"

    let componentVersion: String = {
        // Bundle(for:) on a pure-Swift class returns the framework bundle when
        // Mapbox is linked dynamically (the common SPM case). With static
        // linking it can fall through to Bundle.main, which would report the
        // host app's version instead of Mapbox's — guard against that.
        let bundle = Bundle(for: MapView.self)
        guard bundle != Bundle.main,
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else { return "unknown" }
        return version
    }()
}
