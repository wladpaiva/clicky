//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Sends text to ElevenLabs TTS (via the Cloudflare Worker proxy) and plays
//  back the resulting audio. Uses the /with-timestamps endpoint so the app
//  receives character-level alignment data alongside the audio — this lets
//  cursor-movement callbacks fire at the exact second each UI element is
//  mentioned in speech rather than at a rough proportional estimate.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    /// Timers that fire cursor-movement callbacks at precise timestamps derived
    /// from ElevenLabs character-level alignment data. Cancelled on stopPlayback
    /// or when a new speakText call begins.
    private var pendingPointTimers: [Timer] = []

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// A cursor-movement callback paired with the character offset in the
    /// spoken text where the associated [POINT:...] tag appeared. The TTS
    /// client uses the ElevenLabs alignment data to find the exact playback
    /// timestamp for that character and fires the callback at that moment.
    struct TimedPointCallback {
        /// Index into the spoken text string (UTF-16 code unit offset) where
        /// the [POINT:...] tag appeared. ElevenLabs alignment arrays are
        /// indexed by character position in the text that was sent to TTS.
        let spokenTextCharacterOffset: Int
        /// Called on the main actor when the spoken text reaches the character
        /// at `spokenTextCharacterOffset` — i.e., when the model says the
        /// element's name aloud.
        let action: () -> Void
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// `timedPointCallbacks` is an optional list of cursor-movement actions.
    /// Each action fires at the moment the spoken text reaches its associated
    /// character offset, using the ElevenLabs character-level alignment data.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(
        _ text: String,
        timedPointCallbacks: [TimedPointCallback] = []
    ) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        // The /with-timestamps endpoint returns JSON with base64-encoded audio
        // and character-level alignment data. Decode both before playback.
        let (audioData, characterStartTimesInSeconds) = try decodeTimestampedTTSResponse(responseData: data)

        let player = try AVAudioPlayer(data: audioData)
        self.audioPlayer = player

        // Cancel any leftover timers from a previous response before scheduling new ones
        cancelPendingPointTimers()

        // Schedule each cursor-movement callback at the exact second the spoken
        // text reaches that character's position. Enforce a 0.1s minimum so
        // timers fire safely after player.play() returns.
        for timedPoint in timedPointCallbacks {
            let characterOffset = timedPoint.spokenTextCharacterOffset

            // Look up the exact playback timestamp from ElevenLabs alignment data.
            // Fall back to 0.5s if the offset is out of range (shouldn't happen in practice).
            let alignmentTimestamp: Double
            if characterOffset < characterStartTimesInSeconds.count {
                alignmentTimestamp = characterStartTimesInSeconds[characterOffset]
            } else if !characterStartTimesInSeconds.isEmpty {
                alignmentTimestamp = characterStartTimesInSeconds.last!
            } else {
                alignmentTimestamp = 0.5
            }

            let delay = max(0.1, alignmentTimestamp)
            let action = timedPoint.action

            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor in action() }
            }
            pendingPointTimers.append(timer)
        }

        player.play()
        print("🔊 ElevenLabs TTS: playing \(audioData.count / 1024)KB audio, \(timedPointCallbacks.count) timed point(s), \(characterStartTimesInSeconds.count) alignment chars")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately and cancels pending cursor timers.
    func stopPlayback() {
        cancelPendingPointTimers()
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Private helpers

    /// Decodes the JSON response from the ElevenLabs /with-timestamps endpoint.
    /// Returns the raw MP3 audio data and the array of character start times (in seconds).
    private func decodeTimestampedTTSResponse(responseData: Data) throws -> (audioData: Data, characterStartTimesInSeconds: [Double]) {
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "ElevenLabsTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "TTS response is not a JSON object"])
        }

        guard let audioBase64 = json["audio_base64"] as? String,
              let audioData = Data(base64Encoded: audioBase64) else {
            throw NSError(domain: "ElevenLabsTTS", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "TTS response missing or invalid audio_base64 field"])
        }

        // Extract character start times from the alignment block.
        // The alignment arrays are indexed by character position in the text sent to TTS,
        // which matches the spokenTextCharacterOffset values we compute in CompanionManager.
        var characterStartTimesInSeconds: [Double] = []
        if let alignment = json["alignment"] as? [String: Any],
           let startTimes = alignment["character_start_times_seconds"] as? [Double] {
            characterStartTimesInSeconds = startTimes
        } else {
            print("⚠️ ElevenLabs TTS: alignment data missing from response — timed points will use fallback delay")
        }

        return (audioData: audioData, characterStartTimesInSeconds: characterStartTimesInSeconds)
    }

    private func cancelPendingPointTimers() {
        pendingPointTimers.forEach { $0.invalidate() }
        pendingPointTimers.removeAll()
    }
}
