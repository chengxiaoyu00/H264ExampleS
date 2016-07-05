//
//  ViewController.h
//  VTH264examples
//
//  Created by 徐杨 on 16/5/3.
//  Copyright (c) 2016年 srd. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "H264HwEncoderImpl.h"
#import "H264HwDecoderImpl.h"
@interface ViewController : UIViewController<AVCaptureVideoDataOutputSampleBufferDelegate,H264HwEncoderImplDelegate,H264HwDecoderImplDelegate>



@end

