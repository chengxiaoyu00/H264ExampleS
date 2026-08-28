//
//  H264NALU.h
//  H264Kit
//
//  H.264 码流的两种封装格式互转。
//
//  * AVCC    —— VideoToolbox 编码器输出的格式，每个 NAL 单元前是 4 字节大端长度。
//  * Annex-B —— 传输/落盘常用的格式，每个 NAL 单元前是 0x00000001 起始码。
//
//  这两者的互转是把 VideoToolbox 接到 RTMP / RTP / .h264 文件时绕不开的一步，
//  单独抽出来是为了能脱离设备做单元测试。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// H.264 NAL 单元类型（`nal_unit_type`，即首字节的低 5 位）。
typedef NS_ENUM(uint8_t, H264NALUnitType) {
    H264NALUnitTypeUnspecified   = 0,
    H264NALUnitTypeSliceNonIDR   = 1,  ///< 非关键帧片（P / B）
    H264NALUnitTypeSliceDPA      = 2,
    H264NALUnitTypeSliceDPB      = 3,
    H264NALUnitTypeSliceDPC      = 4,
    H264NALUnitTypeSliceIDR      = 5,  ///< 关键帧片（IDR）
    H264NALUnitTypeSEI           = 6,
    H264NALUnitTypeSPS           = 7,  ///< 序列参数集
    H264NALUnitTypePPS           = 8,  ///< 图像参数集
    H264NALUnitTypeAUD           = 9,  ///< 存取单元分隔符
};

/// 4 字节 Annex-B 起始码 `00 00 00 01`。
FOUNDATION_EXPORT NSData *H264AnnexBStartCode(void);

/// 取出 NAL 单元载荷（不含起始码/长度前缀）的类型。
/// @param payload 不含前缀的 NAL 单元数据；空数据返回 `H264NALUnitTypeUnspecified`。
FOUNDATION_EXPORT H264NALUnitType H264NALUnitTypeOfPayload(NSData *payload);

/// 把若干个 NAL 单元载荷拼成 Annex-B 码流（每个前面加 `00 00 00 01`）。
FOUNDATION_EXPORT NSData *H264AnnexBStreamFromPayloads(NSArray<NSData *> *payloads);

/// 从 Annex-B 码流中切出所有 NAL 单元载荷。3 字节和 4 字节起始码都能识别。
FOUNDATION_EXPORT NSArray<NSData *> *H264PayloadsFromAnnexBStream(NSData *stream);

/// 从 AVCC 码流（长度前缀）中切出所有 NAL 单元载荷。
/// @param lengthSize 长度前缀字节数，VideoToolbox 输出恒为 4。
FOUNDATION_EXPORT NSArray<NSData *> *H264PayloadsFromAVCCStream(NSData *stream, NSUInteger lengthSize);

/// 把若干个 NAL 单元载荷拼成 AVCC 码流（每个前面加大端长度前缀）。
FOUNDATION_EXPORT NSData *H264AVCCStreamFromPayloads(NSArray<NSData *> *payloads, NSUInteger lengthSize);

/// AVCC → Annex-B。
FOUNDATION_EXPORT NSData *H264AnnexBFromAVCC(NSData *avcc, NSUInteger lengthSize);

/// Annex-B → AVCC。
FOUNDATION_EXPORT NSData *H264AVCCFromAnnexB(NSData *annexB, NSUInteger lengthSize);

NS_ASSUME_NONNULL_END
