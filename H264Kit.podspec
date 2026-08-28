Pod::Spec.new do |s|
  s.name             = 'H264Kit'
  s.version          = '2.0.0'
  s.summary          = 'iOS VideoToolbox 硬件 H.264 编解码封装（Objective-C）'

  s.description      = <<-DESC
                       基于 VideoToolbox 的 H.264 硬件编码 / 解码封装，外加 AVCC ↔ Annex-B
                       码流格式互转工具。

                       CocoaPods 只分发 Objective-C 版本（H264KitObjC）。
                       Swift 版本请通过 Swift Package Manager 引入。
                       DESC

  s.homepage         = 'https://github.com/chengxiaoyu00/H264ExampleS'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'rain' => 'chengxiaoyu@lbesec.com' }
  s.source           = { :git => 'https://github.com/chengxiaoyu00/H264ExampleS.git', :tag => s.version.to_s }

  s.ios.deployment_target = '12.0'

  s.source_files        = 'Sources/H264KitObjC/**/*.{h,m}'
  s.public_header_files = 'Sources/H264KitObjC/include/*.h'

  s.frameworks = 'Foundation', 'AVFoundation', 'VideoToolbox', 'CoreMedia', 'CoreVideo'

  s.requires_arc = true
end
