# iOS Jailbreak Camera Replacement Tweak

这个包是“替换底层相机效果”的二合一骨架。它包含：

- `VCamInject.dylib`：注入使用相机的 App，拦截 AVFoundation 的视频帧回调。
- `vcamreceiverd`：手机端常驻服务，监听 `9999`，让 Windows 端能通过 usbmuxd 连接手机。

## 工作方式

1. Windows 端通过 usbmuxd 连接手机 `9999`。
2. `vcamreceiverd` 收到握手后回复 `0x01`，并把 H.264 流保存到：

```text
/var/mobile/Library/VCam/stream.h264
```

3. 后续需要把 H.264 解码成 BGRA 原始帧，写到：

```text
/var/mobile/Library/VCam/frame.bgra
/var/mobile/Library/VCam/frame.info
```

4. 本 tweak 注入目标 App。
5. App 调相机时，tweak 拦截 `captureOutput:didOutputSampleBuffer:fromConnection:`。
6. 如果共享帧存在，就用虚拟帧替换真实相机帧。

## 没有电脑端时使用手机本地视频

新版注入层支持本地视频兜底源。没有电脑端推流、也没有 `frame.bgra` 时，它会自动读取下面任意一个文件并循环播放：

```text
/var/mobile/Library/VCam/source.mp4
/var/mobile/Library/VCam/source.mov
/var/mobile/Library/VCam/source.m4v
```

使用方式：

1. 从相册把视频保存/导出到文件管理器。
2. 用 Filza 或爱思助手复制到：

```text
/var/mobile/Library/VCam/source.mp4
```

3. 重启目标 App，再打开相机页。

优先级是：

```text
frame.bgra 共享帧
source.mp4/source.mov/source.m4v 本地视频
真实相机
```

也可以在被注入 App 里用手势选择：

```text
双指快速敲击屏幕两下
```

它会呼出相册视频选择器。选中视频后，插件会复制到：

```text
/var/mobile/Library/VCam/source.mp4
```

然后重开目标 App 的相机页即可使用本地视频替换。

## 它现在为什么不是 deb

这个文件夹是 Theos 工程源码。注入 tweak 需要先编译，编译后才会在 `packages/` 目录生成 `.deb`。

生成后类似：

```text
packages/com.qianmian.vcaminject_0.1.0_iphoneos-arm.deb
```

这个 `.deb` 才是安装到手机上的文件。

## rootless 通用注入

当前默认配置是 rootless/越狱常见环境下更稳的“相机类通用注入”：

```text
Classes = (
    "AVCaptureVideoDataOutput"
);
```

这表示：只要某个 App 使用 AVFoundation 的相机视频帧输出类，就加载这个 tweak。它比“所有进程都注入”安全很多。

不建议把 tweak 无差别注入所有进程，因为 rootless 环境里系统服务、SpringBoard、扩展进程都可能被加载，容易进安全模式。

如果你只想注入某几个 App，也可以把 `VCamInject.plist` 和 `layout/Library/MobileSubstrate/DynamicLibraries/VCamInject.plist` 改回 Bundle ID 白名单，例如微信：

```xml
{
    Filter = {
        Bundles = (
            "com.tencent.xin"
        );
    };
}
```

## 编译成 deb

如果手机上打包不了，推荐用 GitHub Actions 云编译：

1. 在 GitHub 新建一个仓库。
2. 把这个文件夹里的全部内容上传进去，包括隐藏的 `.github` 文件夹。
3. 打开仓库页面的 `Actions`。
4. 选择 `Build RootHide Deb`。
5. 点 `Run workflow`。
6. 等它跑完，在页面底部 `Artifacts` 下载 `VCamInject-roothide-deb`。
7. 解压下载到的 artifact，里面就是 `.deb`。

最简单方式：

```sh
chmod +x build_rootless.sh install_latest_deb.sh
./build_rootless.sh
./install_latest_deb.sh
```

RootHide 环境优先用：

```sh
chmod +x build_roothide.sh install_latest_deb.sh
./build_roothide.sh
./install_latest_deb.sh
```

如果提示 Theos 不支持 `roothide`，说明手机里的 Theos 太旧。可以升级 Theos，或者先用 `./build_rootless.sh` 生成 deb，再用 RootHide/Bootstrap 里的转换工具转换成 RootHide 包。

手动方式：

```sh
make package
```

Rootless：

```sh
THEOS_PACKAGE_SCHEME=rootless make package
```

## 安装 deb

把 `packages/` 目录里生成的 `.deb` 传到手机，然后：

```sh
dpkg -i com.qianmian.vcaminject_0.1.0_iphoneos-arm.deb
killall -9 SpringBoard
```

如果是 rootless 越狱，包名可能带 `iphoneos-arm64`，照实际文件名安装即可。Theos 会把安装路径映射到 rootless 的 `/var/jb/...` 下。

也可以用 Filza 直接点 `.deb` 安装，或用 Sileo/Zebra 安装本地 deb。

## 重要说明

这个是注入层骨架。要完整显示 Windows 推来的视频，还需要把前面的 `vcamreceiverd` 从“保存 H.264 文件”升级为“解码 H.264 到 BGRA 共享帧”。否则 tweak 会退回使用真实相机帧。

## 解决 Windows 端 USB 连接失败

Windows 端的错误：

```text
USB 连接失败，请确认 iPhone 已连接且插件已开启监听
```

对应的就是手机端 `vcamreceiverd` 没有监听 `9999`。安装新版 deb 后，重启手机或手动加载 LaunchDaemon：

```sh
launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.qianmian.vcamreceiver.plist
launchctl kickstart -k system/com.qianmian.vcamreceiver
```

如果 RootHide 的实际路径不是 `/var/jb`，需要按你手机上的 bootstrap 路径调整。

## 先测替换是否生效

可以把 `test_frame_writer.c` 编译到手机上运行，生成一张 BGRA 测试渐变图：

```sh
clang test_frame_writer.c -o test_frame_writer
./test_frame_writer 720 1280
```

然后打开已注入的目标 App 相机页。如果 hook 生效，目标 App 收到的应是测试渐变图帧。
