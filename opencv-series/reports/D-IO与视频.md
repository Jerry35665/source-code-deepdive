# 报告 D|IO 与视频:imgcodecs、videoio 与后端工厂

> 基线:opencv 4.x,d3d247f1e3125f03171e59ed8fd2fe9454b8ee5f(2025-11-05)。
> 行号均经本次实际 Read/Grep 核对。路径相对仓库根。

## 0. 总览图

```
                        imread("a.png", IMREAD_COLOR)
                                |
              +-----------------v--------------------------+
              | fopen 读前 maxlen 字节(maxlen=各解码器      | loadsave.cpp:269-286
              | 签名长度最大值)                            |
              +-----------------+--------------------------+
                                |
              +-----------------v--------------------------+
              | 遍历解码器表逐个 checkSignature:            | grfmt_base.cpp:117-120
              | BMP/GIF/AVIF/HDR/JPEG/WEBP/PXM/PFM/TIFF/   | loadsave.cpp:165-240
              | PNG(spng|libpng)/GDCM/Jasper/JXL/OpenJPEG/ |
              | OpenEXR/GDAL -> 命中即 newDecoder()         |
              +-----------------+--------------------------+
                                |
              +-----------------v--------------------------+
              | readHeader -> validateInputImageSize       | loadsave.cpp:578
              | -> calcType(flags) 定输出类型              | loadsave.cpp:581
              | -> readData(Mat) -> EXIF 旋转/缩小收尾      | loadsave.cpp:601-632
              +--------------------------------------------+

  imencode(".png", img, buf, params):  扩展名 -> findEncoder(loadsave.cpp:327)
      -> encoder->write(mat, params_kv);params 必须成对(键值 int 对)

  VideoCapture::open("f.mp4")  // CAP_ANY=0 时按注册序轮询
    注册序即优先级: priority = 1000 - i*10        videoio_registry.cpp:226-230
      FFMPEG(1000) > GSTREAMER > INTEL_MFX > AVFOUNDATION > WINRT
      > MSMF > DSHOW > V4L2 > FFMPEG(相机) > OPENNI2 > REALSENSE
      > CV_IMAGES > CV_MJPEG > FIREWIRE/PVAPI/XIMEA/ARAVIS/UEYE/GPHOTO2/XINE
      > ANDROID_NATIVE > OBSENSOR                    videoio_registry.cpp:66-197
    每个后端: factory->getBackend()->createCapture(file, params)
      -> isOpened() ? 用它 : 继续下一个               cap.cpp:130-208
```

## 1. imgcodecs:签名探测的静态图管线

### 1.1 注册表与 findDecoder

所有编码解码器在进程首次调用时由单例 `ImageCodecInitializer` 构造,按 `#ifdef HAVE_*` 装入两个 vector(loadsave.cpp:157-245;单例入口 getCodecs:loadsave.cpp:247-252)。`imread` 路径的格式识别完全不看扩展名:先算出所有解码器签名的最大长度,读文件头部同样多字节,再逐个 `checkSignature` 比对(文件版 loadsave.cpp:261-297;内存版 imdecode 用的 `findDecoder(const Mat&)` 逻辑相同,loadsave.cpp:299-325)。

```cpp
// loadsave.cpp:282-293(节选)
    // read the file signature
    String signature(maxlen, ' ');
    maxlen = fread( (void*)signature.c_str(), 1, maxlen, f );
    fclose(f);
    signature = signature.substr(0, maxlen);

    /// compare signature against all decoders
    for( i = 0; i < codecs.decoders.size(); i++ )
    {
        if( codecs.decoders[i]->checkSignature(signature) )
            return codecs.decoders[i]->newDecoder();
    }
```

签名比对基类实现是简单前缀 memcmp(grfmt_base.cpp:112-120,成员 `m_signature` 见 grfmt_base.hpp:186)。解码基类以方法多态:每个 grfmt_* 文件实现 `readHeader/readData/nextPage` 等。与读相反,**写路径按扩展名选编码器**:`findEncoder` 取末尾 `.` 后的字母数字段,与各编码器 `getDescription()` 里括号内的扩展名串匹配(loadsave.cpp:327-352);找不到直接 `CV_Error`(loadsave.cpp:1069-1071)。

### 1.2 编解码器 wrapper 一览(文件 → 一句话)

- grfmt_bmp.cpp — BMP 自研实现,`BmpDecoder::readHeader` 在 :81,`BmpEncoder::write` 在 :617(注册 loadsave.cpp:165-166)。
- grfmt_png.cpp / grfmt_spng.cpp — PNG 双实现:libpng(`PngDecoder::readHeader` :251,`PngEncoder::write` :959,另含 APNG `writeanimation` :1625)与 libspng(`SPngDecoder::readHeader` :111,`SPngEncoder::write` :513);二者互斥注册,SPNG 优先(loadsave.cpp:209-215)。
- grfmt_jpeg.cpp — libjpeg-turbo 包装,`JpegDecoder::readHeader` :220,`JpegEncoder::write` :632(注册 loadsave.cpp:180-183)。
- grfmt_webp.cpp — libwebp,`WebPDecoder::readHeader` :108,`WebPEncoder::write` :351,动画 :498(注册 loadsave.cpp:184-187)。
- grfmt_tiff.cpp — libtiff,`TiffDecoder::readHeader` :325,`TiffEncoder::writeLibTiff` :1293(注册 loadsave.cpp:205-208);TIFF 是多页(imreadmulti)主力格式。
- grfmt_exr.cpp — OpenEXR,`ExrDecoder::readHeader` :148,`ExrEncoder::write` :759(注册 loadsave.cpp:232-235);EXR 是唯一允许非常规通道数的特例(见 imwrite_ 中 `encoder.dynamicCast<ExrEncoder>()` 逃逸,loadsave.cpp:1078-1082)。
- grfmt_avif.cpp — libavif,`AvifDecoder::readHeader` :210,`AvifEncoder::writeanimation` :333(注册 loadsave.cpp:172-175)。
- grfmt_jpegxl.cpp — libjxl,`JpegXLDecoder::readHeader` :95(注册 loadsave.cpp:223-226)。
- grfmt_jpeg2000.cpp / grfmt_jpeg2000_openjpeg.cpp — 旧 Jasper 实现与 OpenJPEG 实现,读取分量循环见 grfmt_jpeg2000.cpp:325(注册 loadsave.cpp:219-231)。
- grfmt_pxm.cpp / grfmt_pfm.cpp — PNM 族(PBM/PGM/PPM/PAM)自研,`PxMDecoder::readHeader` :141;PFM 浮点图,`PFMDecoder::readHeader` :87(注册 loadsave.cpp:192-204)。
- grfmt_hdr.cpp + rgbe.cpp — Radiance HDR 自研(RGBE 编解码,注册 loadsave.cpp:176-179)。
- grfmt_gif.cpp — GIF 自研,`GifDecoder::readHeader` :36,`GifEncoder::writeanimation` :565(注册 loadsave.cpp:168-171)。
- grfmt_gdcm.cpp / grfmt_gdal.cpp — 分别为 DICOM(GDCM 只解码,loadsave.cpp:216-218)与遥感栅格 GDAL(imread 时 `IMREAD_LOAD_GDAL` 直接旁路签名探测指定 GDAL 解码器,loadsave.cpp:515-523;注册 loadsave.cpp:237-240)。

### 1.3 IMREAD_* 标志的语义

标志在公开头定义:IMREAD_UNCHANGED 之外的核心位有 GRAYSCALE=0/COLOR=1/ANYDEPTH=2/ANYCOLOR=4/LOAD_GDAL=8、REDUCED_*_2/4/8=16..65、IMREAD_IGNORE_ORIENTATION=128(modules/imgcodecs/include/opencv2/imgcodecs.hpp:71-83)。三件事由这些位驱动:

1. **输出类型推导 `calcType`**(loadsave.cpp:84-111):非 UNCHANGED 时,若未给 ANYDEPTH 则强制 8U;COLOR/RGB/ANYCOLOR(多通道图)则 3 通道,否则 1 通道;COLOR_BGR 与 COLOR_RGB 互斥由 `CV_CheckNE` 守卫(loadsave.cpp:88-90)。
2. **缩小读**:`flags > IMREAD_LOAD_GDAL` 时按 REDUCED 位设 `scale_denom=2/4/8`,交给 `decoder->setScale`;JPEG 在解码器内部直接降采样(loadsave.cpp:531-548 注释 loadsave.cpp:623:仅 JPEG `setScale` 恒返回 1),其余格式由 imread 收尾 `resize(..., INTER_LINEAR_EXACT)`(loadsave.cpp:623-626)。
3. **EXIF 方向**:非 UNCHANGED 且未 IGNORE_ORIENTATION 时按 EXIF Orientation 旋转(loadsave.cpp:629-632,ApplyExifOrientation 调用)。

读端还有 OOM/解压炸弹护栏:`OPENCV_IO_MAX_IMAGE_WIDTH/HEIGHT/PIXELS/PARAMS` 四个环境变量默认限 2^20 边长、2^30 像素(loadsave.cpp:67-70),`validateInputImageSize` 在 readHeader 后立即断言(loadsave.cpp:72-81,调用 :578)。imread 失败不抛异常而是记 ERROR 日志并返回空 Mat(readHeader/readData 各有 catch 分支,loadsave.cpp:565-574、609-621)——历史 API 承诺。内存版 `imdecode_`(loadsave.cpp:1305)与文件版唯一的入口差异是 `findDecoder(const Mat&)`(:1316),后续类型推导/EXIF/缩小逻辑逐行镜像;带元数据变体 `imreadWithMetadata/imdecodeWithMetadata` 通过 `setReadOptions(1)` 让解码器顺带产出元数据通道(loadsave.cpp:553-557、607)。

### 1.4 多页读取与 Animation

`imreadmulti_` 复用同一 findDecoder,先 `nextPage()` 快进到 `start`,再循环 `readData + nextPage` 直到 count 或页尾(loadsave.cpp:690-740)——TIFF 多页与 EXR 单文件多 part 走这条路;`imcount` 用惰性 `ImageCollection` 只数页数(loadsave.cpp:1041-1051;Impl 定义 loadsave.cpp:1790)。GIF/AVIF/WebP 动画另有 `Animation` 容器与 `imreadanimation/imencodeanimation`(imencodeanimation_:loadsave.cpp:1272-1301)。

### 1.5 imencode 与参数向量(intvector)

`imencode` 是 `imencodeWithMetadata` 的薄封装(loadsave.cpp:1766-1770)。参数 `std::vector<int> params` 是**键值成对的 int 向量**(如 IMWRITE_JPEG_QUALITY=1、IMWRITE_PNG_COMPRESSION=16,枚举见 imgcodecs.hpp:89-126),处理规则:

```cpp
// loadsave.cpp:1125-1146(节选)
    CV_Check(params.size(), (params.size() & 1) == 0, "Encoding 'params' must be key-value pairs");
    CV_CheckLE(params.size(), (size_t)(CV_IO_MAX_IMAGE_PARAMS*2), "");

    for(size_t v = 0; v < params.size(); v+= 2)
    {
        const int key = params[v];
        if(encoder->isValidEncodeKey(key))
        { ... }                                        // 本编码器认识:生效
        else if(isValidEncodeKeyAtAll(key))
        { ...警告忽略... }                              // 别家认识:忽略
        else
        { ...警告忽略... }                              // 全都 不认识:忽略
    }
```

上限 `CV_IO_MAX_IMAGE_PARAMS=50` 对(loadsave.cpp:67,1126)。深度不匹配时静默降为 CV_8U(loadsave.cpp:1086-1092);另有 4.x 过渡兼容:HDR 编码器收到旧式单值参数时自动补 IMWRITE_HDR_COMPRESSION 键(loadsave.cpp:1106-1120)。写失败时尝试探测可写性并删除残留文件(loadsave.cpp:1156-1171)。`imwrite_`/`imencodeWithMetadata` 两处逻辑几乎复制(loadsave.cpp:1061-1180 与 1633-1763),是 4.x 冻结期典型的兼容副本。

## 2. videoio:后端工厂与轮询

### 2.1 CAP_* 枚举与优先级

后端 ID 是稳定的历史数值:CAP_ANY=0、CAP_DSHOW=700、CAP_MSMF=1400、CAP_AVFOUNDATION=1200、CAP_GSTREAMER=1800、CAP_FFMPEG=1900、CAP_IMAGES=2000、CAP_OPENCV_MJPEG=2200、CAP_INTEL_MFX=2300(modules/videoio/include/opencv2/videoio.hpp:96-131)。静态表 `builtin_backends` 按注释中的排序方针书写("modern optimized, multi-platform libraries: ffmpeg, gstreamer...",videoio_registry.cpp:58-65),FFMPEG 在最前(videoio_registry.cpp:69-70)。**优先级由数组下标派生**:`info.priority = 1000 - i*10`(videoio_registry.cpp:226-230;默认值 1000 亦写在 DECLARE 宏里,videoio_registry.cpp:40-56)。两个环境变量可覆盖:`OPENCV_VIDEOIO_PRIORITY_<NAME>` 调单个后端、设 0 即禁用(videoio_registry.cpp:242-253);`OPENCV_VIDEOIO_PRIORITY_LIST` 以 100000+ 重排整个次序(videoio_registry.cpp:272-302)。每个后端带模式位:BY_INDEX/BY_FILENAME/BY_STREAM/MODE_WRITER(videoio_registry.hpp:14-26),因此"文件捕获序"与"相机捕获序"、"Writer 序"是三张不同的表(getAvailableBackends_CaptureByFilename/Writer,videoio_registry.cpp:448-470)。

### 2.2 open 轮询与工厂

`VideoCapture::open(filename, apiPreference, params)` 拿到按优先级排序的表,`CAP_ANY` 时逐一尝试,直到某后端 `isOpened()` 为真(cap.cpp:120-208):

```cpp
// cap.cpp:130-158(节选)
    const std::vector<VideoBackendInfo> backends = cv::videoio_registry::getAvailableBackends_CaptureByFilename();
    for (size_t i = 0; i < backends.size(); i++)
    {
        const VideoBackendInfo& info = backends[i];
        if (apiPreference == CAP_ANY || apiPreference == info.id)
        {
            ...
            const Ptr<IBackend> backend = info.backendFactory->getBackend();
            ...
                    icap = backend->createCapture(filename, parameters);
                    ...
                        if (icap->isOpened())
                            return true;
                        icap.release();
```

工厂有两套:静态 `StaticBackend` 直接持有各 `cvCreate*_proxy` 函数指针,参数经 `applyParametersFallback` 回退为逐个 setProperty(backend_static.cpp:34-46、12-31);动态 `createPluginBackendFactory` 走插件——按 `OPENCV_VIDEOIO_PLUGIN_NAME` 等扫描版本化目录加载 so/dll(backend_plugin.cpp:302、388),插件 ABI 版本常量 `CAPTURE_API_VERSION=2` / `WRITER_API_VERSION=1`(plugin_capture_api.hpp:16,plugin_writer_api.hpp:16)。grab/retrieve/read 是薄委托(cap.cpp:527-565)。

### 2.3 cap_ffmpeg_impl.hpp:与 FFmpeg 的宏解耦(函数级)

这个 3600 行的头是 OpenCV 与 FFmpeg API 断层的全部减震器,标尺是 `CALC_FFMPEG_VERSION(a,b,c) = a<<16|b<<8|c`(cap_ffmpeg_impl.hpp:61),对每处 API 断点给出带 FFmpeg 上游 APIchanges 链接的宏:

```cpp
// cap_ffmpeg_impl.hpp:121-146(节选)
#if LIBAVFORMAT_BUILD >= CALC_FFMPEG_VERSION(59, 0, 100)
#  define CV_FFMPEG_FMT_CONST const
#else
#  define CV_FFMPEG_FMT_CONST
#endif
#if LIBAVFORMAT_BUILD >= CALC_FFMPEG_VERSION(58, 7, 100)
#  define CV_FFMPEG_URL
#endif
// AVStream.codec deprecated in favor of AVStream.codecpar
#if LIBAVFORMAT_BUILD >= CALC_FFMPEG_VERSION(59, 16, 100)
#  define CV_FFMPEG_CODECPAR
#  define CV_FFMPEG_CODEC_FIELD codecpar
#else
#  define CV_FFMPEG_CODEC_FIELD codec
#endif
```

函数级能力开关还包括:编解码 ID 命名空间(`CV_CODEC_ID`/`CV_CODEC(name)`,cap_ffmpeg_impl.hpp:223-229)、send/receive 解码新 API(`USE_AV_SEND_FRAME_API`,:250-258)、硬件加速(`USE_AV_HW_CODECS`,FFmpeg 4.0+ 才启用并引入 cap_ffmpeg_hw.hpp,:172-179)、PTS/pkt_pts 字段改名(:142-146)、旧注册回调与新锁管理(:104-111)、旋转元数据在 FFmpeg 8.0 的第三次搬家(:2130-2145)。硬件解码输出可经 OpenCL 扩展零拷贝进 UMat(cap_ffmpeg_hw.hpp:334;D3D11 单纹理拷贝 :852、:902)。环境参数面也在这层:`OPENCV_FFMPEG_CAPTURE_OPTIONS`(cap_ffmpeg_impl.hpp:1148)、`OPENCV_FFMPEG_WRITER_OPTIONS`(:3289)、调试日志开关(:952-953)、读/解码重试上限 `OPENCV_FFMPEG_READ_ATTEMPTS/DECODE_ATTEMPTS`(:1603-1604)。对外则收敛成一个 C ABI(纯 C 结构体指针 + 函数导出,cap_ffmpeg_legacy_api.hpp:28-42),使 FFmpeg 后端可以被编译成独立二进制插件——这也是 Windows 预编译 FFmpeg 二进制(3rdparty/ffmpeg/ffmpeg.cmake:3-24)规避 LGPL 问题的包装方式。fourcc/编解码 ID 的兼容映射在 ffmpeg_codecs.hpp(含 C99 INT64_C shim,:45-56,全文 301 行)。

### 2.4 内部时钟与帧序

仓库中**没有 MCAP 组件**(全 modules/videoio 大小写不敏感 grep "mcap" 无命中),视频时序完全由各后端自带。FFmpeg 后端的"时钟"是 dts/pts 到帧号的换算:取帧时优先 picture->pts,退化到 pkt_dts(cap_ffmpeg_impl.hpp:1705-1726);`CAP_PROP_POS_MSEC` 返回 `dts_to_sec(picture_pts)*1000`,否则退化为帧号(:1977-1983);换算基准是 `r_frame_rate`,取不到再 `av_guess_frame_rate`、再退到 time_base 倒数(:2086-2101)。帧号即 `fps * sec + 0.5` 的整数化(:2115-2119),首帧 dts 偏移被记入 `dts_delay_in_fps_time_base` 供 CAP_PROP_… 使用(:1724-1725、:2051)。

```cpp
// cap_ffmpeg_impl.hpp:2115-2125
int64_t CvCapture_FFMPEG::dts_to_frame_number(int64_t dts)
{
    double sec = dts_to_sec(dts);
    return (int64_t)(get_fps() * sec + 0.5);
}
double CvCapture_FFMPEG::dts_to_sec(int64_t dts) const
{
    return (double)(dts - ic->streams[video_stream]->start_time) *
        r2d(ic->streams[video_stream]->time_base);
}
```

### 2.5 VideoWriter 编码路径

Writer 与 Capture 同构:`VideoWriter::open` 遍历 `getAvailableBackends_Writer()`(cap.cpp:722-820;表生成 videoio_registry.cpp:467-470)。内置 Writer 后端:FFMPEG(videoio_registry.cpp:69)、GSTREAMER(:76)、INTEL_MFX(:82)、AVFOUNDATION(:89)、MSMF(:98)、CV_IMAGES(:132)、CV_MJPEG(:133)、ANDROID_NATIVE(:162-186)。FFmpeg 写路径的核心是 `icv_configure_video_stream_FFMPEG`(cap_ffmpeg_impl.hpp:2410-2415):按 fourcc 反查 codec_id(:3095),按 pixel_format 定参数(:3160-3250 的 swig 型 switch),并对老编码器做逐 codec 特判(如 MPEG1/2 的 low_delay :2492-2496),新旧 `CODEC_FLAG_GLOBAL_HEADER` 用 CV_CODEC 宏二选一(:2521-2523)。写端参数经 `VIDEOWRITER_PROP_*`:QUALITY=1/IS_COLOR=4/RAW_VIDEO=9/KEY_INTERVAL=10(modules/videoio/include/opencv2/videoio.hpp:225-235;消费点 cap_ffmpeg_impl.hpp:2994-2999)。CV_MJPEG 后端是 OpenCV 自带的 Motion-JPEG 编码器(cap_mjpeg_encoder.cpp),不依赖任何第三方。

### 2.6 杂项

相机校正类 API 只此一处:`CAP_PROP_RECTIFICATION=18`,"仅 DC1394 v2.x 后端支持"的立体校正开关(modules/videoio/include/opencv2/videoio.hpp:162)。

### 2.7 历史层:C API 与已移除后端

videoio 顶层还保留一套 C 兼容层 `videoio_c.cpp`,但 4.x 里旧入口大多已存根化:如 `cvCreateCameraCapture` 直接打印 "doesn't support legacy API anymore" 返回空(modules/videoio/src/videoio_c.cpp:13-16,`cvCreateFileCaptureWithPreference` 同样 :19-22),仅保留 `cvCreateFileCapture` 等少数转发(:25 起)。registry 里另有"已移除后端"名录表 `deprecated_backends`(videoio_registry.cpp:199-214),表尾明示 "dropped backends: MIL, TYZX"(:196),`checkDeprecatedBackend` 会在用户误用旧 ID 时打印专门日志(cap.cpp:226-231)。读源码时这层可作为"枚举数值为什么有空洞"(CAP_VFW=200、CAP_QT=500、CAP_UNICAP=600 均标注 obsolete,videoio.hpp:96-106)的注脚。

## 3. 3rdparty 内嵌库清单(3rdparty/ 目录)

目录自述:收录"very popular still image codecs"以便(主要在 Windows)开箱即用,Unix 上可用 `BUILD_<lib>` 覆盖系统库(3rdparty/readme.txt:1-6)。

- libjpeg-turbo — JPEG 默认实现,`BUILD_JPEG=ON` 即选它(readme.txt:14-24);3rdparty/libjpeg 还保留 IJG 老库作为弃用后备(readme.txt:9-12)。
- libpng / libspng — PNG 两套解码(前者带 zlib 压缩缓冲控制,imgcodecs.hpp:100;后者是轻量安全替代,readme.txt:25-37、:32)。
- libtiff — TIFF 唯一实现(readme.txt:39)。
- zlib / zlib-ng — PNG 依赖的 LZ77 压缩,后者是性能分支(readme.txt:48-56)。
- openexr — HDR/浮点 EXR(readme.txt:75)。
- openjpeg / libjasper — JPEG2000 新旧两代实现(WITH_OPENJPEG/WITH_JASPER)。
- libwebp、quirc(二维码)、protobuf(序列化/dnn 用)。
- tbb、ippicv、ittnotify — 并行/性能原语/追踪;cpufeatures、dlpack、flatbuffers — 平台与互操作辅助。
- ffmpeg — 仅 Windows 预编译二进制下载脚本与 license 包装(3rdparty/ffmpeg/ffmpeg.cmake:8-24),源码不内嵌。
- fastcv、libtim-vx、orbbecsdk — Qualcomm/VeriSilicon/Orbbec 厂商 SDK 前端。

## 4. 后端编译开关(CMakeLists.txt)

图像侧:WITH_JPEG(:306)、WITH_PNG(:330)、WITH_SPNG(:333)、WITH_TIFF(:363)、WITH_WEBP(:312)、WITH_OPENEXR(:315)、WITH_JASPER(:300)、WITH_OPENJPEG(:303)、WITH_JPEGXL(:309)。视频侧:WITH_FFMPEG 默认除 Android 外开启(:265)、WITH_GSTREAMER(:268)、WITH_AVFOUNDATION(:220)、WITH_MSMF(非 MinGW,:372,DXVA 加速 :375)、WITH_DSHOW(:369)、WITH_V4L(:366)、WITH_1394 默认关(:217)。videoio 的 FFmpeg 静态链接时若仅作为 wrapper 编译,可退化为运行期插件(HAVE_FFMPEG_WRAPPER,modules/videoio/CMakeLists.txt:165;Windows 下载器 :291)。

## 5. 与 T-API(UMat)的交集

如实结论:**imgcodecs 完全无 UMat 路径**——imread/imencode 全部以 `Mat`/CPU 缓冲为中心(loadsave.cpp:595-601、1644-1649);`imencodeWithMetadata` 虽接受 `InputArrayOfArrays` 且能识别 `isUMatVector`,但下一步就是 `getMatVector` 拉回 CPU(loadsave.cpp:1646-1647)。videoio 主体同样如此:公开签名收 `OutputArray`,内部 `cv::Mat(...).copyTo(frame)` 落 CPU(cap_ffmpeg.cpp:125);唯一的 GPU 例外是 FFmpeg 硬解:`retrieveFrame_` 检测到调用方传入 UMat 时尝试 `retrieveHWFrame` 零拷贝(cap_ffmpeg.cpp:109-114,声明 cap_ffmpeg_impl.hpp:536,实现 :1928),VideoWriter 对称地有 UMat 入口的 GPU-GPU 拷贝(cap_ffmpeg.cpp:210-211)。即:T-API 支持是有意的窄门,只开在"帧已在 GPU 显存"的硬解场景。

## 6. 设计动机

1. **为什么签名探测而非扩展名**:读端内容可能来自网络/无扩展名/扩展名错误,`checkSignature` 前缀匹配(loadsave.cpp:289-293)让 imread 对"改名的 raw 文件"仍然鲁棒;而写端格式必须由用户显式选择,扩展名恰是最自然的意图表达(findEncoder,loadsave.cpp:327-352)——同一个工厂类里"读靠内容、写靠声明"各取所需。
2. **为什么后端枚举显式(CAP_*)**:跨平台后端能力差异巨大(模式位、属性集),静态数值(videoio.hpp:96-131)+ 注册表顺序即优先级(videoio_registry.cpp:229)让 (a) 用户可用 `VideoCapture(filename, CAP_FFMPEG)` 钉死后端,屏蔽静默回退;(b) 运维可用 `OPENCV_VIDEOIO_PRIORITY_*` 环境变量重排/禁用而无需重编译(:242-253);(c) 日志逐后端可归因(cap.cpp:141-146 的 "trying capture")。
3. **为什么 FFmpeg 宏兼容层**:FFmpeg 每个版本都可能删 API(codec 字段、PTS 命名、注册回调、side-data 三次搬家),而 OpenCV 期望同一份源码覆盖十余年跨度(0.7.x 注释到 FFmpeg 8.0);把断点收进 ~20 个版本宏(cap_ffmpeg_impl.hpp:104-258)后,业务代码只面对 `CV_FFMPEG_CODEC_FIELD` 这类中性名,版本差异被压缩为编译期选择,且每条宏都锚定上游 APIchanges 链接便于回溯。
4. **为什么 imgcodecs 不走 UMat**:静态图解码本质上调用第三方库的 CPU 指针 API,单帧数据量小、GPU 上传/下载往返开销通常高于收益;只有"帧天然在 GPU"的硬解视频才值得开 UMat 窄门(cap_ffmpeg.cpp:109-114)——这解释了同属 IO 模块却对 T-API 态度迥异。
5. **为什么内嵌第三方库**:Windows 上没有可靠包管理器,内嵌源码保证开箱即用与行为一致(3rdparty/readme.txt:1-6);Unix 默认检测系统库、`BUILD_<lib>` 可覆盖,兼顾发行版合规(libjpeg-turbo 而非 IJG 默认,readme.txt:14-24);FFmpeg 因许可证不能内嵌源码,就退化为"许可证干净的预编译二进制 + C ABI 插件包装"(3rdparty/ffmpeg/ffmpeg.cmake:8-24,cap_ffmpeg_legacy_api.hpp:28-42)。
6. **为什么参数是 int 键值向量而非结构体**:`std::vector<int>` 是稳定的 C++/ABI 面上的"可扩展协议",新增 IMWRITE_*/VIDEOWRITER_PROP_* 不破坏二进制;配合三级容错(本编码器认识/别家认识/没人认识,loadsave.cpp:1128-1146)做到参数可携带、未知键只警告不失败。
7. **为什么读失败返回空 Mat 而写失败尽力清场**:imread 的"空 Mat + false"契约(loadsave.cpp:526-528、617-621)是二十年的公开 API 承诺,只能用日志补可观测性;imwrite 失败时先 fopen 探测区分权限问题(EACCES 警告)再 remove 残留文件(loadsave.cpp:1156-1171),把半成品文件对下游的危害降到最低——同一模块对读、写两侧的失败语义做了不对称但各自自洽的处理。

## 7. 写作素材清单(文件:行号)

1. modules/imgcodecs/src/loadsave.cpp:261-297 — findDecoder 签名探测全文
2. modules/imgcodecs/src/loadsave.cpp:157-245 — 编解码器注册表(HAVE_* 门控)
3. modules/imgcodecs/src/grfmt_base.cpp:112-120 — checkSignature 前缀比对
4. modules/imgcodecs/src/loadsave.cpp:84-111 — calcType 标志→类型推导
5. modules/imgcodecs/src/loadsave.cpp:531-548 — REDUCED_* 缩小与 setScale
6. modules/imgcodecs/src/loadsave.cpp:1125-1146 — imencode 参数键值校验三级容错
7. modules/imgcodecs/src/loadsave.cpp:690-740 — imreadmulti 多页循环 nextPage
8. modules/imgcodecs/include/opencv2/imgcodecs.hpp:71-126 — IMREAD_/IMWRITE_ 枚举
9. modules/videoio/src/videoio_registry.cpp:224-257 — 优先级 1000-i*10 与环境变量
10. modules/videoio/src/videoio_registry.cpp:66-133 — builtin_backends 表(FFMPEG 打头)
11. modules/videoio/src/cap.cpp:130-158 — open 逐后端轮询
12. modules/videoio/src/cap_ffmpeg_impl.hpp:121-146 — FFmpeg 宏兼容层样本
13. modules/videoio/src/cap_ffmpeg_impl.hpp:2115-2125 — dts→帧号/秒的内部时钟
14. modules/videoio/src/cap_ffmpeg.cpp:101-126 — retrieveFrame 的 UMat 窄门
15. modules/videoio/src/backend_plugin.cpp:302-388 — 插件扫描加载
16. CMakeLists.txt:265-375 — WITH_FFMPEG/GSTREAMER/MSMF/V4L 等开关带

## 8. 阅读顺序建议(给成稿)

第一遍从"数据"入手:imread 一个真实 PNG,断点/日志跟 findDecoder(loadsave.cpp:261)→ PngDecoder::readHeader(grfmt_png.cpp:251)→ readData;第二遍从"选择"入手:构造 VideoCapture 开 OPENCV_VIDEOIO_DEBUG=1 观察逐后端尝试日志(cap.cpp:141-146;开关定义 cap.cpp:49),再用 OPENCV_VIDEOIO_PRIORITY_LIST 重排复现;第三遍专攻 cap_ffmpeg_impl.hpp 的宏区间(:104-258)与内部分析:对照系统 libav 的版本号逐个解释当前编译选了哪条分支,是这一讲最能体现"深读"价值的部分。

成稿时的取舍提示:imgcodecs 侧的可视化重点放在"同一字节流 + 不同注册表内容 = 不同解码器",videoio 侧放在"三张可用后端表(文件/相机/Writer)如何从同一张 builtin 表投影"(videoio_registry.cpp:429-470),避免把两张表画混。
