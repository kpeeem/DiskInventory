// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskInventory",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DiskInventory", targets: ["DiskInventory"]),
        .executable(name: "inventorymcp", targets: ["inventorymcp"])
    ],
    targets: [
        .target(name: "InventoryCore"),
        .executableTarget(name: "DiskInventory", dependencies: ["InventoryCore"]),
        .executableTarget(name: "inventorymcp", dependencies: ["InventoryCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "InventoryCoreTests", dependencies: ["InventoryCore"]),
        .testTarget(name: "InventoryMCPTests", dependencies: ["inventorymcp", "InventoryCore"])
    ]
)
