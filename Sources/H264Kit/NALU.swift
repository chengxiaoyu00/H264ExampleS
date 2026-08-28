//
//  NALU.swift
//  H264Kit
//
//  H.264 码流的两种封装格式及其互转。
//
//  * AVCC    —— VideoToolbox 编解码器用的格式，每个 NAL 单元前是大端长度前缀。
//  * Annex-B —— 传输 / 落盘常用的格式，每个 NAL 单元前是 `00 00 01` 或 `00 00 00 01` 起始码。
//
//  整个文件是纯字节运算，不碰 VideoToolbox，可以在模拟器和 CI 上直接跑单元测试。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// NAL 单元类型，即载荷首字节的低 5 位（`nal_unit_type`）。
public enum NALUnitType: UInt8, Sendable, CaseIterable {
    case unspecified  = 0
    /// 非关键帧片（P / B）
    case sliceNonIDR  = 1
    case sliceDPA     = 2
    case sliceDPB     = 3
    case sliceDPC     = 4
    /// 关键帧片（IDR）
    case sliceIDR     = 5
    /// 补充增强信息
    case sei          = 6
    /// 序列参数集
    case sps          = 7
    /// 图像参数集
    case pps          = 8
    /// 存取单元分隔符
    case aud          = 9

    /// 是否是需要送进解码器的图像数据（而非参数集 / 元信息）。
    public var isVideoCodingLayer: Bool {
        (1...5).contains(rawValue)
    }
}

/// 一个不含起始码、不含长度前缀的 NAL 单元。
public struct NALUnit: Sendable, Equatable {
    /// 裸载荷，第一个字节是 NAL 头。
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }

    /// 单元类型；载荷为空或类型未知时为 `nil`。
    public var type: NALUnitType? {
        guard let header = payload.first else { return nil }
        return NALUnitType(rawValue: header & 0x1F)
    }

    /// 加上 4 字节起始码后的 Annex-B 表示。
    public var annexB: Data {
        AnnexB.startCode + payload
    }

    /// 加上 `lengthSize` 字节大端长度前缀后的 AVCC 表示。
    public func avcc(lengthSize: Int = 4) -> Data {
        AVCC.lengthPrefix(payload.count, lengthSize: lengthSize) + payload
    }
}

// MARK: - Annex-B

/// Annex-B 起始码格式的解析与生成。
public enum AnnexB {

    /// 4 字节起始码 `00 00 00 01`。
    public static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// 从 Annex-B 码流中切出所有 NAL 单元。3 字节和 4 字节起始码都能识别。
    public static func nalUnits(in stream: Data) -> [NALUnit] {
        var units: [NALUnit] = []
        let bytes = [UInt8](stream)

        guard var match = findStartCode(in: bytes, from: 0) else { return units }
        while true {
            let payloadStart = match.index + match.length
            let next = findStartCode(in: bytes, from: payloadStart)
            let payloadEnd = next?.index ?? bytes.count
            if payloadEnd > payloadStart {
                units.append(NALUnit(payload: Data(bytes[payloadStart..<payloadEnd])))
            }
            guard let next else { break }
            match = next
        }
        return units
    }

    /// 把若干 NAL 单元拼成 Annex-B 码流。
    public static func stream(from units: [NALUnit]) -> Data {
        var stream = Data()
        for unit in units where !unit.payload.isEmpty {
            stream.append(startCode)
            stream.append(unit.payload)
        }
        return stream
    }

    /// 在 `bytes` 中从 `offset` 起找下一个起始码。
    private static func findStartCode(in bytes: [UInt8], from offset: Int) -> (index: Int, length: Int)? {
        guard bytes.count >= 3, offset < bytes.count else { return nil }
        var i = offset
        while i + 2 < bytes.count {
            if bytes[i] == 0x00 && bytes[i + 1] == 0x00 {
                if bytes[i + 2] == 0x01 {
                    return (i, 3)
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01 {
                    return (i, 4)
                }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - AVCC

/// AVCC 长度前缀格式的解析与生成。
public enum AVCC {

    /// 从 AVCC 码流中切出所有 NAL 单元。长度字段越界时停止解析并返回已取到的部分。
    public static func nalUnits(in stream: Data, lengthSize: Int = 4) -> [NALUnit] {
        guard (1...4).contains(lengthSize) else { return [] }

        var units: [NALUnit] = []
        let bytes = [UInt8](stream)
        var offset = 0

        while offset + lengthSize <= bytes.count {
            var length = 0
            for i in 0..<lengthSize {
                length = (length << 8) | Int(bytes[offset + i])
            }
            offset += lengthSize
            guard length > 0, offset + length <= bytes.count else { break }
            units.append(NALUnit(payload: Data(bytes[offset..<(offset + length)])))
            offset += length
        }
        return units
    }

    /// 把若干 NAL 单元拼成 AVCC 码流。
    public static func stream(from units: [NALUnit], lengthSize: Int = 4) -> Data {
        guard (1...4).contains(lengthSize) else { return Data() }

        var stream = Data()
        for unit in units where !unit.payload.isEmpty {
            stream.append(lengthPrefix(unit.payload.count, lengthSize: lengthSize))
            stream.append(unit.payload)
        }
        return stream
    }

    /// 生成 `lengthSize` 字节的大端长度前缀。
    static func lengthPrefix(_ length: Int, lengthSize: Int) -> Data {
        var prefix = Data(capacity: lengthSize)
        for i in stride(from: lengthSize - 1, through: 0, by: -1) {
            prefix.append(UInt8((length >> (8 * i)) & 0xFF))
        }
        return prefix
    }
}

// MARK: - 互转

extension Data {

    /// 把 AVCC 码流转成 Annex-B。
    public func avccToAnnexB(lengthSize: Int = 4) -> Data {
        AnnexB.stream(from: AVCC.nalUnits(in: self, lengthSize: lengthSize))
    }

    /// 把 Annex-B 码流转成 AVCC。
    public func annexBToAVCC(lengthSize: Int = 4) -> Data {
        AVCC.stream(from: AnnexB.nalUnits(in: self), lengthSize: lengthSize)
    }
}

// MARK: - 参数集

/// 一组 SPS + PPS。解码端拿到它才能建解码会话。
public struct ParameterSets: Sendable, Equatable {
    public let sps: Data
    public let pps: Data

    public init(sps: Data, pps: Data) {
        self.sps = sps
        self.pps = pps
    }

    /// 参数集的 Annex-B 表示：起始码 + SPS + 起始码 + PPS。
    public var annexB: Data {
        AnnexB.stream(from: [NALUnit(payload: sps), NALUnit(payload: pps)])
    }
}
