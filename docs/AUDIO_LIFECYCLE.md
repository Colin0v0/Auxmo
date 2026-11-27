# 应用音频生命周期

## 职责

- `AuxmoAudioEngine`：统一管理所有应用 `AudioAppSource` 与按物理设备共享的 `AudioDeviceSink` 混音总线，执行无锁环形缓冲分发、自适应漂移重采样与 20ms 交叉淡入淡出。
- `AudioGraphPlanner`：纯函数式拓扑编译器，根据硬件快照、进程表与用户意图生成不可变音频图计划及结构化 `AudioRouteExplanation`，并硬性剔除本进程防止回授。
- `ProcessAudioSession` / `EngineApplicationSession`：验证进程和目标路由，保留用户增益、静音及音效，决定何时启动、暂停和停止。
- `ProcessAudioResources` / `AudioAppSource` / `AudioDeviceSink`：分别持有捕获侧 tap/私有聚合与输出侧物理设备 IOProc 及回调上下文，严格按阶段创建与释放。
- `ProcessAudioHardware` / `AudioSourceHardware` / `AudioSinkHardware`：HAL 调用边界。生产使用真实 API，测试只替换这些调用，执行相同引擎与会话代码。
- `ApplicationTermination`：区分退出完成、等待系统确认和真实失败。单调时钟限定三秒等待，不延长期限。

tap 描述更新统一写入公开的 `kAudioTapPropertyDescription` 属性，直接检查 C API 返回的 OSStatus；不依赖新版 SDK 才有的 Swift 错误包装字段，也不按系统版本选择其他实现。

## 资源状态

重放端只允许以下状态：

```text
absent → aggregate → registered → running
running → registered → aggregate → absent
```

某一步失败，保留该状态和句柄；重试从该步继续。`registered` 连同 IOProc 保留 `RenderState`，注销成功前不能释放上下文。暂停与停止先关闭独立的原子重放开关，后续回调先清零输出，不修改用户增益；已在执行的缓冲和系统缓冲不受此开关追溯控制。

tap 的所有权独立于重放端。暂停写入无设备绑定的持续静音描述，再释放重放；写入和停止都要尝试，失败分别保留。只有 tap 已解绑且重放端完全释放，才报告“已暂停”。明确停止须先完成重放释放，再销毁 tap；tap 销毁失败不能丢掉描述。

`!dev` 表示 ID 不能作为有效设备使用，`!obj` 表示无效对象；它们都不是无条件清理成功。设备和 tap 分别查询完整 HAL 列表：只有对应 ID 已消失才视为已释放。列表读取失败或 ID 仍存在就保留资源，不忽略其他状态码。这个核实流程不选择替代设备，也不切换音频后端。

回调原始指针持有独立 retain。正常注销后释放；若会话所有者意外丢失且尚未注销，关闭重放并保留该 retain 至进程退出，避免悬空指针。这是异常所有权丢失的内存安全约束，不是正常资源回收方式。

本地诊断的 `session.resources` 附带 tap/聚合 ID、重放阶段、tap 是否解绑和重放开关。读取这些字段不访问 HAL；它们描述 Auxmo 当前保留的所有权，不证明硬件正在发声。

## 自动输出静音确认

`AudioDeviceMutePending` 只表示写入已经被 HAL 接受，而紧接着的读回尚未匹配。自动输出保护将其记录为 `awaitingHAL`，保存目标 ID、UID、原路由阶段和固定的三秒期限。等待时只读快照，不重发静音、不改音量、不恢复应用重放；只有准确目标的静音读回为 true 才继续接管。

若媒体输出已离开该目标或句柄改变，撤销旧等待，依据新快照重新协调，不能让另一个设备的静音状态确认旧请求。新的明确输出选择优先，不顺带取消任何已写出的设备静音。写入真实失败、持续不确认超时仍报告，不能仅因普通刷新就清错。

## 退出事务

模型按 `running → stopping → stopped` 推进。停止期间屏蔽周期刷新和应用会话重建，撤销未开始的排队选择，只推进已开始的路由操作和资源释放；不能在退出轮询中调用常规恢复链路。

完整释放允许退出并继续已授权的更新。HAL 尚未确认移除时等待，不重复销毁。失败或三秒超时后撤销更新/重启并提示用户：取消退出会恢复观察，保留真实清理错误；“仍然退出”明确结束处理，原声可能恢复，公共组合可能需要手动移除。不自动强制终止进程。

## 验证

`ProcessAudioSessionCleanupTests` 在真实会话代码上注入启动各阶段失败、释放各阶段失败、对象仍存在、对象消失、枚举失败和复合错误；检查释放顺序、重试位置、tap 身份与上下文寿命。还包含 240 轮确定性故障注入和同一 tap 的重复暂停/恢复。

`ApplicationTerminationTests` 验证确认延迟、重复退出、截止时间、错误选择、撤销更新、取消后恢复，以及退出期间不重建会话、不执行排队的新路由。`RenderCallbackTests` 使用合成缓冲验证重放开关。

运行 `./Scripts/check.sh`。这些测试不等于真机蓝牙时序、HAL 卡死、听感或漏音验收。真实设备验证仍按[验证清单](TRUST_AND_TESTING.md#hardware-acceptance-checklist)执行。
