//
//  H264HwEncoderImpl.h
//  H264Kit
//
//  基于 VideoToolbox VTCompressionSession 的 H.264 硬件编码器。
//
//  最初源自 Manish Ganvir 的 h264v1 示例（2015），
//  由徐杨于 2016 年引入本项目，2.0 起重写。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// 编码器参数。用 `-initWithWidth:height:` 拿一份默认值再按需改。
@interface H264EncoderConfiguration : NSObject <NSCopying>

/// 编码宽度，像素。必须 > 0。
@property (nonatomic) int width;
/// 编码高度，像素。必须 > 0。
@property (nonatomic) int height;
/// 平均码率，bps。默认 `width * height * 8`。
@property (nonatomic) int averageBitRate;
/// 关键帧最大间隔（帧数）。越小抗丢包越强、码流越大。默认 30。
@property (nonatomic) int maxKeyFrameInterval;
/// 关键帧最大间隔（秒）。0 表示不设置。默认 2。
@property (nonatomic) double maxKeyFrameIntervalDuration;
/// 预期帧率，用于码率控制。默认 30。
@property (nonatomic) int expectedFrameRate;
/// Profile / Level，取 `kVTProfileLevel_H264_*`。默认 Baseline AutoLevel。
@property (nonatomic, copy) NSString *profileLevel;
/// 实时编码模式（牺牲压缩率换低延迟）。默认 YES。
@property (nonatomic) BOOL realTime;
/// 是否允许帧重排（B 帧）。直播场景应保持 NO。默认 NO。
@property (nonatomic) BOOL allowFrameReordering;

/// 按给定分辨率生成一份默认配置，其余字段取上面各属性注明的默认值。
- (instancetype)initWithWidth:(int)width height:(int)height NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end


@class H264HwEncoderImpl;

@protocol H264HwEncoderImplDelegate <NSObject>

/// 编出关键帧时回调，给出该帧对应的 SPS / PPS（**不含**起始码）。
/// 收到新的一组参数集就意味着解码端需要重建会话。
- (void)gotSpsPps:(NSData *)sps pps:(NSData *)pps;

/// 每个 NAL 单元回调一次，`data` 是**不含**起始码也不含长度前缀的裸载荷。
/// 要拼 Annex-B 码流，在前面补 `H264AnnexBStartCode()`。
- (void)gotEncodedData:(NSData *)data isKeyFrame:(BOOL)isKeyFrame;

@optional

/// 编码过程中出错。出错后编码器已停止，需要重新 `prepare`。
- (void)h264Encoder:(H264HwEncoderImpl *)encoder didFailWithError:(NSError *)error;

@end


/// H.264 硬件编码器。
///
/// 线程模型：`-encode:` 可以在任意队列（包括 AVFoundation 的采集回调队列）调用，
/// 内部会切到自己的串行队列执行，保证送帧顺序。delegate 回调发生在该串行队列上，
/// 不是主队列——要更新 UI 请自行切回主队列。
@interface H264HwEncoderImpl : NSObject

@property (weak, nonatomic, nullable) id<H264HwEncoderImplDelegate> delegate;

/// 当前生效的配置；未 `prepare` 时为 nil。
@property (nonatomic, readonly, copy, nullable) H264EncoderConfiguration *configuration;

/// 编码器是否已就绪。
@property (nonatomic, readonly, getter=isReady) BOOL ready;

/// 创建并启动编码会话。重复调用会先销毁旧会话。
/// @return 成功返回 YES；失败返回 NO 并回填 `error`。
- (BOOL)prepareWithConfiguration:(H264EncoderConfiguration *)configuration
                           error:(NSError **)error;

/// 便捷写法，等价于用默认配置 `prepare`。
- (BOOL)prepareWithWidth:(int)width height:(int)height error:(NSError **)error;

/// 送一帧去编码。`sampleBuffer` 通常直接来自 `AVCaptureVideoDataOutput`。
- (void)encode:(CMSampleBufferRef)sampleBuffer;

/// 送一帧去编码，自己指定时间戳。
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
     presentationTimeStamp:(CMTime)presentationTimeStamp
                  duration:(CMTime)duration;

/// 要求下一帧编成关键帧（例如新观众加入时）。
- (void)requestKeyFrame;

/// 冲出所有排队中的帧并销毁会话。`dealloc` 时会自动调用。
- (void)stop;

#pragma mark - 兼容 1.x 的旧接口

- (void)initWithConfiguration __attribute__((deprecated("不再需要；改用 -prepareWithWidth:height:error:")));
- (void)initEncode:(int)width height:(int)height __attribute__((deprecated("改用 -prepareWithWidth:height:error:")));

@end

NS_ASSUME_NONNULL_END
