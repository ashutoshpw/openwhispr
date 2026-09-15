import AVFoundation
import Foundation

/// The host owns the microphone for the whole activation lease. Buffers are
/// counted only while a dictation is active and are discarded in every other
/// state; this prototype never writes audio to disk.
final class CaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var collecting = false
    private var frameCount = 0

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        collecting = true
        frameCount = 0
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard collecting else { return }
        frameCount += Int(buffer.frameLength)
    }

    func end() -> Int {
        lock.lock()
        defer { lock.unlock() }
        collecting = false
        let result = frameCount
        frameCount = 0
        return result
    }
}

final class AudioSessionController {
    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let accumulator = CaptureAccumulator()
    private var tapInstalled = false

    private(set) var isActive = false

    func activate() throws {
        try audioSession.setCategory(.record, mode: .measurement, options: [])
        try audioSession.setActive(true)

        if !tapInstalled {
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [accumulator] buffer, _ in
                // This callback may execute on the audio thread. The accumulator
                // owns its lock and never retains the buffer.
                accumulator.receive(buffer)
            }
            tapInstalled = true
        }

        if !engine.isRunning {
            try engine.start()
        }
        isActive = true
    }

    func resumeAfterInterruption() throws {
        guard isActive else { return }
        try audioSession.setActive(true)
        if !engine.isRunning {
            try engine.start()
        }
    }

    func beginDictation() {
        accumulator.begin()
    }

    @discardableResult
    func endDictation() -> Int {
        accumulator.end()
    }

    func deactivate() {
        _ = accumulator.end()
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }
}
