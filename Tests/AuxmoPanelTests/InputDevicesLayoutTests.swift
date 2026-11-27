import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuxmoCore
@testable import Auxmo

struct InputDevicesLayoutTests {
    @Test func selectedHiddenMicrophoneRemainsVisible() {
        let active = AudioInput(id: 1, uid: "one", name: "One", transport: 0)
        let other = AudioInput(id: 2, uid: "two", name: "Two", transport: 0)
        let visible = InputDevicesSection.visibleInputs([active, other], hiddenUIDs: ["one", "two"], selectedID: 1)
        #expect(visible.map(\.uid) == ["one"])
    }

    @Test @MainActor func microphoneRowsReuseSizesAndColorOnlyMuteHover() throws {
        let inputs = [
            AudioInput(id: 1, uid: "fixture-input-a", name: "MacBook Air 麦克风", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioInput(id: 2, uid: "fixture-input-b", name: "USB 麦克风", transport: kAudioDeviceTransportTypeUSB)
        ]
        let available = AudioDeviceControlState.available(volume: AudioDeviceVolume(scalar: 0.7, writable: true),
                                                          mute: AudioDeviceMute(muted: false, writable: true))
        let snapshot = SystemInputSnapshot(inputs: inputs, selectedID: 1, controls: [1: available, 2: available])
        let host = NSHostingView(rootView:
            InputDevicesSection(audio: snapshot, select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in })
                .frame(width: PanelMetrics.width - 24).background(PanelStyle.canvas)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.size == CGSize(width: PanelMetrics.contentWidth, height: 80))
        let buttons = actionButtons(in: host)
        #expect(buttons.count == 2)
        for button in buttons {
            #expect(button.bounds.size == PanelActionMetrics.square)
            #expect(button.hoverStyle == .foregroundOnly)
            button.highlight(true)
            #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/auxmo-microphone-layout.png"))
    }

    @Test @MainActor func emptyInputListDoesNotProduceFakeMicrophoneControls() {
        let snapshot = SystemInputSnapshot(inputs: [], selectedID: nil, controls: [:])
        let host = NSHostingView(rootView:
            InputDevicesSection(audio: snapshot, select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in })
                .frame(width: PanelMetrics.width - 24)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(actionButtons(in: host).isEmpty)
        #expect(host.frame.height > 0)
    }

    @Test @MainActor func hiddenDisclosureUsesDeviceRowPitchAndExpandsPerEntry() throws {
        let entries = ["fixture-hidden-a": "Offline A", "fixture-hidden-b": "Offline B"]
        let collapsed = NSHostingView(rootView:
            HiddenDevicesDisclosure(title: "已隐藏麦克风", entries: entries, icon: "eye.slash", itemIcon: "mic",
                                    horizontalInset: PanelMetrics.horizontalInset, restore: { _ in })
                .frame(width: PanelMetrics.contentWidth).background(PanelStyle.canvas)
        )
        collapsed.frame.size = collapsed.fittingSize
        collapsed.layoutSubtreeIfNeeded()
        #expect(collapsed.fittingSize.height == PanelMetrics.deviceRowHeight)

        let expanded = NSHostingView(rootView:
            HiddenDevicesDisclosure(title: "已隐藏麦克风", entries: entries, icon: "eye.slash", itemIcon: "mic",
                                    horizontalInset: PanelMetrics.horizontalInset, initiallyExpanded: true,
                                    restore: { _ in })
                .frame(width: PanelMetrics.contentWidth).background(PanelStyle.canvas)
        )
        expanded.frame.size = expanded.fittingSize
        expanded.layoutSubtreeIfNeeded()
        #expect(expanded.fittingSize.height == PanelMetrics.deviceRowHeight * 3)

        for (host, path) in [(collapsed, "/tmp/auxmo-hidden-microphones-collapsed.png"),
                             (expanded, "/tmp/auxmo-hidden-microphones-expanded.png")] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func hiddenDisclosureOnlyShowsCountForMultipleDevices() {
        #expect(HiddenDevicesDisclosure.displayTitle("已隐藏设备", count: 1, language: .chinese)
                == "已隐藏设备")
        #expect(HiddenDevicesDisclosure.displayTitle("已隐藏设备", count: 2, language: .chinese)
                == "已隐藏设备 · 2 台")
        #expect(HiddenDevicesDisclosure.displayTitle("Hidden Devices", count: 2, language: .english)
                == "Hidden Devices · 2")
    }

    @MainActor private func actionButtons(in view: NSView) -> [PanelActionControl] {
        if let button = view as? PanelActionControl { return [button] }
        return view.subviews.flatMap { actionButtons(in: $0) }
    }
}
