//
//  H264KitError.swift
//  H264Kit
//
//  H264Kit 抛出的错误类型。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import VideoToolbox

/// H264Kit 抛出的错误。
public enum H264KitError: Error, Sendable {

    /// 配置不合法（例如宽高 <= 0）。
    case invalidConfiguration(String)

    /// 创建 `VTCompressionSession` 失败。
    case compressionSessionCreationFailed(OSStatus)

    /// 创建 `VTDecompressionSession` 失败。
    case decompressionSessionCreationFailed(OSStatus)

    /// 编码某一帧失败。
    case encodeFailed(OSStatus)

    /// 解码某一帧失败。
    case decodeFailed(OSStatus)

    /// 从 SPS / PPS 构造 format description 失败。
    case formatDescriptionCreationFailed(OSStatus)

    /// 会话已被销毁（`stop()` 之后继续送帧）。
    case sessionInvalidated
}

extension H264KitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "编码器配置不合法：\(reason)"
        case .compressionSessionCreationFailed(let status):
            return "VTCompressionSessionCreate 失败 (\(status))"
        case .decompressionSessionCreationFailed(let status):
            return "VTDecompressionSessionCreate 失败 (\(status))"
        case .encodeFailed(let status):
            return "VTCompressionSessionEncodeFrame 失败 (\(status))"
        case .decodeFailed(let status):
            return "VTDecompressionSessionDecodeFrame 失败 (\(status))"
        case .formatDescriptionCreationFailed(let status):
            return "CMVideoFormatDescriptionCreateFromH264ParameterSets 失败 (\(status))"
        case .sessionInvalidated:
            return "会话已销毁"
        }
    }
}
