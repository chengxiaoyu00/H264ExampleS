// swift-tools-version: 5.9
//
//  Package.swift
//  H264Kit
//

import PackageDescription

let package = Package(
    name: "H264Kit",
    // SPM 的 platforms 是包级的，没法按 target 区分最低版本。
    // 这里取两者的下限 iOS 12（H264KitObjC 的要求），
    // Swift 版的 API 统一标了 @available(iOS 13.0, *)。
    platforms: [
        .iOS(.v12),
    ],
    products: [
        // 原始 Objective-C 实现，整理并修复后的版本。最低 iOS 12。
        .library(name: "H264KitObjC", targets: ["H264KitObjC"]),
        // Swift 重写版：async/await + AVSampleBufferDisplayLayer。最低 iOS 13。
        .library(name: "H264Kit", targets: ["H264Kit"]),
    ],
    targets: [
        .target(
            name: "H264KitObjC",
            path: "Sources/H264KitObjC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .target(
            name: "H264Kit",
            path: "Sources/H264Kit",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .testTarget(
            name: "H264KitTests",
            dependencies: ["H264Kit", "H264KitObjC"],
            path: "Tests/H264KitTests"
        ),
    ]
)
