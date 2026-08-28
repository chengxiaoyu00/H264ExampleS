//
//  H264NALU.m
//  H264Kit
//
//  H264NALU 的实现。
//
//  Copyright © 2016–2026 rain. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root.
//

#import "H264NALU.h"

static const uint8_t kStartCodeBytes[4] = { 0x00, 0x00, 0x00, 0x01 };

NSData *H264AnnexBStartCode(void)
{
    static NSData *startCode;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        startCode = [NSData dataWithBytes:kStartCodeBytes length:sizeof(kStartCodeBytes)];
    });
    return startCode;
}

H264NALUnitType H264NALUnitTypeOfPayload(NSData *payload)
{
    if (payload.length == 0) {
        return H264NALUnitTypeUnspecified;
    }
    uint8_t header = ((const uint8_t *)payload.bytes)[0];
    return (H264NALUnitType)(header & 0x1F);
}

NSData *H264AnnexBStreamFromPayloads(NSArray<NSData *> *payloads)
{
    NSMutableData *stream = [NSMutableData data];
    for (NSData *payload in payloads) {
        if (payload.length == 0) { continue; }
        [stream appendBytes:kStartCodeBytes length:sizeof(kStartCodeBytes)];
        [stream appendData:payload];
    }
    return stream;
}

/// 从 `offset` 起找下一个起始码，返回其位置；找不到返回 NSNotFound。
/// `outLength` 回填该起始码的长度（3 或 4）。
static NSUInteger H264FindStartCode(const uint8_t *bytes,
                                    NSUInteger length,
                                    NSUInteger offset,
                                    NSUInteger *outLength)
{
    for (NSUInteger i = offset; i + 2 < length; i++) {
        if (bytes[i] != 0x00 || bytes[i + 1] != 0x00) { continue; }
        if (bytes[i + 2] == 0x01) {
            if (outLength) { *outLength = 3; }
            return i;
        }
        if (i + 3 < length && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01) {
            if (outLength) { *outLength = 4; }
            return i;
        }
    }
    return NSNotFound;
}

NSArray<NSData *> *H264PayloadsFromAnnexBStream(NSData *stream)
{
    NSMutableArray<NSData *> *payloads = [NSMutableArray array];
    const uint8_t *bytes = stream.bytes;
    NSUInteger length = stream.length;

    NSUInteger startCodeLength = 0;
    NSUInteger cursor = H264FindStartCode(bytes, length, 0, &startCodeLength);
    while (cursor != NSNotFound) {
        NSUInteger payloadStart = cursor + startCodeLength;
        NSUInteger nextStartCodeLength = 0;
        NSUInteger next = H264FindStartCode(bytes, length, payloadStart, &nextStartCodeLength);
        NSUInteger payloadEnd = (next == NSNotFound) ? length : next;
        if (payloadEnd > payloadStart) {
            [payloads addObject:[stream subdataWithRange:NSMakeRange(payloadStart, payloadEnd - payloadStart)]];
        }
        cursor = next;
        startCodeLength = nextStartCodeLength;
    }
    return payloads;
}

NSArray<NSData *> *H264PayloadsFromAVCCStream(NSData *stream, NSUInteger lengthSize)
{
    NSMutableArray<NSData *> *payloads = [NSMutableArray array];
    if (lengthSize == 0 || lengthSize > 4) { return payloads; }

    const uint8_t *bytes = stream.bytes;
    NSUInteger total = stream.length;
    NSUInteger offset = 0;

    while (offset + lengthSize <= total) {
        uint32_t payloadLength = 0;
        for (NSUInteger i = 0; i < lengthSize; i++) {
            payloadLength = (payloadLength << 8) | bytes[offset + i];
        }
        offset += lengthSize;
        // 长度字段越界说明流被截断了，丢弃剩余部分而不是越界读取。
        if (payloadLength == 0 || offset + payloadLength > total) { break; }
        [payloads addObject:[stream subdataWithRange:NSMakeRange(offset, payloadLength)]];
        offset += payloadLength;
    }
    return payloads;
}

NSData *H264AVCCStreamFromPayloads(NSArray<NSData *> *payloads, NSUInteger lengthSize)
{
    NSMutableData *stream = [NSMutableData data];
    if (lengthSize == 0 || lengthSize > 4) { return stream; }

    for (NSData *payload in payloads) {
        if (payload.length == 0) { continue; }
        uint32_t payloadLength = (uint32_t)payload.length;
        uint8_t prefix[4];
        for (NSUInteger i = 0; i < lengthSize; i++) {
            prefix[i] = (uint8_t)((payloadLength >> (8 * (lengthSize - 1 - i))) & 0xFF);
        }
        [stream appendBytes:prefix length:lengthSize];
        [stream appendData:payload];
    }
    return stream;
}

NSData *H264AnnexBFromAVCC(NSData *avcc, NSUInteger lengthSize)
{
    return H264AnnexBStreamFromPayloads(H264PayloadsFromAVCCStream(avcc, lengthSize));
}

NSData *H264AVCCFromAnnexB(NSData *annexB, NSUInteger lengthSize)
{
    return H264AVCCStreamFromPayloads(H264PayloadsFromAnnexBStream(annexB), lengthSize);
}
