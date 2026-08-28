//
//  NALUTests.swift
//  H264KitTests
//
//  NALU 层是纯字节运算，不依赖 VideoToolbox，可以在任意平台上跑。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import XCTest
@testable import H264Kit

final class NALUTests: XCTestCase {

    // NAL 头：forbidden_zero_bit(1) | nal_ref_idc(2) | nal_unit_type(5)
    private let spsPayload = Data([0x67, 0x42, 0x00, 0x1F])   // type 7
    private let ppsPayload = Data([0x68, 0xCE, 0x3C, 0x80])   // type 8
    private let idrPayload = Data([0x65, 0x88, 0x84, 0x00])   // type 5
    private let pPayload   = Data([0x41, 0x9A, 0x00, 0x11])   // type 1

    // MARK: - 类型识别

    func testNALUnitTypeParsing() {
        XCTAssertEqual(NALUnit(payload: spsPayload).type, .sps)
        XCTAssertEqual(NALUnit(payload: ppsPayload).type, .pps)
        XCTAssertEqual(NALUnit(payload: idrPayload).type, .sliceIDR)
        XCTAssertEqual(NALUnit(payload: pPayload).type, .sliceNonIDR)
        XCTAssertNil(NALUnit(payload: Data()).type)
    }

    func testVideoCodingLayerClassification() {
        XCTAssertTrue(NALUnitType.sliceIDR.isVideoCodingLayer)
        XCTAssertTrue(NALUnitType.sliceNonIDR.isVideoCodingLayer)
        XCTAssertFalse(NALUnitType.sps.isVideoCodingLayer)
        XCTAssertFalse(NALUnitType.pps.isVideoCodingLayer)
        XCTAssertFalse(NALUnitType.sei.isVideoCodingLayer)
    }

    // MARK: - Annex-B

    func testAnnexBRoundTrip() {
        let units = [spsPayload, ppsPayload, idrPayload].map(NALUnit.init(payload:))
        let stream = AnnexB.stream(from: units)

        // 3 个单元 × (4 字节起始码 + 4 字节载荷)
        XCTAssertEqual(stream.count, 24)
        XCTAssertEqual(stream.prefix(4), AnnexB.startCode)
        XCTAssertEqual(AnnexB.nalUnits(in: stream), units)
    }

    func testAnnexBParsesThreeByteStartCodes() {
        // 真实码流里 3 字节和 4 字节起始码会混用。
        var stream = Data([0x00, 0x00, 0x01])
        stream.append(spsPayload)
        stream.append(Data([0x00, 0x00, 0x00, 0x01]))
        stream.append(ppsPayload)

        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].payload, spsPayload)
        XCTAssertEqual(units[1].payload, ppsPayload)
    }

    func testAnnexBIgnoresLeadingGarbage() {
        var stream = Data([0xAA, 0xBB])
        stream.append(AnnexB.startCode)
        stream.append(idrPayload)

        XCTAssertEqual(AnnexB.nalUnits(in: stream).map(\.payload), [idrPayload])
    }

    func testAnnexBOnEmptyAndTruncatedInput() {
        XCTAssertTrue(AnnexB.nalUnits(in: Data()).isEmpty)
        XCTAssertTrue(AnnexB.nalUnits(in: Data([0x00, 0x00])).isEmpty)
        // 只有起始码、没有载荷
        XCTAssertTrue(AnnexB.nalUnits(in: AnnexB.startCode).isEmpty)
    }

    func testAnnexBSkipsEmptyPayloads() {
        let units = [NALUnit(payload: Data()), NALUnit(payload: idrPayload)]
        XCTAssertEqual(AnnexB.stream(from: units).count, 8)
    }

    // MARK: - AVCC

    func testAVCCRoundTrip() {
        let units = [spsPayload, ppsPayload, idrPayload].map(NALUnit.init(payload:))
        let stream = AVCC.stream(from: units)

        XCTAssertEqual(stream.count, 24)
        XCTAssertEqual(stream.prefix(4), Data([0x00, 0x00, 0x00, 0x04]))  // 大端长度 4
        XCTAssertEqual(AVCC.nalUnits(in: stream), units)
    }

    func testAVCCLengthPrefixIsBigEndian() {
        let payload = Data(repeating: 0x41, count: 0x0123)
        let stream = AVCC.stream(from: [NALUnit(payload: payload)])
        XCTAssertEqual(stream.prefix(4), Data([0x00, 0x00, 0x01, 0x23]))
    }

    func testAVCCHonoursNonDefaultLengthSize() {
        let units = [NALUnit(payload: idrPayload)]
        let stream = AVCC.stream(from: units, lengthSize: 2)
        XCTAssertEqual(stream.prefix(2), Data([0x00, 0x04]))
        XCTAssertEqual(AVCC.nalUnits(in: stream, lengthSize: 2), units)
    }

    func testAVCCRejectsInvalidLengthSize() {
        XCTAssertTrue(AVCC.stream(from: [NALUnit(payload: idrPayload)], lengthSize: 0).isEmpty)
        XCTAssertTrue(AVCC.stream(from: [NALUnit(payload: idrPayload)], lengthSize: 5).isEmpty)
        XCTAssertTrue(AVCC.nalUnits(in: Data([0x00, 0x00, 0x00, 0x01]), lengthSize: 9).isEmpty)
    }

    func testAVCCStopsOnTruncatedStream() {
        // 长度字段说有 100 字节，实际只剩 4 字节 —— 必须停下而不是越界读。
        var stream = Data([0x00, 0x00, 0x00, 0x64])
        stream.append(idrPayload)
        XCTAssertTrue(AVCC.nalUnits(in: stream).isEmpty)
    }

    func testAVCCRecoversUnitsBeforeTruncation() {
        var stream = AVCC.stream(from: [NALUnit(payload: spsPayload)])
        stream.append(Data([0x00, 0x00, 0x00, 0x64]))   // 越界的长度字段
        stream.append(idrPayload)

        XCTAssertEqual(AVCC.nalUnits(in: stream).map(\.payload), [spsPayload])
    }

    // MARK: - 互转

    func testAVCCToAnnexBAndBack() {
        let units = [spsPayload, ppsPayload, idrPayload, pPayload].map(NALUnit.init(payload:))
        let avcc = AVCC.stream(from: units)

        let annexB = avcc.avccToAnnexB()
        XCTAssertEqual(AnnexB.nalUnits(in: annexB), units)

        XCTAssertEqual(annexB.annexBToAVCC(), avcc)
    }

    func testConvenienceRepresentations() {
        let unit = NALUnit(payload: idrPayload)
        XCTAssertEqual(unit.annexB, AnnexB.startCode + idrPayload)
        XCTAssertEqual(unit.avcc(), Data([0x00, 0x00, 0x00, 0x04]) + idrPayload)
    }

    // MARK: - 参数集

    func testParameterSetsAnnexB() {
        let sets = ParameterSets(sps: spsPayload, pps: ppsPayload)
        let units = AnnexB.nalUnits(in: sets.annexB)

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].type, .sps)
        XCTAssertEqual(units[1].type, .pps)
    }
}
