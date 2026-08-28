//
//  VideoRenderer.swift
//  H264Kit
//
//  用 AVSampleBufferDisplayLayer 显示解码后的画面。
//
//  这一整个文件替代了 1.x 里 594 行的 AAPLEAGLLayer —— 那是 Apple 2014 年的
//  OpenGL ES 示例代码，自己写 shader 做 YUV→RGB。AVSampleBufferDisplayLayer
//  在系统层面做同样的事，且不依赖已被弃用的 OpenGL ES。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 把 `CVPixelBuffer` 送上屏。
///
/// ```swift
/// let renderer = VideoRenderer()
/// view.layer.addSublayer(renderer.layer)
/// renderer.layer.frame = view.bounds
///
/// for await frame in decoder.frames {
///     renderer.enqueue(frame)
/// }
/// ```
@available(iOS 13.0, *)
@MainActor
public final class VideoRenderer {

    /// 底层显示图层，自己加到视图层级里，或者直接用 `H264PlayerView`。
    public let layer = AVSampleBufferDisplayLayer()

    /// 画面填充方式，默认 `.resizeAspect`。
    public var videoGravity: AVLayerVideoGravity {
        get { layer.videoGravity }
        set { layer.videoGravity = newValue }
    }

    private var formatDescription: CMFormatDescription?

    public init() {
        layer.videoGravity = .resizeAspect
        // 立即显示：实时流不需要按时间戳排程，来一帧显示一帧。
        layer.controlTimebase = nil
    }

    /// 显示解码器输出的一帧。
    public func enqueue(_ frame: DecodedFrame) {
        enqueue(frame.pixelBuffer, presentationTimeStamp: frame.presentationTimeStamp)
    }

    /// 显示一个 pixel buffer。
    public func enqueue(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime = .invalid) {
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer, pts: presentationTimeStamp) else { return }

        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }

    /// 清空待显示队列（例如 seek 或切流时）。
    public func flush() {
        layer.flushAndRemoveImage()
        formatDescription = nil
    }

    /// 把 pixel buffer 包成 `CMSampleBuffer`，并复用 format description。
    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // 分辨率变了要换 format description，否则图层会拒绝新帧。
        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var created: CMFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            ) == noErr else { return nil }
            formatDescription = created
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts.isValid ? pts : .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // 告诉图层立刻显示，不要等 timebase。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }
}

#if canImport(UIKit)

/// 一个把 `VideoRenderer` 的图层当作 backing layer 的 UIView，省掉手工管理 frame。
@available(iOS 13.0, *)
@MainActor
public final class H264PlayerView: UIView {

    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private var formatDescription: CMFormatDescription?

    public var videoGravity: AVLayerVideoGravity {
        get { displayLayer.videoGravity }
        set { displayLayer.videoGravity = newValue }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func enqueue(_ frame: DecodedFrame) {
        enqueue(frame.pixelBuffer, presentationTimeStamp: frame.presentationTimeStamp)
    }

    public func enqueue(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime = .invalid) {
        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var created: CMFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            ) == noErr else { return }
            formatDescription = created
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp.isValid ? presentationTimeStamp : .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    public func flush() {
        displayLayer.flushAndRemoveImage()
        formatDescription = nil
    }
}

#endif

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// `H264PlayerView` 的 SwiftUI 包装。
///
/// ```swift
/// struct PlayerScreen: View {
///     let decoder: H264Decoder
///     var body: some View {
///         H264PlayerRepresentable(frames: decoder.frames)
///             .aspectRatio(16/9, contentMode: .fit)
///     }
/// }
/// ```
@available(iOS 14.0, *)
public struct H264PlayerRepresentable: UIViewRepresentable {

    private let frames: AsyncStream<DecodedFrame>
    private let videoGravity: AVLayerVideoGravity

    public init(frames: AsyncStream<DecodedFrame>, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.frames = frames
        self.videoGravity = videoGravity
    }

    public func makeUIView(context: Context) -> H264PlayerView {
        let view = H264PlayerView(frame: .zero)
        view.videoGravity = videoGravity
        context.coordinator.start(streaming: frames, into: view)
        return view
    }

    public func updateUIView(_ uiView: H264PlayerView, context: Context) {
        uiView.videoGravity = videoGravity
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        private var task: Task<Void, Never>?

        func start(streaming frames: AsyncStream<DecodedFrame>, into view: H264PlayerView) {
            task?.cancel()
            task = Task { @MainActor in
                for await frame in frames {
                    if Task.isCancelled { break }
                    view.enqueue(frame)
                }
            }
        }

        deinit { task?.cancel() }
    }
}
#endif
