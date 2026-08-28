//
//  ViewController.m
//  VTH264examples Demo
//
//  摄像头 → H.264 硬编 → 硬解 → 上屏 的本机闭环演示。
//
//  左边是摄像头原始预览，右边是「编码后再解码」的画面，用来直观对比编码损失。
//  整条链路不走网络，编码器输出直接喂给解码器。
//
//  最初由徐杨创建于 2016 年，2.0 起重写。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import "ViewController.h"

#import <AVFoundation/AVFoundation.h>
@import H264KitObjC;

/// 编码分辨率。采集预设是 1280x720，这里按同样尺寸编码，避免多一次缩放。
static const int kEncodeWidth  = 1280;
static const int kEncodeHeight = 720;

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate,
                              H264HwEncoderImplDelegate,
                              H264HwDecoderImplDelegate>

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, strong) H264HwEncoderImpl *encoder;
@property (nonatomic, strong) H264HwDecoderImpl *decoder;
/// 解码后的画面直接用系统图层显示，不再需要自己写 OpenGL shader。
@property (nonatomic, strong) AVSampleBufferDisplayLayer *playbackLayer;

@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *switchCameraButton;
@property (nonatomic, strong) UILabel *statusLabel;

@property (nonatomic) AVCaptureDevicePosition cameraPosition;
@property (nonatomic) NSUInteger encodedByteCount;

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.cameraPosition = AVCaptureDevicePositionFront;

    self.encoder = [[H264HwEncoderImpl alloc] init];
    self.encoder.delegate = self;

    self.decoder = [[H264HwDecoderImpl alloc] init];
    self.decoder.delegate = self;

    [self setupSubviews];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    CGFloat top = self.view.safeAreaInsets.top + 60;
    CGFloat halfWidth = bounds.size.width / 2;
    CGFloat height = halfWidth * 4 / 3;

    self.previewLayer.frame  = CGRectMake(0, top, halfWidth, height);
    self.playbackLayer.frame = CGRectMake(halfWidth, top, halfWidth, height);
    self.statusLabel.frame   = CGRectMake(12, top + height + 12, bounds.size.width - 24, 40);
}

- (void)dealloc
{
    [self.captureSession stopRunning];
    [self.encoder stop];
}

#pragma mark - UI

- (void)setupSubviews
{
    self.toggleButton = [self buttonWithTitle:@"开摄像头" action:@selector(toggleCapture:)];
    self.toggleButton.frame = CGRectMake(16, 60, 120, 40);
    [self.view addSubview:self.toggleButton];

    self.switchCameraButton = [self buttonWithTitle:@"前后切换" action:@selector(switchCamera:)];
    self.switchCameraButton.frame = CGRectMake(152, 60, 120, 40);
    [self.view addSubview:self.switchCameraButton];

    self.playbackLayer = [[AVSampleBufferDisplayLayer alloc] init];
    self.playbackLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playbackLayer.backgroundColor = [UIColor darkGrayColor].CGColor;
    [self.view.layer addSublayer:self.playbackLayer];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"左：摄像头原始预览　右：编码后再解码";
    [self.view addSubview:self.statusLabel];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = [UIColor systemRedColor];
    button.layer.cornerRadius = 8;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - 按钮

- (void)toggleCapture:(UIButton *)sender
{
    if (self.captureSession.isRunning) {
        [self stopCapture];
        [sender setTitle:@"开摄像头" forState:UIControlStateNormal];
        return;
    }

    // iOS 10 起访问摄像头必须先申请授权，且 Info.plist 必须有
    // NSCameraUsageDescription —— 1.x 两样都没有，装到新系统上一开摄像头就闪退。
    [self requestCameraAccessWithCompletion:^(BOOL granted) {
        if (!granted) {
            self.statusLabel.text = @"没有摄像头权限，请到「设置」里打开。";
            return;
        }
        [self startCapture];
        [sender setTitle:@"关摄像头" forState:UIControlStateNormal];
    }];
}

- (void)switchCamera:(UIButton *)sender
{
    if (!self.captureSession.isRunning) { return; }

    self.cameraPosition = (self.cameraPosition == AVCaptureDevicePositionFront)
        ? AVCaptureDevicePositionBack
        : AVCaptureDevicePositionFront;

    [self stopCapture];
    [self startCapture];
}

- (void)requestCameraAccessWithCompletion:(void (^)(BOOL granted))completion
{
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
        case AVAuthorizationStatusAuthorized:
            completion(YES);
            break;
        case AVAuthorizationStatusNotDetermined: {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
            }];
            break;
        }
        default:
            completion(NO);
            break;
    }
}

#pragma mark - 采集

- (void)startCapture
{
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                 mediaType:AVMediaTypeVideo
                                                                  position:self.cameraPosition];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil) {
        self.statusLabel.text = [NSString stringWithFormat:@"打开摄像头失败：%@", error.localizedDescription];
        return;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };
    // 处理不过来时丢新帧，避免内存堆积。
    output.alwaysDiscardsLateVideoFrames = YES;
    [output setSampleBufferDelegate:self
                              queue:dispatch_queue_create("com.h264kit.demo.capture", DISPATCH_QUEUE_SERIAL)];

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    session.sessionPreset = AVCaptureSessionPreset1280x720;
    if ([session canAddInput:input])   { [session addInput:input]; }
    if ([session canAddOutput:output]) { [session addOutput:output]; }
    [session commitConfiguration];

    self.videoConnection = [output connectionWithMediaType:AVMediaTypeVideo];
    self.videoConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
    if (self.cameraPosition == AVCaptureDevicePositionFront && self.videoConnection.isVideoMirroringSupported) {
        self.videoConnection.videoMirrored = YES;
    }

    self.captureSession = session;

    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view.layer insertSublayer:self.previewLayer atIndex:0];
    [self.view setNeedsLayout];

    // 每次重开都重建编码会话；解码器会跟着新的 SPS/PPS 自动重建。
    if (![self.encoder prepareWithWidth:kEncodeWidth height:kEncodeHeight error:&error]) {
        self.statusLabel.text = [NSString stringWithFormat:@"编码器启动失败：%@", error.localizedDescription];
        return;
    }
    [self.decoder reset];
    self.encodedByteCount = 0;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session startRunning];
    });
}

- (void)stopCapture
{
    [self.captureSession stopRunning];
    self.captureSession = nil;
    self.videoConnection = nil;

    [self.previewLayer removeFromSuperlayer];
    self.previewLayer = nil;

    [self.encoder stop];
    [self.playbackLayer flushAndRemoveImage];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    [self.encoder encode:sampleBuffer];
}

#pragma mark - H264HwEncoderImplDelegate

// 注意：编码器的 delegate 回调发生在它自己的串行队列上，不是主队列。

- (void)gotSpsPps:(NSData *)sps pps:(NSData *)pps
{
    // 真实推流场景下，这里是把参数集发给对端；本 demo 直接转给本地解码器。
    NSMutableData *stream = [NSMutableData data];
    [stream appendData:H264AnnexBStartCode()];
    [stream appendData:sps];
    [stream appendData:H264AnnexBStartCode()];
    [stream appendData:pps];
    [self.decoder decodeAnnexB:stream];
}

- (void)gotEncodedData:(NSData *)data isKeyFrame:(BOOL)isKeyFrame
{
    self.encodedByteCount += data.length + 4;
    [self.decoder decodeNALUnitPayload:data];
}

- (void)h264Encoder:(H264HwEncoderImpl *)encoder didFailWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"编码出错：%@", error.localizedDescription];
    });
}

#pragma mark - H264HwDecoderImplDelegate

- (void)h264Decoder:(H264HwDecoderImpl *)decoder
     didDecodeFrame:(CVImageBufferRef)imageBuffer
presentationTimeStamp:(CMTime)presentationTimeStamp
{
    // imageBuffer 只在本次回调内有效，跨线程用必须自己 retain。
    CVPixelBufferRef pixelBuffer = CVPixelBufferRetain(imageBuffer);
    NSUInteger byteCount = self.encodedByteCount;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self displayPixelBuffer:pixelBuffer presentationTimeStamp:presentationTimeStamp];
        CVPixelBufferRelease(pixelBuffer);

        self.statusLabel.text = [NSString stringWithFormat:@"左：原始预览　右：编解码后\n累计码流 %.1f KB",
                                 byteCount / 1024.0];
    });
}

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer presentationTimeStamp:(CMTime)pts
{
    CMVideoFormatDescriptionRef formatDescription = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription) != noErr) {
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTIME_IS_VALID(pts) ? pts : kCMTimeZero,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                               pixelBuffer,
                                                               formatDescription,
                                                               &timing,
                                                               &sampleBuffer);
    CFRelease(formatDescription);
    if (status != noErr || sampleBuffer == NULL) { return; }

    // 实时流：来一帧显示一帧，不按 timebase 排程。
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    if (self.playbackLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.playbackLayer flush];
    }
    [self.playbackLayer enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
}

- (void)h264Decoder:(H264HwDecoderImpl *)decoder didFailWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"解码出错：%@", error.localizedDescription];
    });
}

@end
