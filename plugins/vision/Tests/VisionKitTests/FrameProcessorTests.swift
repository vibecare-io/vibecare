import CoreVideo
import Foundation
import Testing
import VCKStubs
@testable import VisionKit

/// The frame path: model lifecycle, what gets published, and the shared `seq`.
///
/// `didOutput` is called through `queue.sync` throughout, which is exactly the
/// confinement `VisionAnalyzing` documents — one serial queue, never
/// concurrent — and also what makes `applyPlan`'s dispatched model sync
/// observable at a deterministic point.
@Suite struct FrameProcessorTests {
    private func makeProcessor(
        analyzer: FakeAnalyzer,
        recorder: PublishRecorder,
        signals: VisionSignalsComputer? = nil
    ) -> (FrameProcessor, DispatchQueue) {
        let queue = DispatchQueue(label: "test.frames")
        let processor = FrameProcessor(analyzer: analyzer,
                                       queue: queue,
                                       preview: nil,
                                       signalsComputer: signals,
                                       emit: { topic, payload in recorder.record(topic, payload) })
        return (processor, queue)
    }

    @Test func modelsAreConstructedOnlyForPlannedTopicsAndSignalsCostsNone() {
        let analyzer = FakeAnalyzer()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: PublishRecorder())

        processor.applyPlan(testPlan([.bodyPose: 2, .signals: 2]))
        queue.sync {}

        // Exactly one model for a plan naming one model-bearing topic. Signals
        // is free — pure math over landmarks someone else paid for.
        #expect(analyzer.activeModels == [.bodyPose])
        #expect(analyzer.constructions == [[.bodyPose]])
    }

    @Test func modelsAreReleasedWhenThePlanDropsToZeroEvenWithNoFurtherFrames() {
        let analyzer = FakeAnalyzer()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: PublishRecorder())

        processor.applyPlan(testPlan([.face: 15, .hands: 15]))
        queue.sync {}
        #expect(analyzer.activeModels == [.face, .hands])

        // The demand floor closed the session, so no frame will ever arrive
        // again. Release has to happen on the plan change itself — an idle
        // VNRequest still holds resources, and waiting for a frame that never
        // comes would leak it for the life of the process.
        processor.applyPlan(.idle)
        queue.sync {}
        #expect(analyzer.activeModels.isEmpty)
        #expect(analyzer.releases == [[.face, .hands]])
    }

    @Test func aPartialDropReleasesOnlyTheTopicThatLostItsRequest() {
        let analyzer = FakeAnalyzer()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: PublishRecorder())

        processor.applyPlan(testPlan([.face: 15, .hands: 15, .segmentation: 15]))
        queue.sync {}
        processor.applyPlan(testPlan([.face: 15]))
        queue.sync {}

        #expect(analyzer.activeModels == [.face])
        #expect(analyzer.releases == [[.hands, .segmentation]])
        // "postures installed later -> the body model is constructed, vision
        // unchanged, no release."
        processor.applyPlan(testPlan([.face: 15, .bodyPose: 2]))
        queue.sync {}
        #expect(analyzer.constructions.last == [.bodyPose])
        #expect(analyzer.releases.count == 1)
    }

    @Test func anIdlePlanPublishesNothingAndRunsNoInference() {
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: recorder)

        let buffer = makeTestPixelBuffer()
        queue.sync { processor.didOutput(buffer, mirrored: false, deviceID: "cam") }

        #expect(analyzer.runs.isEmpty)
        #expect(recorder.messages.isEmpty)
        // The frame still counted: "captured but never analyzed" is precisely
        // the state the readout has to be able to describe.
        #expect(processor.counters.captured == 1)
        #expect(processor.counters.analyzed == 0)
    }

    @Test func aFeederRunsItsModelAndFeedsSignalsWithoutPublishingItsOwnTopic() {
        // blink-jump's whole case: it subscribes to `vision.signals.v1` only,
        // so demand for `vision.face.v1` is structurally zero and the face
        // topic must not be published — but the model still has to RUN, or
        // `ear_l` is absent on every frame forever and the game never starts.
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        let (processor, queue) = makeProcessor(
            analyzer: analyzer,
            recorder: recorder,
            signals: { bundle in
                // Absent is not zero: only claim an EAR when a face actually
                // came out of the model this frame.
                guard bundle.face != nil else { return nil }
                var signals = VCTSignals()
                signals.earL = 0.25
                return signals
            }
        )

        let plan = VisionPlan(
            topics: [
                .signals: VisionTopicPlan(fps: 30, subscribers: 1, requesters: ["blink-jump"]),
                .face: VisionTopicPlan(fps: 30, subscribers: 0, requesters: ["blink-jump"], publishes: false),
            ],
            warnings: []
        )
        processor.applyPlan(plan)
        queue.sync {}

        // The model exists — that is the half a bare demand conjunction loses.
        #expect(analyzer.activeModels == [.face])

        queue.sync { processor.didOutput(makeTestPixelBuffer(), mirrored: false, deviceID: "cam") }

        #expect(analyzer.runs.count == 1, "the face model must actually have been run on the frame")
        #expect(recorder.topics == [.signals],
                "the feeder's own topic has no subscribers, so nothing may go on the bus for it")
        let signals = try? VCTSignals(serializedBytes: recorder.payloads(.signals)[0])
        #expect(signals?.hasEarL == true, "the whole point: signals arrive populated, not all-absent")
    }

    @Test func everyTopicDerivedFromOneFrameSharesOneSeq() throws {
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: recorder)

        processor.applyPlan(testPlan([.face: 30, .hands: 30, .segmentation: 30]))
        queue.sync {}
        let buffer = makeTestPixelBuffer(width: 1280, height: 720)
        queue.sync { processor.didOutput(buffer, mirrored: true, deviceID: "cam-42") }

        #expect(recorder.topics.sorted() == [.face, .hands, .segmentation])

        let face = try VCTFaceFrame(serializedBytes: recorder.payloads(.face)[0])
        let hands = try VCTHandsFrame(serializedBytes: recorder.payloads(.hands)[0])
        let mask = try VCTSegmentationFrame(serializedBytes: recorder.payloads(.segmentation)[0])

        // The join key. A consumer needing face + hands + segmentation from
        // the same moment matches on this, and evaluates only on a complete
        // set.
        #expect(face.header.seq == hands.header.seq)
        #expect(face.header.seq == mask.header.seq)
        #expect(face.header.seq == 1)
        #expect(face.header.deviceID == "cam-42")
        #expect(face.header.frame.w == 1280)
        #expect(face.header.frame.h == 720)
    }

    @Test func theMirrorFlagIsForwardedPerFrameRatherThanRemembered() {
        let analyzer = FakeAnalyzer()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: PublishRecorder())

        processor.applyPlan(testPlan([.face: 30]))
        queue.sync {}
        let buffer = makeTestPixelBuffer()
        // A real connection can report either value, and it is only meaningful
        // once the connection is ready — caching the first answer is the
        // first-open-vs-reopen bug this forwarding exists to prevent.
        queue.sync { processor.didOutput(buffer, mirrored: false, deviceID: "cam") }
        // A second frame far enough apart that the 30fps gate lets it through.
        Thread.sleep(forTimeInterval: 0.05)
        queue.sync { processor.didOutput(buffer, mirrored: true, deviceID: "cam") }

        #expect(analyzer.mirroredSeen == [false, true])
    }

    @Test func aTopicWhoseGateHasNotElapsedIsNotRunAndNotPublished() {
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: recorder)

        processor.applyPlan(testPlan([.face: 30]))
        queue.sync {}
        let buffer = makeTestPixelBuffer()
        // Back-to-back, well inside 1/30s.
        queue.sync { processor.didOutput(buffer, mirrored: true, deviceID: "cam") }
        queue.sync { processor.didOutput(buffer, mirrored: true, deviceID: "cam") }

        #expect(analyzer.runs.count == 1)
        #expect(recorder.payloads(.face).count == 1)
        #expect(processor.counters.captured == 2)
        #expect(processor.counters.analyzed == 1)
    }

    // MARK: - Signals

    /// A stand-in for `VCGeometry`'s math: sets `ear_l` iff a face is present
    /// and `shoulder_angle` iff a body is, and leaves everything else absent.
    private static let signalsComputer: VisionSignalsComputer = { bundle in
        var signals = VCTSignals()
        if bundle.face != nil { signals.earL = 0.25 }
        if bundle.body != nil { signals.shoulderAngle = 12 }
        return signals
    }

    @Test func signalsAreNotPublishedWhenNoModelHasEverProducedAnything() {
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        let (processor, queue) = makeProcessor(analyzer: analyzer,
                                               recorder: recorder,
                                               signals: Self.signalsComputer)

        // Signals requested, but nobody asked for a model to feed it. An
        // all-absent Signals message would look like a working tier with
        // nothing to say, which is the one reading the contract forbids.
        processor.applyPlan(testPlan([.signals: 30]))
        queue.sync {}
        queue.sync { processor.didOutput(makeTestPixelBuffer(), mirrored: true, deviceID: "cam") }

        #expect(recorder.messages.isEmpty)
    }

    @Test func signalsCarryForwardWhileTheirModelIsActiveAndVanishWhenItIsReleased() throws {
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        let (processor, queue) = makeProcessor(analyzer: analyzer,
                                               recorder: recorder,
                                               signals: Self.signalsComputer)

        processor.applyPlan(testPlan([.face: 30, .signals: 30]))
        queue.sync {}
        let buffer = makeTestPixelBuffer()
        queue.sync { processor.didOutput(buffer, mirrored: true, deviceID: "cam") }

        var signals = try VCTSignals(serializedBytes: recorder.payloads(.signals)[0])
        #expect(signals.hasEarL)
        #expect(signals.hasShoulderAngle == false)   // absent is not zero
        #expect(signals.header.seq == 1)

        // Face stops. Its carried value must go with it, or `ear_l` would keep
        // being published from a model that is no longer running — the exact
        // lie the presence rule exists to prevent.
        recorder.reset()
        processor.applyPlan(testPlan([.signals: 30]))
        queue.sync {}
        Thread.sleep(forTimeInterval: 0.05)
        queue.sync { processor.didOutput(buffer, mirrored: true, deviceID: "cam") }
        #expect(recorder.payloads(.signals).isEmpty)

        _ = signals
        signals = VCTSignals()
    }

    @Test func signalsAreNeverPublishedWithoutAComputer() {
        let analyzer = FakeAnalyzer()
        let recorder = PublishRecorder()
        // No computer wired in — the math lives in VCGeometry and this
        // deployment has not been given it. Publishing nothing is honest;
        // `/api/state` reports `signalsAvailable: false` alongside.
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: recorder)

        processor.applyPlan(testPlan([.face: 30, .signals: 30]))
        queue.sync {}
        queue.sync { processor.didOutput(makeTestPixelBuffer(), mirrored: true, deviceID: "cam") }

        #expect(recorder.topics == [.face])
    }

    @Test func latestFramesCarryPerModelAndDropWhenAModelIsReleased() {
        let analyzer = FakeAnalyzer()
        let (processor, queue) = makeProcessor(analyzer: analyzer, recorder: PublishRecorder())

        processor.applyPlan(testPlan([.face: 30, .hands: 30]))
        queue.sync {}
        queue.sync { processor.didOutput(makeTestPixelBuffer(), mirrored: true, deviceID: "cam") }

        #expect(processor.latestFrames?.produced == [.face, .hands])

        processor.applyPlan(testPlan([.face: 30]))
        queue.sync {}
        Thread.sleep(forTimeInterval: 0.05)
        queue.sync { processor.didOutput(makeTestPixelBuffer(), mirrored: true, deviceID: "cam") }
        #expect(processor.latestFrames?.produced == [.face])
    }
}
