//
//  H264Encoder.swift
//  H264Kit
//
//  基于 VideoToolbox 的 H.264 硬件编码器，用 AsyncStream 吐出编码结果。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 编码器吐出的一帧。
@available(iOS 13.0, *)
public struct EncodedFrame: @unchecked Sendable {

    /// 该帧包含的所有 NAL 单元（裸载荷，不含起始码/ 长度前缀）。
    public let nalUnits: [NALUnit]

    /// 是否是关键帧（IDR）。
    public let isKeyFrame: Bool

    /// 显示时间戳。
    public let presentationTimeStamp: CMTime

    /// 该帧对应的参数集。仅在参数集**发生变化**的关键帧上非 nil——
    /// 收到它就意味着解码端需要重建会话。
    public let parameterSets: ParameterSets?

    /// Annex-B 码流。关键帧会把参数集拼在最前面，可以直接写文件或推流。
    public var annexB: Data {
        var stream = Data()
        if let parameterSets {
            stream.append(parameterSets.annexB)
        }
        stream.append(AnnexB.stream(from: nalUnits))
        return stream
    }

    /// AVCC 码流（长度前缀），不含参数集。
    public func avcc(lengthSize: Int = 4) -> Data {
        AVCC.stream(from: nalUnits, lengthSize: lengthSize)
    }
}

/// H.264 的 Profile / Level。
///
/// 包一层是因为 `CFString` 不是 `Sendable`，直接放进配置里在 Swift 6 下会报错；
/// 顺带也比裸常量好用。需要用列表外的取值时走 `init(_:)`。
@available(iOS 13.0, *)
public struct ProfileLevel: Sendable, Equatable {

    public let rawValue: String

    public init(_ profileLevel: CFString) {
        self.rawValue = profileLevel as String
    }

    var cfString: CFString { rawValue as CFString }

    /// Baseline，兼容性最好，不支持 B 帧。直播默认用这个。
    public static let baselineAutoLevel = ProfileLevel(kVTProfileLevel_H264_Baseline_AutoLevel)
    /// Main，压缩率优于 Baseline。
    public static let mainAutoLevel = ProfileLevel(kVTProfileLevel_H264_Main_AutoLevel)
    /// High，压缩率最好，解码开销也最大。
    public static let highAutoLevel = ProfileLevel(kVTProfileLevel_H264_High_AutoLevel)
}

/// H.264 硬件编码器。
///
/// ```swift
/// let encoder = try H264Encoder(configuration: .init(width: 1280, height: 720))
///
/// Task {
///     for await frame in encoder.frames {
///         try? fileHandle.write(contentsOf: frame.annexB)
///     }
/// }
///
/// // AVCaptureVideoDataOutput 回调里：
/// encoder.encode(sampleBuffer)
/// ```
///
/// 线程模型：`encode` 是同步非阻塞的，可以直接在采集回调队列上调用；
/// 内部用串行队列保证送帧顺序。用 `final class` 而非 `actor`，是因为
/// `actor` 上的 `Task` 不保证 FIFO，视频帧一旦乱序就会花屏。
@available(iOS 13.0, *)
public final class H264Encoder: @unchecked Sendable {

    /// 编码参数。
    public struct Configuration: Sendable {

        public var width: Int
        public var height: Int
        /// 平均码率，bps。默认 `width * height * 8`。
        public var averageBitRate: Int
        /// 关键帧最大间隔（帧数）。越小抗丢包越强、码流越大。
        public var maxKeyFrameInterval: Int
        /// 关键帧最大间隔（秒）。`nil` 表示不设置。
        public var maxKeyFrameIntervalDuration: Double?
        /// 预期帧率，用于码率控制。
        public var expectedFrameRate: Int
        /// Profile / Level。
        public var profileLevel: ProfileLevel
        /// 实时模式：牺牲压缩率换低延迟。直播场景应为 `true`。
        public var isRealTime: Bool
        /// 是否允许帧重排（B 帧）。直播场景应为 `false`。
        public var allowFrameReordering: Bool

        public init(
            width: Int,
            height: Int,
            averageBitRate: Int? = nil,
            maxKeyFrameInterval: Int = 30,
            maxKeyFrameIntervalDuration: Double? = 2.0,
            expectedFrameRate: Int = 30,
            profileLevel: ProfileLevel = .baselineAutoLevel,
            isRealTime: Bool = true,
            allowFrameReordering: Bool = false
        ) {
            self.width = width
            self.height = height
            self.averageBitRate = averageBitRate ?? (width * height * 8)
            self.maxKeyFrameInterval = maxKeyFrameInterval
            self.maxKeyFrameIntervalDuration = maxKeyFrameIntervalDuration
            self.expectedFrameRate = expectedFrameRate
            self.profileLevel = profileLevel
            self.isRealTime = isRealTime
            self.allowFrameReordering = allowFrameReordering
        }
    }

    public let configuration: Configuration

    /// 编码结果流。每个编码器只应被消费一次。
    public var frames: AsyncStream<EncodedFrame> { stream }

    private let queue = DispatchQueue(label: "com.h264kit.encoder")
    private let stream: AsyncStream<EncodedFrame>
    private let continuation: AsyncStream<EncodedFrame>.Continuation

    // 以下成员只在 queue 上访问。
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var forceKeyFrame = false
    private var lastParameterSets: ParameterSets?

    /// 创建并启动编码会话。
    /// - Throws: `H264KitError.invalidConfiguration` 或 `.compressionSessionCreationFailed`
    public init(configuration: Configuration) throws {
        guard configuration.width > 0, configuration.height > 0 else {
            throw H264KitError.invalidConfiguration("宽高必须大于 0")
        }
        self.configuration = configuration

        // 缓冲策略取 .bufferingNewest：消费端跟不上时丢老帧而不是无限堆积内存。
        var capturedContinuation: AsyncStream<EncodedFrame>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(30)) { capturedContinuation = $0 }
        self.continuation = capturedContinuation

        try queue.sync { try createSession() }
    }

    deinit {
        // deinit 里不能 queue.sync（闭包会捕获正在析构的 self），直接拆。
        continuation.finish()
        teardown()
    }

    // MARK: - 输入

    /// 送一帧去编码，通常直接来自 `AVCaptureVideoDataOutput`。
    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encode(
            pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer)
        )
    }

    /// 送一帧去编码，自己指定时间戳。
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime = .invalid
    ) {
        queue.async { [self] in
            guard let session else { return }

            var pts = presentationTimeStamp
            if !pts.isValid {
                // 没有可用时间戳时用帧序号兜底，时间基 1000 便于换算成毫秒。
                let fps = Int64(max(configuration.expectedFrameRate, 1))
                pts = CMTimeMake(value: frameIndex * (1000 / fps), timescale: 1000)
            }
            frameIndex += 1

            var frameProperties: CFDictionary?
            if forceKeyFrame {
                forceKeyFrame = false
                frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }

            var infoFlags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: frameProperties,
                sourceFrameRefcon: nil,
                infoFlagsOut: &infoFlags
            )

            if status != noErr {
                teardown()
                continuation.finish()
            }
        }
    }

    /// 要求下一帧编成关键帧（例如有新观众加入时）。
    public func requestKeyFrame() {
        queue.async { [self] in
            forceKeyFrame = true
            // 参数集一并清掉，好让下一个关键帧重新带上 SPS / PPS。
            lastParameterSets = nil
        }
    }

    /// 冲出排队中的帧、结束 `frames` 流并销毁会话。
    public func stop() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            }
            teardown()
        }
        continuation.finish()
    }

    // MARK: - 会话

    /// 必须在 queue 上调用。
    private func createSession() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw H264KitError.compressionSessionCreationFailed(status)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: configuration.isRealTime as CFBoolean)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: configuration.allowFrameReordering as CFBoolean)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: configuration.profileLevel.cfString)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: configuration.averageBitRate as CFNumber)
        if configuration.maxKeyFrameInterval > 0 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: configuration.maxKeyFrameInterval as CFNumber)
        }
        if let duration = configuration.maxKeyFrameIntervalDuration, duration > 0 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                 value: duration as CFNumber)
        }
        if configuration.expectedFrameRate > 0 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                 value: configuration.expectedFrameRate as CFNumber)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    private func teardown() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - 输出

    /// 由 C 回调转入，已在 queue 语境下（VideoToolbox 在送帧线程上回调）。
    fileprivate func handleCompressed(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)

        var newParameterSets: ParameterSets?
        if isKeyFrame,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let sets = Self.parameterSets(from: formatDescription),
           sets != lastParameterSets {
            lastParameterSets = sets
            newParameterSets = sets
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer,
                                          atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer else { return }

        // VideoToolbox 输出 AVCC，一帧里可能有多个 NAL 单元。
        let avcc = Data(bytes: dataPointer, count: totalLength)
        let nalUnits = AVCC.nalUnits(in: avcc, lengthSize: 4)
        guard !nalUnits.isEmpty else { return }

        continuation.yield(EncodedFrame(
            nalUnits: nalUnits,
            isKeyFrame: isKeyFrame,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            parameterSets: newParameterSets
        ))
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        return !CFDictionaryContainsKey(attachment,
                                        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

    /// 参数集数量不固定，逐个按 NAL 类型认，不假定 index 0 是 SPS。
    private static func parameterSets(from formatDescription: CMFormatDescription) -> ParameterSets? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return nil }

        var sps: Data?
        var pps: Data?
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                let pointer, size > 0 else { continue }

            let payload = Data(bytes: pointer, count: size)
            switch NALUnit(payload: payload).type {
            case .sps: sps = payload
            case .pps: pps = payload
            default: break
            }
        }

        guard let sps, let pps else { return nil }
        return ParameterSets(sps: sps, pps: pps)
    }
}

@available(iOS 13.0, *)
private func encoderOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr,
          !infoFlags.contains(.frameDropped),
          let sampleBuffer,
          let refCon = outputCallbackRefCon else { return }

    let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleCompressed(sampleBuffer)
}
