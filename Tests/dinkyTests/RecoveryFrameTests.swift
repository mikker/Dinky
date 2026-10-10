import Foundation
import Testing
@testable import DinkyLayout
@testable import dinky

struct RecoveryFrameTests {
    @Test func `Untiled frame keeps its offset when a display moves`() {
        let source = CGRect(x: -1920, y: -1080, width: 1920, height: 1040)
        let frame = CGRect(x: -1820, y: -1000, width: 800, height: 600)
        let current = CGRect(x: 0, y: 38, width: 1920, height: 1040)
        #expect(recoveryFrame(frame, from: source, on: current) == CGRect(x: 100, y: 118, width: 800, height: 600))
    }

    @Test func `Moving to a smaller monitor clamps size and position`() {
        let source = CGRect(x: 1710, y: 38, width: 3440, height: 1402)
        let frame = CGRect(x: 4510, y: 938, width: 2000, height: 1200)
        let current = CGRect(x: 0, y: 38, width: 1710, height: 1074)
        #expect(recoveryFrame(frame, from: source, on: current) == current)
    }

    @Test func `Frame on the same monitor remains unchanged`() {
        let visible = CGRect(x: -3440, y: -1440, width: 3440, height: 1402)
        let frame = CGRect(x: -3340, y: -1340, width: 900, height: 700)
        #expect(recoveryFrame(frame, from: visible, on: visible) == frame)
    }

    @Test func `Legacy frames keep valid current-monitor coordinates`() {
        let visible = CGRect(x: 0, y: 38, width: 1710, height: 1074)
        let frame = CGRect(x: 100, y: 150, width: 900, height: 700)
        #expect(recoveryFrame(frame, from: nil, on: visible) == frame)
    }

    @Test func `Legacy frames from a removed display are centered safely`() {
        let visible = CGRect(x: 0, y: 38, width: 1000, height: 800)
        let frame = CGRect(x: -1920, y: -1080, width: 600, height: 400)
        #expect(recoveryFrame(frame, from: nil, on: visible) == CGRect(x: 200, y: 238, width: 600, height: 400))
    }

    @Test func `Invalid frames or display bounds never produce restore targets`() {
        let visible = CGRect(x: 0, y: 38, width: 1000, height: 800)
        #expect(recoveryFrame(.zero, from: nil, on: visible) == nil)
        #expect(recoveryFrame(visible, from: nil, on: .zero) == nil)
        #expect(recoveryFrame(visible, from: .zero, on: visible) == nil)
        #expect(recoveryFrame(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), from: nil, on: visible) == nil)
    }

    @Test func `A completion available before the deadline is consumed`() {
        let completion = RecoveryFrameCompletion()
        let job = FrameJob(pid: 10, id: 1, frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let results = [FrameResult(job: job, target: job.frame, got: job.frame)]
        completion.complete(results)
        #expect(completion.wait(until: .now()) == results)
    }

    @Test func `A completion after timeout cannot change consumed results`() {
        let completion = RecoveryFrameCompletion()
        #expect(completion.wait(until: .now()).isEmpty)
        let job = FrameJob(pid: 10, id: 1, frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        completion.complete([FrameResult(job: job, target: job.frame, got: job.frame)])
        #expect(completion.wait(until: .now()).isEmpty)
    }
}
