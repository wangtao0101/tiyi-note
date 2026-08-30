// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TiyiDocuments",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "TiyiDocuments",
            targets: ["TiyiDocuments"]
        )
    ],
    targets: [
        .target(
            name: "TiyiDocuments",
            path: "TiyiNote",
            exclude: [
                "App/TiyiNoteApp.swift",
                "Info.plist",
                "Resources",
                "Services/CloudKitSmokeHarness.swift",
                "Services/LibraryFeatureSmokeHarness.swift",
                "TiyiNote.entitlements",
                "TiyiNote.Release.entitlements"
            ]
        )
    ]
)
