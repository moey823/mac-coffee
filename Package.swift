// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCoffee",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacCoffeeCore", targets: ["MacCoffeeCore"]),
        .executable(name: "MacCoffee", targets: ["MacCoffeeApp"]),
        .executable(name: "MacCoffeeLidAwakeHelper", targets: ["MacCoffeeLidAwakeHelper"])
    ],
    targets: [
        .target(name: "MacCoffeeCore"),
        .executableTarget(name: "MacCoffeeApp", dependencies: ["MacCoffeeCore"]),
        .executableTarget(name: "MacCoffeeLidAwakeHelper", dependencies: ["MacCoffeeCore"]),
        .testTarget(name: "MacCoffeeCoreTests", dependencies: ["MacCoffeeCore"])
    ]
)
