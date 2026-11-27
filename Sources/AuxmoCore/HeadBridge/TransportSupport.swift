import CoreAudio
import Foundation

/// 接口派生自 HeadBridge 的 TransportLogEntry，只保存本机有界诊断。
struct TransportLogEntry {
    enum Direction: String { case outgoing = "TX", incoming = "RX", info = "INFO" }
}

/// 每次收发验证物理设备仍在线，不要求它是默认输出，也绝不写入播放路由。
enum HeadphoneConnectionGuard {
    static func check(_ outputUID: String) throws {
        try check(outputUID,
                  deviceIDs: HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyDevices)),
                  readUID: { try HAL.string($0, kAudioDevicePropertyDeviceUID) },
                  isConnectedBluetoothOutput: { id in
            let transport: UInt32 = try HAL.read(id, HAL.address(kAudioDevicePropertyTransportType), initial: 0)
            let alive: UInt32 = try HAL.read(id, HAL.address(kAudioDevicePropertyDeviceIsAlive), initial: 0)
            let streams = try HAL.ids(id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput))
            return AudioOutput(id: id, uid: outputUID, name: "", transport: transport).isBluetooth
                && alive != 0 && !streams.isEmpty
        })
    }

    /// 可注入只读设备枚举，测试不访问真实硬件，不依赖当前默认输出。
    static func check(_ outputUID: String, deviceIDs: [AudioDeviceID],
                      readUID: (AudioDeviceID) throws -> String,
                      isConnectedBluetoothOutput: (AudioDeviceID) throws -> Bool) throws {
        var foundMatchingUID = false
        for id in deviceIDs {
            let uid: String
            do {
                uid = try readUID(id)
            } catch let failure as AudioFailure where failure.status == HAL.badObjectStatus {
                // HAL 列表中可能残留其他刚销毁的无关设备对象，跳过继续核验真实耳机句柄。
                continue
            }
            guard uid == outputUID else { continue }
            foundMatchingUID = true
            do {
                if try isConnectedBluetoothOutput(id) { return }
            } catch let failure as AudioFailure where failure.status == HAL.badObjectStatus {
                continue
            }
        }
        if foundMatchingUID {
            throw AudioFailure("耳机已断开或不再是蓝牙输出设备")
        }
        throw AudioFailure("耳机设备已移除，停止向旧控制目标发送数据")
    }
}
