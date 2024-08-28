// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let mapsindoorsVersion = Version("4.5.14")

let package = Package(
    name: "MapsIndoorsMapbox",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "MapsIndoorsMapbox",
            targets: ["MapsIndoorsMapbox"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MapsPeople/mapsindoors-core-ios.git", exact: mapsindoorsVersion),
        .package(url: "https://github.com/mapbox/mapbox-maps-ios.git", exact: "11.5.2"),
        .package(url: "https://github.com/brownsoo/ValueAnimator.git", from: "0.6.9")
    ],
    targets: [
        .target(
            name: "MapsIndoorsMapbox",
            dependencies: [
                .product(name: "MapsIndoorsCore", package: "mapsindoors-core-ios"),
                .product(name: "MapboxMaps", package: "mapbox-maps-ios"),
                .product(name: "ValueAnimator", package: "ValueAnimator")
            ]
        ),
    ]
)
