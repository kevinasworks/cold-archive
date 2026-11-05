// swift-tools-version: 6.0
// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription
let package = Package(name: "ColdArchive", platforms: [.macOS(.v14)], products: [.executable(name: "ColdArchive", targets: ["ColdArchive"])], targets: [.target(name: "NativeMonitor", linkerSettings: [.linkedLibrary("netsnmp")]), .executableTarget(name: "ColdArchive", dependencies: ["NativeMonitor"], resources: [.copy("Resources/Engine")], swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "ColdArchiveTests", dependencies: ["ColdArchive"], swiftSettings: [.swiftLanguageMode(.v5)])])
