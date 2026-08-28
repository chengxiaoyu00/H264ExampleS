//
//  H264Decoder.swift
//  H264Kit
//
//  基于 VideoToolbox 的 H.264 硬件解码器，用 AsyncStream 吐出解码结果。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 解出来的一帧。
@available(iOS 13.0, *)
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// H.264 硬件解码器。
///
/// ```swift
/// let decoder = H264Decoder()
///
/// Task {
///     for await frame in decoder.frames {
///         await renderer.enqueue(frame)
///     }
/// }
///
/// decoder.decode(annexB: chunkFromNetwork)
/// ```
///
/// 喂 Annex-B 码流即可，SPS / PPS 自动收集。**参数集变化时会自动重建解码会话**，
/// 所以中途切分辨率、切摄像头都不用额外处理。参数集还没齐时收到的图像帧会被丢弃。
@available(iOS 13.0, *)
public final class H264Decoder: @unchecked Sendable {

    /// 解码结果流。每个解码器只应被消费一次。
    public var frames: AsyncStream<DecodedFrame> { stream }

    private let queue = DispatchQueue(label: "com.h264kit.decoder")
    private let stream: AsyncStream<DecodedFrame>
    private let continuation: AsyncStream<DecodedFrame>.Continuation

    // 以下成员只在 queue 上访问。
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?

    public init() {
        var capturedContinuation: AsyncStream<DecodedFrame>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(6)) { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    deinit {
        continuation.finish()
        teardown()
    }

    // MARK: - 输入

    /// 解一段 Annex-B 码流，可以包含任意多个 NAL 单元。
    public func decode(annexB: Data) {
        decode(AnnexB.nalUnits(in: annexB))
    }

    /// 解一段 AVCC 码流。
    public func decode(avcc: Data, lengthSize: Int = 4) {
        decode(AVCC.nalUnits(in: avcc, lengthSize: lengthSize))
    }

    /// 解若干个 NAL 单元。
    public func decode(_ nalUnits: [NALUnit]) {
        guard !nalUnits.isEmpty else { return }
        queue.async { [self] in
            for unit in nalUnits {
                process(unit)
            }
        }
    }

    /// 直接送一帧编码结果（`H264Encoder` 的输出可以原样转过来）。
    public func decode(_ frame: EncodedFrame) {
        var units: [NALUnit] = []
        if let sets = frame.parameterSets {
            units.append(NALUnit(payload: sets.sps))
            units.append(NALUnit(payload: sets.pps))
        }
        units.append(contentsOf: frame.nalUnits)
        decode(units)
    }

    /// 丢弃已收集的参数集并销毁会话，下次收到 SPS / PPS 时重建。
    public func reset() {
        queue.sync { [self] in
            teardown()
            sps = nil
            pps = nil
        }
    }

    /// 结束 `frames` 流并销毁会话。
    public func stop() {
        queue.sync { teardown() }
        continuation.finish()
    }

    // MARK: - 解码

    /// 必须在 queue 上调用。
    private func process(_ unit: NALUnit) {
        switch unit.type {
        case .sps:
            // 参数集变了就得换会话，否则画面会花。
            if unit.payload != sps {
                sps = unit.payload
                teardown()
            }

        case .pps:
            if unit.payload != pps {
                pps = unit.payload
                teardown()
            }

        case .aud, .sei, .none:
            break

        default:
            guard ensureSession() else { return }   // 参数集还没齐，只能丢帧
            decodePayload(unit.payload)
        }
    }

    /// 必须在 queue 上调用。
    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }

        var formatDescription: CMFormatDescription?
        let created: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard created == noErr, let formatDescription else { return false }

        // 输出尺寸不写死，跟随 SPS 里解析出的分辨率。
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decoderOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }

        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.formatDescription = formatDescription
        self.session = session
        return true
    }

    /// 必须在 queue 上调用。
    private func decodePayload(_ payload: Data) {
        guard let session, let formatDescription else { return }

        // VideoToolbox 吃 AVCC，给裸载荷补 4 字节大端长度前缀。
        var avcc = AVCC.lengthPrefix(payload.count, lengthSize: 4)
        avcc.append(payload)

        avcc.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: baseAddress,
                blockLength: buffer.count,
                blockAllocator: kCFAllocatorNull,   // 内存由 avcc 持有，同步解码期间有效
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: buffer.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == kCMBlockBufferNoErr, let blockBuffer else { return }

            var sampleBuffer: CMSampleBuffer?
            var sampleSizes = [buffer.count]
            guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizes,
                sampleBufferOut: &sampleBuffer
            ) == noErr, let sampleBuffer else { return }

            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                frameRefcon: nil,
                infoFlagsOut: &infoFlags
            )

            if status == kVTInvalidSessionErr {
                // 常见于 App 退到后台再回来，拆掉等下一组参数集重建。
                teardown()
            }
        }
    }

    private func teardown() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
    }

    fileprivate func handleDecoded(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        continuation.yield(DecodedFrame(pixelBuffer: pixelBuffer, presentationTimeStamp: pts))
    }
}

@available(iOS 13.0, *)
private func decoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr,
          let imageBuffer,
          let refCon = decompressionOutputRefCon else { return }

    // yield 到 AsyncStream 会让 CVPixelBuffer 被 Swift 持有，
    // 不需要像 Objective-C 版那样手工 retain / release。
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecoded(imageBuffer, pts: presentationTimeStamp)
}
