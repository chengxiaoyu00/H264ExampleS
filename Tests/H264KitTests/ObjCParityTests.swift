//
//  ObjCParityTests.swift
//  H264KitTests
//
//  两套实现是各写各的，容易悄悄跑偏。这里让它们对同一份输入互相验证：
//  OC 版编出来的 Swift 版必须能解回去，反之亦然。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import XCTest
import H264KitObjC
@testable import H264Kit

final class ObjCParityTests: XCTestCase {

    private let spsPayload = Data([0x67, 0x42, 0x00, 0x1F])
    private let ppsPayload = Data([0x68, 0xCE, 0x3C, 0x80])
    private let idrPayload = Data([0x65, 0x88, 0x84, 0x00, 0x11, 0x22])

    private var payloads: [Data] { [spsPayload, ppsPayload, idrPayload] }

    // MARK: - 类型识别

    func testNALUnitTypeAgrees() {
        for payload in payloads {
            let objc = H264NALUnitTypeOfPayload(payload)
            let swift = NALUnit(payload: payload).type
            XCTAssertEqual(objc.rawValue, swift?.rawValue, "载荷 \(payload.map { String($0, radix: 16) })")
        }
    }

    func testStartCodeAgrees() {
        XCTAssertEqual(H264AnnexBStartCode(), AnnexB.startCode)
    }

    // MARK: - Annex-B

    func testAnnexBEncodingAgrees() {
        let objc = H264AnnexBStreamFromPayloads(payloads)
        let swift = AnnexB.stream(from: payloads.map(NALUnit.init(payload:)))
        XCTAssertEqual(objc, swift)
    }

    func testAnnexBDecodingAgrees() {
        let stream = AnnexB.stream(from: payloads.map(NALUnit.init(payload:)))
        XCTAssertEqual(H264PayloadsFromAnnexBStream(stream), AnnexB.nalUnits(in: stream).map(\.payload))
    }

    func testSwiftParsesObjCAnnexBOutput() {
        let stream = H264AnnexBStreamFromPayloads(payloads)
        XCTAssertEqual(AnnexB.nalUnits(in: stream).map(\.payload), payloads)
    }

    func testObjCParsesSwiftAnnexBOutput() {
        let stream = AnnexB.stream(from: payloads.map(NALUnit.init(payload:)))
        XCTAssertEqual(H264PayloadsFromAnnexBStream(stream), payloads)
    }

    // MARK: - AVCC

    func testAVCCEncodingAgrees() {
        for lengthSize in 1...4 {
            let objc = H264AVCCStreamFromPayloads(payloads, UInt(lengthSize))
            let swift = AVCC.stream(from: payloads.map(NALUnit.init(payload:)), lengthSize: lengthSize)
            XCTAssertEqual(objc, swift, "lengthSize = \(lengthSize)")
        }
    }

    func testAVCCDecodingAgrees() {
        for lengthSize in 1...4 {
            let stream = AVCC.stream(from: payloads.map(NALUnit.init(payload:)), lengthSize: lengthSize)
            XCTAssertEqual(H264PayloadsFromAVCCStream(stream, UInt(lengthSize)),
                           AVCC.nalUnits(in: stream, lengthSize: lengthSize).map(\.payload),
                           "lengthSize = \(lengthSize)")
        }
    }

    // MARK: - 互转

    func testCrossConversionAgrees() {
        let avcc = AVCC.stream(from: payloads.map(NALUnit.init(payload:)))
        XCTAssertEqual(H264AnnexBFromAVCC(avcc, 4), avcc.avccToAnnexB())

        let annexB = AnnexB.stream(from: payloads.map(NALUnit.init(payload:)))
        XCTAssertEqual(H264AVCCFromAnnexB(annexB, 4), annexB.annexBToAVCC())
    }

    func testTruncatedAVCCHandledIdentically() {
        // 长度字段声称 0x64 字节，实际只有 6 字节 —— 两边都必须停下而不是越界读。
        var stream = Data([0x00, 0x00, 0x00, 0x64])
        stream.append(idrPayload)

        XCTAssertTrue(H264PayloadsFromAVCCStream(stream, 4).isEmpty)
        XCTAssertTrue(AVCC.nalUnits(in: stream).isEmpty)
    }

    // MARK: - 编解码器可实例化

    func testObjCEncoderRejectsInvalidSize() {
        let encoder = H264HwEncoderImpl()
        XCTAssertFalse(encoder.isReady)
        XCTAssertThrowsError(try encoder.prepare(with: H264EncoderConfiguration(width: 0, height: 0)))
    }

    func testSwiftEncoderRejectsInvalidSize() {
        XCTAssertThrowsError(try H264Encoder(configuration: .init(width: 0, height: 0))) { error in
            guard case H264KitError.invalidConfiguration = error else {
                return XCTFail("期望 invalidConfiguration，实际是 \(error)")
            }
        }
    }

    func testDecodersStartUnready() {
        XCTAssertFalse(H264HwDecoderImpl().isReady)
    }
}
