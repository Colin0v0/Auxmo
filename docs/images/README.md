# README image sources / 图片来源

The PNGs are native renders of Auxmo 0.4.10 SwiftUI/AppKit views using isolated fixtures in [`ReadmePreviewTests.swift`](../../Tests/AuxmoPanelTests/ReadmePreviewTests.swift) and [`StatisticsReadmePreviewTests.swift`](../../Tests/AuxmoPanelTests/StatisticsReadmePreviewTests.swift). They are **UI previews, not captures of a live playback session or proof of hardware compatibility**. Device names, app identities, volume values, battery values, and control replies are illustrative.

- `hero-{en,zh}.png`: the actual `AudioPanel` with a two-member group and two example apps.
- `mixer-{en,zh}.png`: `ApplicationVolumeSection`.
- `outputs-{en,zh}.png`: `SimultaneousOutputEditor`.
- `effects-{en,zh}.png`: `ApplicationAudioEffectView`.
- `headphones-{en,zh}.png`: `HeadphoneSection` using injected Apple headphone readings.
- `statistics-{en,zh}.png`: `ListeningStatisticsView`, rendered from version 0.4.10 with isolated sample records; they do not contain real user data.
- `routing-{en,zh}.svg`: a hand-authored configuration diagram, **not an application screenshot**. It assumes both target devices are online.

Regenerate the PNGs on macOS with the Swift 6 toolchain:

```sh
./Scripts/render-readme-previews.sh
```

The script runs the preview test in a separate process for each language and copies its output to this folder. It overrides preferences only in that process's volatile arguments domain. It does not modify saved Auxmo preferences, play/capture audio, connect Bluetooth devices, or change the host's output route. Ordinary test runs skip this explicit documentation export; existing regression tests are unchanged.

When updating images, inspect both languages, check the UI version, and retain this provenance note. Do not use a fixture image as a device verification result.

## 中文

PNG 均由 Auxmo 0.4.10 的真实界面原生渲染；数据由隔离夹具提供，不是实时播放录屏，也不能证明某个耳机型号已通过真机测试。设备、App、音量、电量与模式均为示例。SVG 是手写的在线设备路由示意，不是界面截图。

运行上面的脚本可重新生成双语图片。每种语言使用独立测试进程，只覆盖进程内参数，不修改用户保存的偏好，不播放或捕获音频、不连接蓝牙、不切换宿主设备。普通门禁不执行图片导出；原有回归测试没有被跳过或改弱。更新后请检查图片并保留来源说明。
