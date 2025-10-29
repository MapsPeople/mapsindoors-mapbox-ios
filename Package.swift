// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let mapsindoorsVersion = Version("4.15.3-rc.1")

let package = Package(
    name: "MapsIndoorsMapbox",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "MapsIndoorsMapbox",
            targets: ["MapsIndoorsMapbox"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MapsPeople/mapsindoors-core-ios.git", exact: mapsindoorsVersion),
        .package(url: "https://github.com/mapbox/mapbox-maps-ios.git", exact: "11.13.5"),
    ],
    targets: [
        .target(
            name: "MapsIndoorsMapbox",
            dependencies: [
                .product(name: "MapsIndoorsCore", package: "mapsindoors-core-ios"),
                .product(name: "MapboxMaps", package: "mapbox-maps-ios"),
            ]
        ),
    ]
)
