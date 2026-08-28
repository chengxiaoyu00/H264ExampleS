//
//  H264HwDecoderImpl.h
//  H264Kit
//
//  基于 VideoToolbox VTDecompressionSession 的 H.264 硬件解码器。
//
//  最初由徐杨创建于 2016 年，2.0 起重写。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@class H264HwDecoderImpl;

/// 解码结果回调。
///
/// 出帧的两个方法都是可选的，但**必须实现其中一个**，否则解出来的帧无处可去。
/// 两个都实现时只会回调带时间戳的那个。
@protocol H264HwDecoderImplDelegate <NSObject>

@optional

/// 解出一帧，带显示时间戳。新代码用这个。
///
/// @note `imageBuffer` 只在本次回调内有效，要留到之后用请自己 `CVPixelBufferRetain`。
///       这一点和 1.x 不同：1.x 要求 delegate 负责 release，很容易漏。
- (void)h264Decoder:(H264HwDecoderImpl *)decoder
     didDecodeFrame:(CVImageBufferRef)imageBuffer
presentationTimeStamp:(CMTime)presentationTimeStamp;

/// 解出一帧。1.x 就有的签名，保留是为了让老代码能直接跑。
///
/// @note 所有权语义和 1.x 不同：`imageBuffer` 只在本次回调内有效，
///       **不要**在这里 `CVPixelBufferRelease`。
- (void)displayDecodedFrame:(CVImageBufferRef)imageBuffer;

/// 解码出错。
- (void)h264Decoder:(H264HwDecoderImpl *)decoder didFailWithError:(NSError *)error;

@end


/// H.264 硬件解码器。
///
/// 喂给它 Annex-B 码流即可，SPS / PPS 会自动收集；参数集变化时会自动重建解码会话，
/// 所以中途切分辨率、切摄像头都不需要额外处理。
///
/// 线程模型：`-decodeNalu:withSize:` 及其同类方法可以在任意队列调用，内部串行化。
/// delegate 回调发生在内部串行队列上，不是主队列。
@interface H264HwDecoderImpl : NSObject

@property (weak, nonatomic, nullable) id<H264HwDecoderImplDelegate> delegate;

/// 解码会话是否已建好（即已经收到过 SPS + PPS）。
@property (nonatomic, readonly, getter=isReady) BOOL ready;

/// 解一段 Annex-B 码流。可以包含任意多个 NAL 单元。
- (void)decodeAnnexB:(NSData *)annexB;

/// 解一个**不含**起始码的裸 NAL 单元载荷。
- (void)decodeNALUnitPayload:(NSData *)payload;

/// 丢弃已收集的参数集并销毁会话。下次收到 SPS / PPS 时重建。
- (void)reset;

#pragma mark - 兼容 1.x 的旧接口

/// 解一段 Annex-B 码流。
/// @warning 1.x 的实现会**原地改写** `frame` 指向的内存；本版不再改写入参。
- (void)decodeNalu:(uint8_t *)frame withSize:(uint32_t)frameSize;

- (BOOL)initH264Decoder __attribute__((deprecated("不再需要；收到 SPS/PPS 后会自动建会话")));

@end

NS_ASSUME_NONNULL_END
