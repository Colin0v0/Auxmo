import Foundation
import Testing
@testable import Auxmo

struct DevelopmentInstanceLockTests {
    @Test func secondDevelopmentInstanceWaitsUntilFirstExits() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("auxmo-instance-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        var first = try DevelopmentInstanceLock.acquire(at: path)
        #expect(first != nil)
        let second = try DevelopmentInstanceLock.acquire(at: path)
        #expect(second == nil)
        withExtendedLifetime(first) {}
        first = nil
        let afterRelease = try DevelopmentInstanceLock.acquire(at: path)
        #expect(afterRelease != nil)
    }
}
