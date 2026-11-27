import AppKit
import Foundation
import Testing
import AuxmoCore
@testable import Auxmo

@MainActor
struct ApplicationTerminationTests {
    @Test func cleanExitDoesNotCancelAnAuthorizedUpdate() {
        var cancelled = false
        let termination = ApplicationTermination(attempt: { .complete }, confirmUncleanExit: { _ in
            Issue.record("正常退出不应出现确认框"); return false
        }, cancelRestart: { cancelled = true }, cancelShutdown: {})
        #expect(termination.request(at: 1) == .terminateNow)
        #expect(!cancelled)
        #expect(termination.poll(at: 2) == nil)
    }

    @Test func repeatedQuitRequestsDoNotRestartCleanupOrExtendTheDeadline() {
        var attempts = 0
        var cancellations = 0
        let termination = ApplicationTermination(attempt: { attempts += 1; return .waiting },
            confirmUncleanExit: { _ in true }, cancelRestart: { cancellations += 1 }, cancelShutdown: {})
        #expect(termination.request(at: 10) == .terminateLater)
        #expect(termination.request(at: 12) == .terminateLater)
        #expect(attempts == 1)
        #expect(termination.poll(at: 12.9) == nil)
        #expect(termination.poll(at: 13) == true)
        #expect(cancellations == 1)
        #expect(termination.poll(at: 20) == nil)
    }

    @Test func delayedHALConfirmationCompletesTheOriginalQuit() {
        var result: ApplicationShutdownResult = .waiting
        let termination = ApplicationTermination(attempt: { result }, confirmUncleanExit: { _ in
            Issue.record("正常 HAL 延迟不是错误"); return false
        }, cancelRestart: {}, cancelShutdown: {})
        #expect(termination.request(at: 1) == .terminateLater)
        result = .complete
        #expect(termination.poll(at: 1.5) == true)
    }

    @Test(arguments: [true, false])
    func genuineFailureRequiresAnExplicitChoiceAndCancelsUpdate(quitAnyway: Bool) {
        var warnings: [String] = []
        var cancelledUpdate = false
        var resumed = false
        let termination = ApplicationTermination(attempt: { .failed("Core Audio 123") },
            confirmUncleanExit: { warnings.append($0); return quitAnyway },
            cancelRestart: { cancelledUpdate = true }, cancelShutdown: { resumed = true })
        #expect(termination.request(at: 1) == (quitAnyway ? .terminateNow : .terminateCancel))
        #expect(warnings == ["Core Audio 123"] && cancelledUpdate)
        #expect(resumed == !quitAnyway)
    }

    @Test func cancellingExitAllowsAnotherExplicitQuit() {
        var result: ApplicationShutdownResult = .failed("未释放")
        let termination = ApplicationTermination(attempt: { result }, confirmUncleanExit: { _ in false },
            cancelRestart: {}, cancelShutdown: {})
        #expect(termination.request(at: 1) == .terminateCancel)
        result = .complete
        #expect(termination.request(at: 2) == .terminateNow)
    }

    @Test func failureDialogExplainsAudioRestorationAndDefaultsToCancel() {
        let alert = ApplicationTermination.makeFailureAlert("Core Audio 123", language: .english)
        #expect(alert.buttons.map(\.title) == ["Cancel", "Quit Anyway"])
        #expect(alert.informativeText.contains("Original app audio may resume"))
        #expect(alert.informativeText.contains("Core Audio 123"))
    }

    @Test func shutdownPollingNeverCreatesNewApplicationSessions() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.4, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        let created = audio.sessions.count
        hardware.keepAfterDestroy = true
        #expect(model.shutdownStep() == .waiting)
        for _ in 0..<10 {
            model.refresh()
            #expect(model.shutdownStep() == .waiting)
        }
        #expect(audio.sessions.count == created && model.sessions.isEmpty)
        #expect(hardware.destroyed.count == 1)
        hardware.compositions.removeAll()
        #expect(model.shutdownStep() == .complete)
        #expect(model.shutdownStep() == .complete)
    }

    @Test func shutdownSweepsAnOrphanAggregateThatWasNeverPresentedInTheUI() throws {
        let hardware = RoutingTestHardware()
        let plan = try MultiOutputPlan(outputs: Array(hardware.outputs.prefix(2)),
                                       sampleRates: ["speaker": 48_000, "headphone": 48_000])
        hardware.compositions[88] = plan.description(uid: "com.colin0v0.auxmo.multi.orphan")
        hardware.selected = 2
        hardware.systemSelected = 1
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false)

        // 不先调用 refresh，模拟残留设备尚未进入 pendingCleanup 就被用户直接退出。
        #expect(model.shutdownStep() == .complete)
        #expect(hardware.destroyed == [88])
        #expect(hardware.selected == 2 && hardware.systemSelected == 1)
        #expect(hardware.selections.isEmpty)
    }

    @Test func failedSessionCleanupStaysOwnedUntilRetryAndCancelResumesObservation() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.4, for: audio.row.id)
        let session = try #require(model.sessions[audio.row.id] as? MemoryAudioSession)
        session.failStop = true
        guard case .failed = model.shutdownStep() else { Issue.record("应报告真实清理错误"); return }
        #expect(model.sessions[audio.row.id] === session)
        let previousRows = model.applications
        audio.objectIDs = [43]
        model.refresh()
        #expect(model.applications == previousRows)
        model.cancelShutdown()
        #expect(model.applications != previousRows)
        #expect(model.cleanupErrors[audio.row.id] != nil)
        session.failStop = false
        #expect(model.shutdownStep() == .complete)
    }

    @Test func quittingDuringASwitchDiscardsTheUnstartedNextSelection() {
        let hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false)
        hardware.deferSelection = true
        model.selectOutput(2)
        #expect(model.outputRouting.phase.isBusy)
        model.startSimultaneousOutput(["speaker", "usb"])
        #expect(model.outputRouting.queued != nil)
        #expect(model.shutdownStep() == .waiting)
        #expect(model.outputRouting.queued == nil)
        hardware.commitSelection()
        #expect(model.shutdownStep() == .complete)
        #expect(hardware.created.isEmpty)
    }
}
