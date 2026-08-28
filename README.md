# H264Kit

[![SPM](https://img.shields.io/badge/SPM-supported-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2012%2B-lightgrey.svg)](#系统要求)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

iOS **VideoToolbox 硬件 H.264 编解码**封装，以及 **AVCC ↔ Annex-B** 码流格式互转。

同一个仓库提供两套实现，各自独立可用：

| Product | 语言 | 最低系统 | 接口风格 | 适合 |
|---|---|---|---|---|
| `H264KitObjC` | Objective-C | iOS 12 | delegate 回调 | 老项目接入、需要 CocoaPods |
| `H264Kit` | Swift | iOS 13 | `async/await` + `AsyncStream` | 新项目 |

> 本仓库前身是 2016 年的 `VTH264examples` 示例工程。2.0 把编解码核心抽成了独立的 SPM 包，
> 补上了 Swift 实现，并修掉了一批原版的内存与并发问题（见 [从 1.x 迁移](#从-1x-迁移)）。

---

## 目录

- [它能做什么](#它能做什么)
- [安装](#安装)
- [快速开始（Swift）](#快速开始swift)
- [快速开始（Objective-C）](#快速开始objective-c)
- [码流格式：AVCC 与 Annex-B](#码流格式avcc-与-annex-b)
- [API 说明](#api-说明)
- [线程模型](#线程模型)
- [Demo](#demo)
- [从 1.x 迁移](#从-1x-迁移)
- [系统要求](#系统要求)
- [版本与发布](#版本与发布)
- [常见问题](#常见问题)
- [License](#license)

---

## 它能做什么

```
                 ┌──────────────┐
 CVPixelBuffer ─▶│  H264Encoder │─▶ EncodedFrame ─┬─▶ Annex-B → 推流 / 落盘
 (摄像头/离屏渲染) └──────────────┘   (NAL 单元)    └─▶ AVCC   → MP4 / RTMP
                                                        │
                 ┌──────────────┐                       │
      上屏显示 ◀─│  H264Decoder │◀──────────────────────┘
    (CVPixelBuffer)└──────────────┘
```

具体包含：

- **硬件编码** —— 封装 `VTCompressionSession`，可配码率 / GOP / Profile / 帧率，支持强制关键帧
- **硬件解码** —— 封装 `VTDecompressionSession`，**参数集变化时自动重建会话**，中途切分辨率不花屏
- **码流互转** —— `AVCC ↔ Annex-B` 双向转换，NAL 单元切分与类型识别，纯字节运算、有单元测试覆盖
- **上屏渲染**（Swift 版）—— `AVSampleBufferDisplayLayer` 封装，含 UIKit / SwiftUI 视图

**不包含**：网络传输（RTMP / RTP / WebRTC）、音频、封装成 MP4。这些请配合 `AVAssetWriter`
或第三方推流库使用——本库负责的是「像素 ↔ H.264 码流」这一段。

---

## 安装

### Swift Package Manager（推荐）

在 Xcode 里 **File → Add Package Dependencies…**，填入仓库地址，然后按需勾选 product。

或者在 `Package.swift` 里：

```swift
dependencies: [
    .package(url: "https://github.com/chengxiaoyu00/H264ExampleS.git", from: "2.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            // 二选一，或者两个都要
            .product(name: "H264Kit",     package: "H264ExampleS"),   // Swift 版
            .product(name: "H264KitObjC", package: "H264ExampleS"),   // Objective-C 版
        ]
    )
]
```

### CocoaPods

CocoaPods **只分发 Objective-C 版本**。Swift 版请走 SPM。

```ruby
pod 'H264Kit', '~> 2.0'
```

### 手动接入 / iOS 12 以下

把 `Sources/H264KitObjC/` 整个目录拖进工程即可，没有第三方依赖。
需要支持 iOS 12 以下的老项目，请 checkout `v1.0.0`：

```bash
git checkout v1.0.0
```

---

## 快速开始（Swift）

### 编码

```swift
import AVFoundation
import H264Kit

let encoder = try H264Encoder(configuration: .init(width: 1280, height: 720))

// 消费编码结果
Task {
    for await frame in encoder.frames {
        // frame.annexB —— 关键帧会自动在前面拼上 SPS/PPS，可直接写 .h264 文件
        try? fileHandle.write(contentsOf: frame.annexB)

        // 或者按 NAL 单元自己打包
        for unit in frame.nalUnits where unit.type == .sliceIDR {
            print("关键帧，\(unit.payload.count) 字节")
        }
    }
}

// AVCaptureVideoDataOutput 的回调里直接送帧，不用切队列
func captureOutput(_ output: AVCaptureOutput,
                   didOutput sampleBuffer: CMSampleBuffer,
                   from connection: AVCaptureConnection) {
    encoder.encode(sampleBuffer)
}
```

调整参数：

```swift
var config = H264Encoder.Configuration(width: 1920, height: 1080)
config.averageBitRate = 4_000_000        // 4 Mbps
config.maxKeyFrameInterval = 60          // 每 60 帧一个关键帧
config.profileLevel = .highAutoLevel      // .baselineAutoLevel / .mainAutoLevel / .highAutoLevel
config.isRealTime = false                // 离线转码，换更好的压缩率

let encoder = try H264Encoder(configuration: config)
```

### 解码 + 上屏

```swift
import H264Kit

let decoder = H264Decoder()

Task { @MainActor in
    let renderer = VideoRenderer()            // 内部是 AVSampleBufferDisplayLayer
    renderer.layer.frame = view.bounds
    view.layer.addSublayer(renderer.layer)

    for await frame in decoder.frames {
        renderer.enqueue(frame)
    }
}

// 网络收到的 Annex-B 数据直接丢进来，SPS/PPS 会自动识别
decoder.decode(annexB: chunkFromNetwork)
```

SwiftUI：

```swift
struct PlayerView: View {
    let decoder: H264Decoder

    var body: some View {
        H264PlayerRepresentable(frames: decoder.frames)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }
}
```

### 编码 → 解码 直连（本机回环，用来验证链路）

```swift
Task {
    for await frame in encoder.frames {
        decoder.decode(frame)     // 参数集会一并带过去
    }
}
```

---

## 快速开始（Objective-C）

```objc
@import H264KitObjC;

@interface Recorder () <H264HwEncoderImplDelegate, H264HwDecoderImplDelegate>
@property (nonatomic, strong) H264HwEncoderImpl *encoder;
@property (nonatomic, strong) H264HwDecoderImpl *decoder;
@end

@implementation Recorder

- (void)setup
{
    self.encoder = [[H264HwEncoderImpl alloc] init];
    self.encoder.delegate = self;

    NSError *error = nil;
    if (![self.encoder prepareWithWidth:1280 height:720 error:&error]) {
        NSLog(@"编码器启动失败：%@", error.localizedDescription);
        return;
    }

    self.decoder = [[H264HwDecoderImpl alloc] init];
    self.decoder.delegate = self;
}

#pragma mark - 采集回调

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    [self.encoder encode:sampleBuffer];
}

#pragma mark - 编码回调（在编码器自己的串行队列上）

- (void)gotSpsPps:(NSData *)sps pps:(NSData *)pps
{
    // 只在参数集真的变化时才回调一次，收到就说明解码端需要重建会话
    NSMutableData *stream = [NSMutableData data];
    [stream appendData:H264AnnexBStartCode()];
    [stream appendData:sps];
    [stream appendData:H264AnnexBStartCode()];
    [stream appendData:pps];
    [self.decoder decodeAnnexB:stream];
}

- (void)gotEncodedData:(NSData *)data isKeyFrame:(BOOL)isKeyFrame
{
    // data 是不含起始码的裸 NAL 载荷
    [self.decoder decodeNALUnitPayload:data];
}

#pragma mark - 解码回调

- (void)h264Decoder:(H264HwDecoderImpl *)decoder
     didDecodeFrame:(CVImageBufferRef)imageBuffer
presentationTimeStamp:(CMTime)pts
{
    // imageBuffer 只在本次回调内有效，要跨线程用就自己 retain
    CVPixelBufferRef buffer = CVPixelBufferRetain(imageBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self display:buffer];
        CVPixelBufferRelease(buffer);
    });
}

@end
```

自定义编码参数：

```objc
H264EncoderConfiguration *config =
    [[H264EncoderConfiguration alloc] initWithWidth:1920 height:1080];
config.averageBitRate = 4000000;
config.maxKeyFrameInterval = 60;
config.profileLevel = (__bridge NSString *)kVTProfileLevel_H264_High_AutoLevel;

[self.encoder prepareWithConfiguration:config error:&error];
```

---

## 码流格式：AVCC 与 Annex-B

这是接 VideoToolbox 时最容易踩的地方，单独说明。

同一份 H.264 数据有两种封装：

```
Annex-B     00 00 00 01 | 67 42 ...     00 00 00 01 | 65 88 ...
            └─ 起始码 ─┘  └─ SPS ─┘      └─ 起始码 ─┘  └─ IDR ─┘
            用于：.h264 文件、RTP、TS 流

AVCC        00 00 00 04 | 67 42 ...     00 00 01 A3 | 65 88 ...
            └─ 长度 ──┘  └─ SPS ─┘      └─ 长度 ──┘  └─ IDR ─┘
            用于：VideoToolbox 输入输出、MP4、FLV/RTMP
```

**VideoToolbox 的编码器输出 AVCC，解码器也只吃 AVCC。** 而落盘和大部分传输协议用 Annex-B。
本库把这层转换做成了独立的纯函数：

```swift
// Swift
let annexB = avccData.avccToAnnexB()
let avcc   = annexBData.annexBToAVCC()

let units = AnnexB.nalUnits(in: stream)          // 切成 NAL 单元
units.first?.type                                 // .sps / .pps / .sliceIDR / ...
AVCC.stream(from: units, lengthSize: 4)           // 重新拼回去
```

```objc
// Objective-C
NSData *annexB = H264AnnexBFromAVCC(avcc, 4);
NSData *avcc   = H264AVCCFromAnnexB(annexB, 4);

NSArray<NSData *> *payloads = H264PayloadsFromAnnexBStream(stream);
H264NALUnitType type = H264NALUnitTypeOfPayload(payloads.firstObject);
```

两套实现有 [parity 测试](Tests/H264KitTests/ObjCParityTests.swift)互相校验，输出保证一致。

**另外注意**：SPS / PPS 不在编码器的普通数据回调里，要从 format description 单独取
（本库已经处理，通过 `gotSpsPps:` / `EncodedFrame.parameterSets` 给出）。解码端**必须先拿到
SPS + PPS 才能建会话**，参数集到齐之前收到的图像帧只能丢弃。

---

## API 说明

### Swift

| 类型 | 说明 |
|---|---|
| `H264Encoder` | 硬件编码器。`frames: AsyncStream<EncodedFrame>` 出结果 |
| `H264Encoder.Configuration` | 宽高、码率、GOP、Profile、实时模式、帧重排 |
| `ProfileLevel` | Profile / Level，`.baselineAutoLevel` / `.mainAutoLevel` / `.highAutoLevel` |
| `EncodedFrame` | 一帧的 NAL 单元集合 + 是否关键帧 + PTS + 参数集；`.annexB` / `.avcc()` 取码流 |
| `H264Decoder` | 硬件解码器。`frames: AsyncStream<DecodedFrame>` 出结果 |
| `DecodedFrame` | `CVPixelBuffer` + PTS |
| `VideoRenderer` | `AVSampleBufferDisplayLayer` 封装（`@MainActor`） |
| `H264PlayerView` | 用显示图层做 backing layer 的 `UIView` |
| `H264PlayerRepresentable` | SwiftUI 包装 |
| `NALUnit` / `NALUnitType` | 单个 NAL 单元及其类型 |
| `AnnexB` / `AVCC` | 两种封装格式的解析与生成 |
| `ParameterSets` | 一组 SPS + PPS |
| `H264KitError` | 错误类型，带 `LocalizedError` |

### Objective-C

| 类型 | 说明 |
|---|---|
| `H264HwEncoderImpl` | 硬件编码器，delegate 出结果 |
| `H264EncoderConfiguration` | 编码参数 |
| `H264HwEncoderImplDelegate` | `gotSpsPps:pps:` / `gotEncodedData:isKeyFrame:` / `h264Encoder:didFailWithError:` |
| `H264HwDecoderImpl` | 硬件解码器，delegate 出结果 |
| `H264HwDecoderImplDelegate` | `displayDecodedFrame:` / `h264Decoder:didDecodeFrame:presentationTimeStamp:` / `h264Decoder:didFailWithError:` |
| `H264NALUnitType` + `H264*` 系列 C 函数 | 码流格式互转 |

---

## 线程模型

两套实现的规则一致：

- **送帧方法（`encode` / `decode`）可以在任意队列调用**，包括 `AVCaptureVideoDataOutput`
  的采集回调队列。内部各有一条串行队列，保证送帧顺序。
- **回调 / AsyncStream 的输出不在主队列上。** 要更新 UI 请自己切回主线程
  （Swift 版的 `VideoRenderer` 已标 `@MainActor`）。
- Swift 版刻意用 `final class` + 串行 `DispatchQueue` 而不是 `actor`——
  向 actor 投递的 `Task` 不保证 FIFO，视频帧一旦乱序就会花屏。

Objective-C 版解码回调里的 `CVImageBufferRef` **只在回调期间有效**，跨线程使用必须自己
`CVPixelBufferRetain` / `CVPixelBufferRelease`。Swift 版由 `AsyncStream` 持有，不需要手工管理。

---

## Demo

[`Demo/VTH264examples.xcodeproj`](Demo/) 是一个本机闭环示例：摄像头采集 → 硬编 → 硬解 → 上屏，
左右并排显示「原始预览」和「编解码后的画面」，用来直观看编码损失。它通过本地路径依赖
引用同仓库的 `H264KitObjC`，可以直接当作接入示例。

```bash
open Demo/VTH264examples.xcodeproj
```

需要真机运行（模拟器没有摄像头）。

---

## 从 1.x 迁移

1.x 是 2016 年的原始实现。2.0 修掉了下面这些问题，其中前四条是会实际出错的 bug：

| 问题 | 1.x 的表现 | 2.0 |
|---|---|---|
| **缺少相机权限声明** | iOS 10+ 一开摄像头直接闪退 | Demo 补齐 `NSCameraUsageDescription` 并主动申请授权 |
| **SPS / PPS 内存泄漏** | 每收到一个参数集 `malloc` 一次且从不 `free` | 改用 `NSData`，随对象释放 |
| **解码会话永不重建** | 参数集变化后继续用旧会话，切分辨率必花屏 | 检测到参数集变化自动重建 |
| **解码输出尺寸写死** | 硬编码常量且宽高写反，和实际采集尺寸对不上 | 跟随 SPS 解析出的分辨率 |
| **`dispatch_sync` 到全局并发队列** | 以为串行化了其实没有，`frameCount++` 数据竞争 | 各自的私有串行队列 |
| **原地改写调用方内存** | `decodeNalu:` 直接改传入 buffer 的前 4 字节 | 生成新 buffer，入参只读 |
| **会话无销毁** | 无 `dealloc`，退出时泄漏 VT session | `stop()` + `dealloc` 完整拆除 |
| **参数集索引写死** | 假定 index 0 是 SPS、1 是 PPS | 按 NAL 类型逐个识别 |
| **`[Class alloc]` 未 init** | 靠 ivar 归零侥幸能跑 | 正常 `init` |
| **OpenGL ES 渲染** | `AAPLEAGLLayer`，594 行，iOS 12 起废弃 | 换成 `AVSampleBufferDisplayLayer` |

### 接口对照

```objc
// 1.x
h264Encoder = [H264HwEncoderImpl alloc];        // 注意：没有 init
[h264Encoder initWithConfiguration];
[h264Encoder initEncode:800 height:600];

// 2.0
H264HwEncoderImpl *encoder = [[H264HwEncoderImpl alloc] init];
NSError *error = nil;
[encoder prepareWithWidth:1280 height:720 error:&error];
```

```objc
// 1.x —— 自己拼起始码，然后传裸指针
NSMutableData *h264Data = [NSMutableData data];
[h264Data appendData:ByteHeader];
[h264Data appendData:data];
[h264Decoder decodeNalu:(uint8_t *)[h264Data bytes] withSize:(uint32_t)h264Data.length];

// 2.0 —— 直接给裸载荷
[decoder decodeNALUnitPayload:data];
// 或者给一整段 Annex-B
[decoder decodeAnnexB:stream];
```

```objc
// 1.x —— delegate 负责 release，很容易漏
- (void)displayDecodedFrame:(CVImageBufferRef)imageBuffer {
    playLayer.pixelBuffer = imageBuffer;
    CVPixelBufferRelease(imageBuffer);          // 所有权在 delegate 这边
}

// 2.0 —— 所有权留在解码器，delegate 想留才 retain
- (void)h264Decoder:(H264HwDecoderImpl *)decoder
     didDecodeFrame:(CVImageBufferRef)imageBuffer
presentationTimeStamp:(CMTime)pts {
    CVPixelBufferRef buffer = CVPixelBufferRetain(imageBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self display:buffer];
        CVPixelBufferRelease(buffer);
    });
}
```

`initWithConfiguration` / `initEncode:height:` / `initH264Decoder` / `decodeNalu:withSize:`
仍然保留（标了 `deprecated`），老代码可以先跑起来再逐步迁移。
其中 `decodeNalu:withSize:` 的行为有一处**不兼容变化**：不再改写传入的 buffer。

---

## 系统要求

| | 最低系统 | 说明 |
|---|---|---|
| `H264KitObjC` | iOS 12.0 | |
| `H264Kit` | iOS 13.0 | `async/await` 回溯部署的下限 |
| Swift | 5.9 | |
| Xcode | 15.0 | |

SPM 的 `platforms` 是包级的，没法按 target 区分，所以 `Package.swift` 里写的是 iOS 12
（两者的下限），Swift 版的 API 统一标了 `@available(iOS 13.0, *)`。

---

## 版本与发布

| Tag | 内容 | 分发方式 |
|---|---|---|
| `v1.0.0` | 2016–2018 年的原始 Objective-C 实现，未修 bug | 源码（`git checkout v1.0.0`） |
| `v2.0.0` | SPM 双 product，OC 版修复 + Swift 版新增 | SPM / CocoaPods / 源码 |

`v1.0.0` 保留是为了给还在引用旧代码的项目留一个可对照的基线，以及支持 iOS 12 以下的设备。
新项目请直接用 `v2.0.0`。

---

## 常见问题

**Q：解码后画面全绿 / 花屏？**
A：多半是关键帧丢了数据。传输时 IDR 帧不能丢，P / B 帧丢了只会卡顿。
另外确认 SPS / PPS 已经先于第一个 IDR 帧送到解码器。

**Q：只解出一帧就不动了？**
A：检查是不是每帧都在重建解码会话。参数集没变时不应该重建——本库只在参数集
真的发生变化时才重建，如果你自己做了封装，注意别在每个关键帧都 reset。

**Q：App 退到后台再回来就不解码了？**
A：`VTDecompressionSession` 会失效（`kVTInvalidSessionErr`）。本库检测到后会自动拆掉会话，
等下一组 SPS / PPS 到达时重建——所以要确保发送端能重新发参数集
（Swift 版调 `encoder.requestKeyFrame()`，OC 版调 `-requestKeyFrame`）。

**Q：为什么不用 `actor`？**
A：向 actor 投递的 `Task` 不保证 FIFO。视频帧顺序一乱就花屏，所以用了串行 `DispatchQueue`。

**Q：支持 H.265 / HEVC 吗？**
A：暂不支持。VideoToolbox 侧只需要换 `kCMVideoCodecType_HEVC`，但 NAL 头格式不同
（HEVC 的类型字段是 6 位、在第二个字节），码流层需要另写一套。

**Q：能推流吗？**
A：本库不含网络层。拿 `EncodedFrame.annexB`（或 `.avcc()`）自己接 RTMP / RTP 库即可。

---

## License

MIT。详见 [LICENSE](LICENSE)。

`Sources/H264KitObjC` 的编解码逻辑最初改写自 Manish Ganvir 的 h264v1 示例；
1.x 里的 `AAPLEAGLLayer` 来自 Apple 官方示例代码，2.0 起已移除。
