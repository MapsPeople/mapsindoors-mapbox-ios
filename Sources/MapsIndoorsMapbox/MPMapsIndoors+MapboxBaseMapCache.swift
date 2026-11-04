import Foundation
@_spi(Private) import MapsIndoors
@_spi(Private) import MapsIndoorsCore

extension MPMapsIndoors {
    /// Makes Mapbox base-map tile caching available before the first map is created.
    ///
    /// The SDK otherwise registers its Mapbox base-map cache when a Mapbox map provider is built,
    /// so until a map exists `MPDataSetCacheManager.synchronizeBaseMapTiles(progress:)` throws
    /// `MPError.baseMapCachingNotSupported` and `isBaseMapCachingSupported` is `false`. Call this
    /// first to cache ahead of time - from a home screen on Wi-Fi, say - so the map renders
    /// offline the first time it is opened (SPEX-2895).
    ///
    /// Downloads authenticate with `MapboxOptions.accessToken`, so set it before syncing.
    ///
    /// Until a map exists, the MapsIndoors Mapbox style is cached. A map provider created later
    /// replaces this registration with its own, which follows the style that map renders, so an
    /// app using its own style should create its map before syncing.
    ///
    /// Call it on the main thread: the Mapbox offline objects it creates belong to the thread that
    /// creates them, and the cache only uses them from the main thread. Safe to call repeatedly.
    /// Does nothing once a map provider has registered its own cache.
    @MainActor
    @objc public static func registerMapboxBaseMapCache() {
        registerBaseMapCacheProviderIfAbsent(MBBaseMapCacheProvider())
    }
}
