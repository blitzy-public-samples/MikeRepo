// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WealthLedger",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "WealthLedgerApp", targets: ["WealthLedgerApp"]),
        .executable(name: "SeedTool", targets: ["SeedTool"]),
        .library(name: "AccountManagement", targets: ["AccountManagement"]),
        .library(name: "LedgerEngine", targets: ["LedgerEngine"]),
        .library(name: "ValuationEngine", targets: ["ValuationEngine"]),
        .library(name: "ReferenceDataService", targets: ["ReferenceDataService"]),
        .library(name: "JobScheduler", targets: ["JobScheduler"]),
        .library(name: "RBAC", targets: ["RBAC"]),
        .library(name: "UILayer", targets: ["UILayer"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Shared", targets: ["Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-kit.git", from: "4.9.0"),
        .package(url: "https://github.com/wisetail/BCryptSwift.git", from: "2.0.1"),
    ],
    targets: [
        // MARK: - Main Application
        .executableTarget(
            name: "WealthLedgerApp",
            dependencies: [
                "AccountManagement",
                "LedgerEngine",
                "ValuationEngine",
                "ReferenceDataService",
                "JobScheduler",
                "RBAC",
                "UILayer",
                "Persistence",
                "Shared",
            ],
            path: "Sources/WealthLedgerApp"
        ),

        // MARK: - CLI Seed Tool
        .executableTarget(
            name: "SeedTool",
            dependencies: [
                "Persistence",
                "ReferenceDataService",
                "AccountManagement",
                "Shared",
            ],
            path: "Sources/SeedTool"
        ),

        // MARK: - Business Logic Modules
        .target(
            name: "AccountManagement",
            dependencies: [
                "Persistence",
                "RBAC",
                "Shared",
            ],
            path: "Sources/AccountManagement"
        ),
        .target(
            name: "LedgerEngine",
            dependencies: [
                "Persistence",
                "RBAC",
                "Shared",
            ],
            path: "Sources/LedgerEngine"
        ),
        .target(
            name: "ValuationEngine",
            dependencies: [
                "Persistence",
                "ReferenceDataService",
                "AccountManagement",
                "Shared",
            ],
            path: "Sources/ValuationEngine"
        ),
        .target(
            name: "ReferenceDataService",
            dependencies: [
                "Persistence",
                "Shared",
            ],
            path: "Sources/ReferenceDataService"
        ),
        .target(
            name: "JobScheduler",
            dependencies: [
                "Persistence",
                "ReferenceDataService",
                "AccountManagement",
                "ValuationEngine",
                "Shared",
            ],
            path: "Sources/JobScheduler"
        ),
        .target(
            name: "RBAC",
            dependencies: [
                "Persistence",
                "Shared",
                .product(name: "BCryptSwift", package: "BCryptSwift"),
            ],
            path: "Sources/RBAC"
        ),
        .target(
            name: "UILayer",
            dependencies: [
                "AccountManagement",
                "LedgerEngine",
                "ValuationEngine",
                "ReferenceDataService",
                "JobScheduler",
                "RBAC",
                "Shared",
            ],
            path: "Sources/UILayer"
        ),

        // MARK: - Persistence Layer
        .target(
            name: "Persistence",
            dependencies: [
                "Shared",
                .product(name: "MySQLKit", package: "mysql-kit"),
            ],
            path: "Sources/Persistence"
        ),

        // MARK: - Shared Module
        .target(
            name: "Shared",
            dependencies: [],
            path: "Sources/Shared"
        ),

        // MARK: - Unit Tests
        .testTarget(
            name: "UnitTests",
            dependencies: [
                "AccountManagement",
                "LedgerEngine",
                "ValuationEngine",
                "ReferenceDataService",
                "RBAC",
                "Persistence",
                "Shared",
            ],
            path: "Tests/UnitTests"
        ),

        // MARK: - Integration Tests
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "AccountManagement",
                "LedgerEngine",
                "ValuationEngine",
                "ReferenceDataService",
                "JobScheduler",
                "RBAC",
                "Persistence",
                "Shared",
            ],
            path: "Tests/IntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
