import Foundation

struct FixtureTranscriber {
    func transcribe(capturedFrames: Int, capReached: Bool) -> String {
        let capNote = capReached ? " (120-second cap reached)" : ""
        return "[Fixture transcription] captured \(capturedFrames) audio frames\(capNote)."
    }
}
