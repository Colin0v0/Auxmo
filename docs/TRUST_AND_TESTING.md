# Trust, limits, and testing

[English home](../README.md) · [中文说明](#中文说明) · [中文首页](../README.zh-CN.md)

## What has actually been checked

The [0.3.8 release](https://github.com/Colin0v0/Auxmo/releases/tag/v0.3.8) is a reference point, not a claim about every future build:

- Its local `Scripts/check.sh` run passed **274 panel tests and 331 core tests (605 total)**.
- [The release workflow](https://github.com/Colin0v0/Auxmo/actions/runs/44459154756) passed on a macOS 15 runner, including packaging checks.
- DMG and ZIP checksum files were checked against the published downloads; the ZIP's app passed signature and resource checks.

Those checks exercise state machines, synthetic PCM, protocol fixtures, UI layout, and packaging. They do **not** prove real headphone output, universal compatibility, Bluetooth timing, long-session stability, or absence of every audio leak. UI previews are not hardware acceptance evidence. The [compatibility matrix](HEADPHONE_COMPATIBILITY.md) distinguishes upstream evidence from independent Auxmo validation.

## Known limits

### Custom routes are not privacy isolation

**Published 0.3.8:** the released resolver can use All Outputs if every custom target is unavailable, or normalize the saved route when a member is removed. A group containing speakers can therefore play audio externally. Do not treat that release as a fail-closed routing boundary.

**0.3.9 and later:** [the current resolver](../Sources/AuxmoCore/AppAudioRoute.swift) keeps the complete saved selection and explicitly reports `waitingForDevices` when none of its targets are active. The model suspends replay, retains an unbound continuously muted tap, and resumes only on a confirmed selected target. A newly registered app with an unavailable saved route starts a mute-only session, not a temporary speaker playback chain. Other apps explicitly using All Outputs are unaffected.

Only an explicit per-app choice can expand targets or clear the restriction. Quitting Auxmo, permission revocation, unregistered audio processes, and real device timing remain separate boundaries to validate. Use version 0.4.2 for the current app identity and global safety mute. Descriptor/state tests are not a live audio-leak test.

### Global safety mute

**Mute All** is a temporary overlay over each app's saved mute intent. It covers app audio that Auxmo can observe and process. When enabled, existing mixing sessions are silenced first, read-only meter taps switch their source mute behavior in place, and newly observed playback is taken over as muted. Turning the control off restores each app's own mute state. It is not an operating-system master mute and does not cover system sounds, unregistered audio processes, or audio heard after Auxmo quits or loses permission.

While safety mute is active, Auxmo observes app playback more frequently to reduce the time before a newly playing app is covered. That shorter polling window reduces, but does not prove the absence of, a real-device timing gap. Test it at low hardware volume.

### Device changes and processing

- Output changes may interrupt playback; separate Bluetooth devices may drift or have different latency.
- Some sleep/wake, permission, and session failures require an explicit **Reapply**. Previously failed processing may remain paused to preserve mute intent.
- The per-app processing path requires supported native Float32 mono/stereo PCM. Some duplex interfaces, multiple output streams, third-party aggregates, and protected audio are outside that scope.
- A recognized headphone brand is not blanket support. Capabilities depend on exact model, protocol replies, firmware, and macOS.
- System audio permission checks use a non-public TCC interface because macOS does not expose a public Process Tap authorization query. OS updates may break that integration. See [permission implementation](audio-capture-permission.md).

## Distribution and permissions

Current release packages are **ad-hoc signed and not notarized**, without a Developer ID identity. A passing `codesign --verify` checks bundle integrity; it is not Apple notarization or a guarantee that Gatekeeper accepts the app. SHA-256 detects a mismatch with the published checksum; it is not a substitute for publisher identity verification.

Use the project's GitHub Releases, review the matching notes, and follow macOS security prompts. Do not disable Gatekeeper or SIP to meet a test checklist. The current startup flow requires system audio recording access; Bluetooth permission is requested for headphone control. The microphone page reads and changes hardware properties, not microphone audio.

## Local processing and useful reports

Audio is processed on the Mac, without recording files, audio uploads, an account, or telemetry. Update checks contact GitHub and include an Auxmo version User-Agent. Opening the project link uses the system browser. Local diagnostics are not automatically uploaded.

Use the [audio bug report form](https://github.com/Colin0v0/Auxmo/issues/new?template=bug_report.yml) to report a problem:

1. Note the version shown in Auxmo, macOS version, Mac model, exact output devices, and firmware if known.
2. Describe the starting route, gain/mute state, action taken, expected result, and observed result. Distinguish “no sound,” “unexpected speakers,” and “stale error message.”
3. Export **Settings → Diagnostics → Export Diagnostics…** before restarting. Events are in memory for this process only; the buffer retains up to 300 recent events, not a persistent crash history.
4. Review the JSON. It can include device names, UIDs, Bluetooth addresses, application identities, and headphone protocol traces. Remove private information before sharing it in an [issue](https://github.com/Colin0v0/Auxmo/issues/new?template=bug_report.yml).

The export does not contain audio samples. A screenshot alone does not identify the underlying Core Audio property or failure path.

## Hardware acceptance checklist

These are **tasks to run**, not boxes already passed on every supported model. Record version, devices, firmware, result, and diagnostic evidence for each run. Use low hardware volumes and non-sensitive test audio; do not test with a real meeting or private recording.

- [ ] Mute an app, switch between speakers and headphones, and confirm each physical output's behavior.
- [ ] Enable **Mute All**, start a new app, switch outputs, then disable it and verify each app's original mute state returns.
- [ ] Repeat with app gain at zero and with spatial effects on; listen for retained reverb tails.
- [ ] In a multi-device group, disconnect/reconnect members and verify actual outputs against the intended route.
- [ ] Remove the only custom target and check the documented group-output behavior.
- [ ] Exercise sleep/wake, media-to-call format changes, process exit/restart, and explicit Reapply.
- [ ] Test a clean install, system permission denial/grant, update/relaunch, and quit with active sessions.

A failure belongs in the issue and compatibility records. Do not relabel a model as verified based only on a fixture or a green CI result. See the [release checklist](RELEASING.md).

## 中文说明

### 有记录的验证，不是全场景保证

以 [0.3.8](https://github.com/Colin0v0/Auxmo/releases/tag/v0.3.8) 为例，本地完整检查通过 274 项面板测试和 331 项核心测试，共 605 项；[macOS 15 发布流水线](https://github.com/Colin0v0/Auxmo/actions/runs/44459154756) 也已通过。发布后的 DMG/ZIP 校验值、ZIP 内应用签名和资源均做过检查。

这说明状态机、合成音频、协议夹具、界面及安装包通过了相应检查，**不代表所有耳机真机、延迟、长时间稳定性或漏音场景已经验收**。界面示例图也不是验收证据。[兼容表](HEADPHONE_COMPATIBILITY.md) 中的“上游已验证”和“Auxmo 独立验证”是不同状态。

### 已知边界

- **已发布的 0.3.8 不是隐私隔离。** 该版本在自定义目标全部离线时，可能改用组内其他输出；移除组成员也可能让保存的路由变为全部输出。
- **0.3.9 及后续版本**保留完整选择，没有可用目标时返回明确的等待状态，只停重放、保留无设备绑定的持续静音 tap；新注册的 App 也先建仅静音会话，不先在扬声器建播放链。原目标确认恢复后，才恢复原配置。其他明确使用全部输出的 App 不受影响。
- **全局安全静音**是每个 App 原有静音意图之上的临时叠加层，覆盖 Auxmo 能观察并处理的 App 音频。开启时先静音已有 mixing 会话，再直接切换只读计量 tap 的来源静音，并把新发现的播放接管为静音；关闭后恢复各 App 原来的静音状态。它不是系统总静音，不覆盖系统提示音、尚未注册的音频进程，也不覆盖 Auxmo 退出或失去权限后的声音。
- 扩大或清除自定义目标必须由用户明确选择。Auxmo 退出、权限撤销、尚未注册的新音频进程及真实设备时序仍需单独验证。全局静音期间会缩短只读观察间隔，但缩短时间窗口不等于证明真机不存在漏音；请使用低音量验收。
- 输出切换可能断音，多个蓝牙设备不保证严格同步。休眠、权限或会话失败后，部分 App 需要明确“重新应用”，暂停可能是在保留静音意图。
- 应用处理支持原生 Float32 单声道或双声道；部分双工接口、多输出流、第三方聚合及受保护音频不在支持范围内。
- 耳机能力取决于具体型号、协议回包、固件及系统版本，不是品牌全系支持。
- 音频授权检查依赖非公开 TCC 接口，系统升级可能影响它。详情见[权限实现](audio-capture-permission.md)。

### 安装与隐私

当前包为 ad-hoc 签名，**没有 Developer ID 签名和 Apple 公证**。签名完整性检查不等于 Gatekeeper 放行；SHA-256 也不能替代发布者身份认证。请从项目 Releases 下载并遵循系统提示，不需要关闭 Gatekeeper 或 SIP。

当前启动流程需要系统音频录制权限才能进入主界面，耳机控制会申请蓝牙权限。麦克风页只读写硬件属性，不录制麦克风音频。

音频在本机处理，不保存录音、不上传音频、无需账号、不收集遥测。应用会访问 GitHub 检查更新和下载；更新请求包含 Auxmo 版本标识。诊断不会自动上传。

### 怎样反馈更容易查清楚

记录 Auxmo 与 macOS 版本、Mac 型号、设备及固件，说明原路由、静音/音量状态、触发步骤和实际输出。先在“设置 → 诊断”导出，再重启；事件只保留本次进程最近最多 300 条，重启后没有旧事件记录。

JSON 可能包含设备名、UID、蓝牙地址、应用身份及耳机协议记录，不含音频样本。公开到 [Issue](https://github.com/Colin0v0/Auxmo/issues/new?template=bug_report.yml) 前请脱敏；仅凭截图不能确认失败的属性或调用路径。

上方真机清单都是待执行的验收项，不是全型号已经通过。请用低音量、非敏感测试音频，验证静音切换、音效尾音、多设备断连与重连、唯一自定义目标离线、休眠唤醒、通话格式变化、权限和升级。失败应如实记录，不能仅凭绿色 CI 把型号标成已验证。
