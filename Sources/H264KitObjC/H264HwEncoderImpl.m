//
//  H264HwEncoderImpl.m
//  H264Kit
//
//  H264HwEncoderImpl 的实现。
//
//  最初源自 Manish Ganvir 的 h264v1 示例（2015），
//  由徐杨于 2016 年引入本项目，2.0 起重写。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import "H264HwEncoderImpl.h"
#import "H264NALU.h"

@import VideoToolbox;

NSString * const H264KitErrorDomain = @"com.h264kit.error";


#pragma mark - Configuration

@implementation H264EncoderConfiguration

- (instancetype)initWithWidth:(int)width height:(int)height
{
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _averageBitRate = width * height * 8;
        _maxKeyFrameInterval = 30;
        _maxKeyFrameIntervalDuration = 2.0;
        _expectedFrameRate = 30;
        _profileLevel = (__bridge NSString *)kVTProfileLevel_H264_Baseline_AutoLevel;
        _realTime = YES;
        _allowFrameReordering = NO;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    H264EncoderConfiguration *copy = [[[self class] allocWithZone:zone] initWithWidth:_width height:_height];
    copy.averageBitRate = _averageBitRate;
    copy.maxKeyFrameInterval = _maxKeyFrameInterval;
    copy.maxKeyFrameIntervalDuration = _maxKeyFrameIntervalDuration;
    copy.expectedFrameRate = _expectedFrameRate;
    copy.profileLevel = _profileLevel;
    copy.realTime = _realTime;
    copy.allowFrameReordering = _allowFrameReordering;
    return copy;
}

@end

#pragma mark - Encoder

@interface H264HwEncoderImpl ()
{
    // 只在 _queue 上访问。
    VTCompressionSessionRef _session;
    int64_t _frameIndex;
    BOOL _forceKeyFrame;
    NSData *_lastSPS;
    NSData *_lastPPS;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) H264EncoderConfiguration *configuration;
@end

@implementation H264HwEncoderImpl

- (instancetype)init
{
    self = [super init];
    if (self) {
        // 串行队列：VTCompressionSession 不是线程安全的，而且送帧顺序必须保持。
        _queue = dispatch_queue_create("com.h264kit.encoder", DISPATCH_QUEUE_SERIAL);
        _session = NULL;
        _frameIndex = 0;
    }
    return self;
}

- (void)dealloc
{
    // dealloc 里不能 dispatch_sync 到自己的队列（block 会强引用正在析构的 self）。
    // 能走到 dealloc 就说明队列上已无待执行的 block，直接拆即可。
    [self teardownLocked];
}

- (BOOL)isReady
{
    __block BOOL ready = NO;
    dispatch_sync(self.queue, ^{
        ready = (self->_session != NULL);
    });
    return ready;
}

#pragma mark - 会话生命周期

static void H264EncoderDidCompress(void *outputCallbackRefCon,
                                   void *sourceFrameRefCon,
                                   OSStatus status,
                                   VTEncodeInfoFlags infoFlags,
                                   CMSampleBufferRef sampleBuffer);

- (BOOL)prepareWithWidth:(int)width height:(int)height error:(NSError **)error
{
    H264EncoderConfiguration *configuration = [[H264EncoderConfiguration alloc] initWithWidth:width height:height];
    return [self prepareWithConfiguration:configuration error:error];
}

- (BOOL)prepareWithConfiguration:(H264EncoderConfiguration *)configuration error:(NSError **)error
{
    if (configuration.width <= 0 || configuration.height <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:H264KitErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"编码宽高必须大于 0"}];
        }
        return NO;
    }

    __block OSStatus status = noErr;
    dispatch_sync(self.queue, ^{
        [self teardownLocked];

        status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                            configuration.width,
                                            configuration.height,
                                            kCMVideoCodecType_H264,
                                            NULL,
                                            NULL,
                                            NULL,
                                            H264EncoderDidCompress,
                                            (__bridge void *)self,
                                            &self->_session);
        if (status != noErr) { return; }

        [self setSessionProperty:kVTCompressionPropertyKey_RealTime
                           value:(configuration.realTime ? kCFBooleanTrue : kCFBooleanFalse)];
        [self setSessionProperty:kVTCompressionPropertyKey_AllowFrameReordering
                           value:(configuration.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse)];
        [self setSessionProperty:kVTCompressionPropertyKey_ProfileLevel
                           value:(__bridge CFStringRef)configuration.profileLevel];
        [self setSessionProperty:kVTCompressionPropertyKey_AverageBitRate
                           value:(__bridge CFNumberRef)@(configuration.averageBitRate)];
        if (configuration.maxKeyFrameInterval > 0) {
            [self setSessionProperty:kVTCompressionPropertyKey_MaxKeyFrameInterval
                               value:(__bridge CFNumberRef)@(configuration.maxKeyFrameInterval)];
        }
        if (configuration.maxKeyFrameIntervalDuration > 0) {
            [self setSessionProperty:kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration
                               value:(__bridge CFNumberRef)@(configuration.maxKeyFrameIntervalDuration)];
        }
        if (configuration.expectedFrameRate > 0) {
            [self setSessionProperty:kVTCompressionPropertyKey_ExpectedFrameRate
                               value:(__bridge CFNumberRef)@(configuration.expectedFrameRate)];
        }

        self->_frameIndex = 0;
        self->_forceKeyFrame = NO;
        self->_lastSPS = nil;
        self->_lastPPS = nil;
        VTCompressionSessionPrepareToEncodeFrames(self->_session);
    });

    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"VTCompressionSessionCreate 失败 (%d)", (int)status]}];
        }
        return NO;
    }

    self.configuration = configuration;
    return YES;
}

/// 必须在 _queue 上调用。
- (void)setSessionProperty:(CFStringRef)key value:(CFTypeRef)value
{
    if (_session == NULL || value == NULL) { return; }
    OSStatus status = VTSessionSetProperty(_session, key, value);
    if (status != noErr) {
        NSLog(@"[H264Kit] 设置编码属性 %@ 失败: %d", (__bridge NSString *)key, (int)status);
    }
}

/// 必须在 _queue 上调用。
- (void)teardownLocked
{
    if (_session == NULL) { return; }
    VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(_session);
    CFRelease(_session);
    _session = NULL;
}

- (void)stop
{
    dispatch_sync(self.queue, ^{
        [self teardownLocked];
    });
    self.configuration = nil;
}

#pragma mark - 编码

- (void)encode:(CMSampleBufferRef)sampleBuffer
{
    if (sampleBuffer == NULL) { return; }
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) { return; }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    [self encodePixelBuffer:imageBuffer presentationTimeStamp:pts duration:duration];
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
     presentationTimeStamp:(CMTime)presentationTimeStamp
                  duration:(CMTime)duration
{
    if (pixelBuffer == NULL) { return; }

    // 采集回调线程随时可能被复用，pixel buffer 必须自己持有到编码完成。
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(self.queue, ^{
        if (self->_session == NULL) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }

        CMTime pts = presentationTimeStamp;
        if (!CMTIME_IS_VALID(pts)) {
            // 没有可用时间戳时用帧序号兜底，时间基取 1000 便于换算成毫秒。
            int32_t fps = self.configuration.expectedFrameRate > 0 ? self.configuration.expectedFrameRate : 30;
            pts = CMTimeMake(self->_frameIndex * (1000 / fps), 1000);
        }
        self->_frameIndex++;

        NSDictionary *frameProperties = nil;
        if (self->_forceKeyFrame) {
            self->_forceKeyFrame = NO;
            frameProperties = @{ (__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
        }

        VTEncodeInfoFlags flags = 0;
        OSStatus status = VTCompressionSessionEncodeFrame(self->_session,
                                                          pixelBuffer,
                                                          pts,
                                                          duration,
                                                          (__bridge CFDictionaryRef)frameProperties,
                                                          NULL,
                                                          &flags);
        CVPixelBufferRelease(pixelBuffer);

        if (status != noErr) {
            [self teardownLocked];
            NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                                 code:status
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"VTCompressionSessionEncodeFrame 失败 (%d)", (int)status]}];
            id<H264HwEncoderImplDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(h264Encoder:didFailWithError:)]) {
                [delegate h264Encoder:self didFailWithError:error];
            }
        }
    });
}

- (void)requestKeyFrame
{
    dispatch_async(self.queue, ^{
        if (self->_session == NULL) { return; }
        self->_forceKeyFrame = YES;
        // 参数集一起清掉，好让下一个关键帧重新触发 -gotSpsPps: ——
        // 新加入的接收端需要拿到参数集才能建解码会话。
        self->_lastSPS = nil;
        self->_lastPPS = nil;
    });
}

#pragma mark - VideoToolbox 回调

/// 从 format description 里取出 SPS / PPS。参数集数量不固定，逐个按类型认。
static void H264ExtractParameterSets(CMFormatDescriptionRef format,
                                     NSData * __autoreleasing *outSPS,
                                     NSData * __autoreleasing *outPPS)
{
    if (format == NULL) { return; }

    size_t parameterSetCount = 0;
    OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &parameterSetCount, NULL);
    if (status != noErr) { return; }

    for (size_t index = 0; index < parameterSetCount; index++) {
        const uint8_t *pointer = NULL;
        size_t size = 0;
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &pointer, &size, NULL, NULL);
        if (status != noErr || pointer == NULL || size == 0) { continue; }

        NSData *payload = [NSData dataWithBytes:pointer length:size];
        switch (H264NALUnitTypeOfPayload(payload)) {
            case H264NALUnitTypeSPS: *outSPS = payload; break;
            case H264NALUnitTypePPS: *outPPS = payload; break;
            default: break;
        }
    }
}

static void H264EncoderDidCompress(void *outputCallbackRefCon,
                                   void *sourceFrameRefCon,
                                   OSStatus status,
                                   VTEncodeInfoFlags infoFlags,
                                   CMSampleBufferRef sampleBuffer)
{
    if (status != noErr || sampleBuffer == NULL) { return; }
    if (!CMSampleBufferDataIsReady(sampleBuffer)) { return; }
    if (infoFlags & kVTEncodeInfo_FrameDropped) { return; }

    H264HwEncoderImpl *encoder = (__bridge H264HwEncoderImpl *)outputCallbackRefCon;
    id<H264HwEncoderImplDelegate> delegate = encoder.delegate;
    if (delegate == nil) { return; }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    BOOL isKeyFrame = YES;
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
        isKeyFrame = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
    }

    if (isKeyFrame) {
        NSData *sps = nil;
        NSData *pps = nil;
        H264ExtractParameterSets(CMSampleBufferGetFormatDescription(sampleBuffer), &sps, &pps);
        // 参数集通常整段不变，只在真的换了的时候才通知解码端重建会话。
        if (sps != nil && pps != nil &&
            (![sps isEqualToData:encoder->_lastSPS] || ![pps isEqualToData:encoder->_lastPPS])) {
            encoder->_lastSPS = sps;
            encoder->_lastPPS = pps;
            [delegate gotSpsPps:sps pps:pps];
        }
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (blockBuffer == NULL) { return; }

    size_t totalLength = 0;
    char *dataPointer = NULL;
    if (CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer) != kCMBlockBufferNoErr) {
        return;
    }

    // VideoToolbox 输出的是 AVCC：4 字节大端长度 + 载荷，可能一帧里有多个 NAL 单元。
    static const size_t kAVCCHeaderLength = 4;
    size_t offset = 0;
    while (offset + kAVCCHeaderLength <= totalLength) {
        uint32_t nalUnitLength = 0;
        memcpy(&nalUnitLength, dataPointer + offset, kAVCCHeaderLength);
        nalUnitLength = CFSwapInt32BigToHost(nalUnitLength);
        offset += kAVCCHeaderLength;
        if (nalUnitLength == 0 || offset + nalUnitLength > totalLength) { break; }

        NSData *payload = [NSData dataWithBytes:dataPointer + offset length:nalUnitLength];
        [delegate gotEncodedData:payload isKeyFrame:isKeyFrame];
        offset += nalUnitLength;
    }
}

#pragma mark - 兼容 1.x

- (void)initWithConfiguration
{
    // 1.x 里这个方法只是把成员清零，现在 -init 已经做了。
}

- (void)initEncode:(int)width height:(int)height
{
    NSError *error = nil;
    if (![self prepareWithWidth:width height:height error:&error]) {
        NSLog(@"[H264Kit] initEncode 失败: %@", error.localizedDescription);
    }
}

@end
