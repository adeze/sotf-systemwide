// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConfigBar",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(
            name: "ConfigBarModels",
            targets: ["ConfigBarModels"]
        ),
        .library(
            name: "ConfigBarUI",
            targets: ["ConfigBarUI"]
        ),
        .executable(
            name: "sotf-systemwide",
            targets: ["SotFSystemwide"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0")
    ],
    targets: [
        .target(
            name: "ConfigBarModels",
            path: "src",
            exclude: [
                "ConfigBar.swift",
                "AppMain.swift",
                "OutputProfilesView.swift",
                "PluginEditorViews.swift",
                "PluginRackView.swift",
            ],
            sources: ["PluginModels.swift", "ConfigBarIPC.swift", "ConfigBarPure.swift"]
        ),
        .target(
            name: "ConfigBarUI",
            dependencies: ["ConfigBarModels"],
            path: "src",
            exclude: ["AppMain.swift", "PluginModels.swift", "ConfigBarIPC.swift", "ConfigBarPure.swift"],
            sources: ["ConfigBar.swift", "OutputProfilesView.swift", "PluginEditorViews.swift", "PluginRackView.swift"]
        ),
        .executableTarget(
            name: "SotFSystemwide",
            dependencies: ["ConfigBarUI"],
            path: "src",
            exclude: [
                "ConfigBar.swift",
                "OutputProfilesView.swift",
                "PluginEditorViews.swift",
                "PluginRackView.swift",
                "PluginModels.swift",
                "ConfigBarIPC.swift",
                "ConfigBarPure.swift",
            ],
            sources: ["AppMain.swift"]
        ),
        .testTarget(
            name: "ConfigBarModelTests",
            dependencies: ["ConfigBarModels"],
            path: "tests",
            exclude: ["ConfigBarUITests.swift", "__Snapshots__"],
            sources: ["ConfigBarModelTests.swift", "ConfigBarIPCTests.swift"]
        ),
        .testTarget(
            name: "ConfigBarUITests",
            dependencies: ["ConfigBarUI", "ConfigBarModels", "ViewInspector"],
            path: "tests",
            exclude: ["ConfigBarModelTests.swift", "ConfigBarIPCTests.swift", "__Snapshots__"],
            sources: ["ConfigBarUITests.swift"]
        ),
    ]
)
