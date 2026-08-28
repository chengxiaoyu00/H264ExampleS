//
//  H264HwDecoderImpl.m
//  H264Kit
//
//  H264HwDecoderImpl 的实现。
//
//  最初由徐杨创建于 2016 年，2.0 起重写。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import "H264HwDecoderImpl.h"
#import "H264NALU.h"

@import VideoToolbox;

@interface H264HwDecoderImpl ()
{
    // 只在 _queue 上访问。
    NSData *_sps;
    NSData *_pps;
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _formatDescription;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@end

static void H264DecoderDidDecompress(void *decompressionOutputRefCon,
                                     void *sourceFrameRefCon,
                                     OSStatus status,
                                     VTDecodeInfoFlags infoFlags,
                                     CVImageBufferRef imageBuffer,
                                     CMTime presentationTimeStamp,
                                     CMTime presentationDuration);

@implementation H264HwDecoderImpl

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.h264kit.decoder", DISPATCH_QUEUE_SERIAL);
        _session = NULL;
        _formatDescription = NULL;
    }
    return self;
}

- (void)dealloc
{
    // dealloc 里不能再 dispatch_sync 到自己的队列（block 会捕获 self），直接拆。
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

- (void)reset
{
    dispatch_sync(self.queue, ^{
        [self teardownLocked];
        self->_sps = nil;
        self->_pps = nil;
    });
}

/// 必须在 _queue 上调用（dealloc 除外）。
- (void)teardownLocked
{
    if (_session != NULL) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription != NULL) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
}

#pragma mark - 输入

- (void)decodeAnnexB:(NSData *)annexB
{
    if (annexB.length == 0) { return; }
    for (NSData *payload in H264PayloadsFromAnnexBStream(annexB)) {
        [self decodeNALUnitPayload:payload];
    }
}

- (void)decodeNALUnitPayload:(NSData *)payload
{
    if (payload.length == 0) { return; }
    dispatch_async(self.queue, ^{
        [self processPayloadLocked:payload];
    });
}

- (void)decodeNalu:(uint8_t *)frame withSize:(uint32_t)frameSize
{
    if (frame == NULL || frameSize == 0) { return; }
    [self decodeAnnexB:[NSData dataWithBytes:frame length:frameSize]];
}

- (BOOL)initH264Decoder
{
    return self.isReady;
}

#pragma mark - 解码

/// 必须在 _queue 上调用。
- (void)processPayloadLocked:(NSData *)payload
{
    switch (H264NALUnitTypeOfPayload(payload)) {
        case H264NALUnitTypeSPS:
            // 参数集变了就得换会话，否则画面会花——这是 1.x 里 session 建好就永不重建留下的坑。
            if (![payload isEqualToData:_sps]) {
                _sps = payload;
                [self teardownLocked];
            }
            break;

        case H264NALUnitTypePPS:
            if (![payload isEqualToData:_pps]) {
                _pps = payload;
                [self teardownLocked];
            }
            break;

        case H264NALUnitTypeAUD:
        case H264NALUnitTypeSEI:
            break;

        default:
            if ([self ensureSessionLocked]) {
                [self decodePayloadLocked:payload];
            }
            break;
    }
}

/// 必须在 _queue 上调用。
- (BOOL)ensureSessionLocked
{
    if (_session != NULL) { return YES; }
    if (_sps == nil || _pps == nil) { return NO; }  // 参数集还没齐，这些帧只能丢

    const uint8_t * const parameterSetPointers[2] = { _sps.bytes, _pps.bytes };
    const size_t parameterSetSizes[2] = { _sps.length, _pps.length };

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          2,
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          4,   // AVCC 长度前缀字节数
                                                                          &_formatDescription);
    if (status != noErr) {
        [self reportError:status message:@"CMVideoFormatDescriptionCreateFromH264ParameterSets 失败"];
        return NO;
    }

    // 输出尺寸不写死——直接跟随 SPS 里解析出来的分辨率。
    // 1.x 在这里硬编码了 config.h 的常量并且宽高是反的，换分辨率就花屏。
    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = H264DecoderDidDecompress,
        .decompressionOutputRefCon = (__bridge void *)self,
    };

    status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                          _formatDescription,
                                          NULL,
                                          (__bridge CFDictionaryRef)pixelBufferAttributes,
                                          &callback,
                                          &_session);
    if (status != noErr) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
        [self reportError:status message:@"VTDecompressionSessionCreate 失败"];
        return NO;
    }

    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return YES;
}

/// 必须在 _queue 上调用。
- (void)decodePayloadLocked:(NSData *)payload
{
    // VideoToolbox 吃的是 AVCC，所以要把裸载荷加上 4 字节大端长度前缀。
    // 这里生成新 buffer，不像 1.x 那样去改调用方的内存。
    uint32_t length = (uint32_t)payload.length;
    uint32_t bigEndianLength = CFSwapInt32HostToBig(length);

    // objc_precise_lifetime：CMBlockBuffer 用的是 kCFAllocatorNull，不拷贝内存，
    // 所以 avcc 必须确定活到作用域结束（同步解码返回之后）。
    NSMutableData * __attribute__((objc_precise_lifetime)) avcc =
        [NSMutableData dataWithCapacity:payload.length + 4];
    [avcc appendBytes:&bigEndianLength length:4];
    [avcc appendData:payload];

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         (void *)avcc.bytes,
                                                         avcc.length,
                                                         kCFAllocatorNull,   // 内存由 avcc 持有
                                                         NULL,
                                                         0,
                                                         avcc.length,
                                                         0,
                                                         &blockBuffer);
    if (status != kCMBlockBufferNoErr) {
        [self reportError:status message:@"CMBlockBufferCreateWithMemoryBlock 失败"];
        return;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    const size_t sampleSizes[] = { avcc.length };
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       _formatDescription,
                                       1, 0, NULL,
                                       1, sampleSizes,
                                       &sampleBuffer);
    CFRelease(blockBuffer);

    if (status != noErr || sampleBuffer == NULL) {
        [self reportError:status message:@"CMSampleBufferCreateReady 失败"];
        return;
    }

    VTDecodeInfoFlags infoFlags = 0;
    // 同步解码：avcc 这块内存必须活到解码返回为止。
    status = VTDecompressionSessionDecodeFrame(_session,
                                               sampleBuffer,
                                               0,
                                               NULL,
                                               &infoFlags);
    CFRelease(sampleBuffer);

    if (status == kVTInvalidSessionErr) {
        // 会话失效（常见于 App 退到后台再回来），拆掉等下一组参数集重建。
        [self teardownLocked];
    } else if (status != noErr && status != kVTVideoDecoderBadDataErr) {
        [self reportError:status message:@"VTDecompressionSessionDecodeFrame 失败"];
    }
}

static void H264DecoderDidDecompress(void *decompressionOutputRefCon,
                                     void *sourceFrameRefCon,
                                     OSStatus status,
                                     VTDecodeInfoFlags infoFlags,
                                     CVImageBufferRef imageBuffer,
                                     CMTime presentationTimeStamp,
                                     CMTime presentationDuration)
{
    if (status != noErr || imageBuffer == NULL) { return; }

    H264HwDecoderImpl *decoder = (__bridge H264HwDecoderImpl *)decompressionOutputRefCon;
    id<H264HwDecoderImplDelegate> delegate = decoder.delegate;
    if (delegate == nil) { return; }

    // 所有权留在解码器这边：回调期间 imageBuffer 有效，delegate 想留就自己 retain。
    if ([delegate respondsToSelector:@selector(h264Decoder:didDecodeFrame:presentationTimeStamp:)]) {
        [delegate h264Decoder:decoder didDecodeFrame:imageBuffer presentationTimeStamp:presentationTimeStamp];
    } else if ([delegate respondsToSelector:@selector(displayDecodedFrame:)]) {
        [delegate displayDecodedFrame:imageBuffer];
    }
}

- (void)reportError:(OSStatus)status message:(NSString *)message
{
    NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"%@ (%d)", message, (int)status]}];
    NSLog(@"[H264Kit] %@", error.localizedDescription);

    id<H264HwDecoderImplDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(h264Decoder:didFailWithError:)]) {
        [delegate h264Decoder:self didFailWithError:error];
    }
}

@end
