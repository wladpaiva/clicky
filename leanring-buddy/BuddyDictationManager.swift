//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    struct ShortcutConfiguration: Codable, Equatable {
        let modifierFlagsRawValue: UInt
        let keyCode: UInt16?
        let keyDisplayText: String?
        let keySentenceDisplayText: String?

        init(
            modifierFlags: NSEvent.ModifierFlags,
            keyCode: UInt16?,
            keyDisplayText: String? = nil,
            keySentenceDisplayText: String? = nil
        ) {
            self.modifierFlagsRawValue = modifierFlags
                .intersection(BuddyPushToTalkShortcut.supportedModifierFlags)
                .rawValue
            self.keyCode = keyCode
            self.keyDisplayText = keyDisplayText
            self.keySentenceDisplayText = keySentenceDisplayText
        }

        var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
                .intersection(BuddyPushToTalkShortcut.supportedModifierFlags)
        }

        var isModifierOnlyShortcut: Bool {
            keyCode == nil
        }

        var displayText: String {
            displayLabels(sentenceCase: false).joined(separator: " + ")
        }

        var sentenceDisplayText: String {
            displayLabels(sentenceCase: true).joined(separator: " + ")
        }

        var isValidForPushToTalk: Bool {
            let shortcutModifierCount = modifierFlags.shortcutModifierCount

            if isModifierOnlyShortcut {
                return shortcutModifierCount >= 2
            }

            return shortcutModifierCount >= 1
        }

        private func displayLabels(sentenceCase: Bool) -> [String] {
            var labels = BuddyPushToTalkShortcut.modifierDisplayLabels(
                for: modifierFlags,
                sentenceCase: sentenceCase
            )

            if let keyCode {
                labels.append(
                    BuddyPushToTalkShortcut.keyDisplayLabel(
                        for: keyCode,
                        storedLowercaseLabel: keyDisplayText,
                        storedSentenceLabel: keySentenceDisplayText,
                        sentenceCase: sentenceCase
                    )
                )
            }

            return labels
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    private static let selectedShortcutConfigurationUserDefaultsKey = "selectedPushToTalkShortcutOption"
    static let supportedModifierFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
    static let defaultShortcutConfiguration = ShortcutConfiguration(
        modifierFlags: [.control, .option],
        keyCode: nil
    )

    static var selectedShortcutConfiguration: ShortcutConfiguration {
        if
            let storedShortcutConfigurationData = UserDefaults.standard.data(
                forKey: selectedShortcutConfigurationUserDefaultsKey
            ),
            let storedShortcutConfiguration = try? JSONDecoder().decode(
                ShortcutConfiguration.self,
                from: storedShortcutConfigurationData
            )
        {
            return storedShortcutConfiguration
        }

        if
            let storedLegacyShortcutRawValue = UserDefaults.standard.string(
                forKey: selectedShortcutConfigurationUserDefaultsKey
            ),
            let migratedShortcutConfiguration = legacyShortcutConfiguration(
                from: storedLegacyShortcutRawValue
            )
        {
            return migratedShortcutConfiguration
        }

        return defaultShortcutConfiguration
    }

    static var pushToTalkDisplayText: String {
        selectedShortcutConfiguration.displayText
    }

    static var pushToTalkSentenceDisplayText: String {
        selectedShortcutConfiguration.sentenceDisplayText
    }

    static var pushToTalkTooltipText: String {
        "push to talk (\(pushToTalkDisplayText))"
    }

    static func setSelectedShortcutConfiguration(
        _ selectedShortcutConfiguration: ShortcutConfiguration
    ) {
        guard
            let encodedShortcutConfiguration = try? JSONEncoder().encode(selectedShortcutConfiguration)
        else {
            return
        }

        UserDefaults.standard.set(
            encodedShortcutConfiguration,
            forKey: selectedShortcutConfigurationUserDefaultsKey
        )
    }

    static func normalizedModifierFlags(from modifierFlags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(supportedModifierFlags)
    }

    static func capturePreviewText(for modifierFlags: NSEvent.ModifierFlags) -> String? {
        let normalizedModifierFlags = normalizedModifierFlags(from: modifierFlags)
        guard !normalizedModifierFlags.isEmpty else { return nil }

        return modifierDisplayLabels(
            for: normalizedModifierFlags,
            sentenceCase: true
        ).joined(separator: " + ")
    }

    static func capturedShortcutConfiguration(from keyDownEvent: NSEvent) -> ShortcutConfiguration? {
        let normalizedModifierFlags = normalizedModifierFlags(from: keyDownEvent.modifierFlags)
        guard !normalizedModifierFlags.isEmpty else { return nil }
        guard !isModifierKeyCode(keyDownEvent.keyCode) else { return nil }

        let keyDisplayLabels = keyDisplayLabels(from: keyDownEvent)

        return ShortcutConfiguration(
            modifierFlags: normalizedModifierFlags,
            keyCode: keyDownEvent.keyCode,
            keyDisplayText: keyDisplayLabels.lowercaseLabel,
            keySentenceDisplayText: keyDisplayLabels.sentenceLabel
        )
    }

    static func capturedModifierOnlyShortcutConfiguration(
        previousModifierFlags: NSEvent.ModifierFlags,
        currentModifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutConfiguration? {
        let normalizedPreviousModifierFlags = normalizedModifierFlags(from: previousModifierFlags)
        let normalizedCurrentModifierFlags = normalizedModifierFlags(from: currentModifierFlags)

        guard !normalizedPreviousModifierFlags.isEmpty else { return nil }
        guard normalizedCurrentModifierFlags != normalizedPreviousModifierFlags else { return nil }
        guard normalizedPreviousModifierFlags.isSuperset(of: normalizedCurrentModifierFlags) else {
            return nil
        }

        return ShortcutConfiguration(
            modifierFlags: normalizedPreviousModifierFlags,
            keyCode: nil
        )
    }

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let currentSelectedShortcutConfiguration = selectedShortcutConfiguration
        let normalizedModifierFlags = normalizedModifierFlags(from: modifierFlags)

        if currentSelectedShortcutConfiguration.isModifierOnlyShortcut {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed =
                normalizedModifierFlags == currentSelectedShortcutConfiguration.modifierFlags

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let configuredKeyCode = currentSelectedShortcutConfiguration.keyCode else {
            return .none
        }

        let matchesModifierFlags =
            normalizedModifierFlags == currentSelectedShortcutConfiguration.modifierFlags

        if shortcutEventType == .keyDown
            && keyCode == configuredKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .flagsChanged
            && wasShortcutPreviouslyPressed
            && !matchesModifierFlags {
            return .released
        }

        if shortcutEventType == .keyUp
            && keyCode == configuredKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }

    private static func legacyShortcutConfiguration(
        from legacyShortcutRawValue: String
    ) -> ShortcutConfiguration? {
        switch legacyShortcutRawValue {
        case "shiftFunction":
            return ShortcutConfiguration(modifierFlags: [.shift, .function], keyCode: nil)
        case "controlOption":
            return ShortcutConfiguration(modifierFlags: [.control, .option], keyCode: nil)
        case "shiftControl":
            return ShortcutConfiguration(modifierFlags: [.shift, .control], keyCode: nil)
        case "controlOptionSpace":
            return ShortcutConfiguration(
                modifierFlags: [.control, .option],
                keyCode: 49,
                keyDisplayText: "space",
                keySentenceDisplayText: "Space"
            )
        case "shiftControlSpace":
            return ShortcutConfiguration(
                modifierFlags: [.shift, .control],
                keyCode: 49,
                keyDisplayText: "space",
                keySentenceDisplayText: "Space"
            )
        default:
            return nil
        }
    }

    private static func modifierDisplayLabels(
        for modifierFlags: NSEvent.ModifierFlags,
        sentenceCase: Bool
    ) -> [String] {
        let orderedModifierLabels: [(NSEvent.ModifierFlags, String, String)] = [
            (.control, "ctrl", "Control"),
            (.option, "option", "Option"),
            (.shift, "shift", "Shift"),
            (.command, "cmd", "Command"),
            (.function, "fn", "Fn")
        ]

        return orderedModifierLabels.compactMap { modifierFlag, lowercaseLabel, sentenceLabel in
            guard modifierFlags.contains(modifierFlag) else { return nil }
            return sentenceCase ? sentenceLabel : lowercaseLabel
        }
    }

    private static func keyDisplayLabel(
        for keyCode: UInt16,
        storedLowercaseLabel: String?,
        storedSentenceLabel: String?,
        sentenceCase: Bool
    ) -> String {
        if sentenceCase, let storedSentenceLabel {
            return storedSentenceLabel
        }

        if !sentenceCase, let storedLowercaseLabel {
            return storedLowercaseLabel
        }

        let fallbackKeyDisplayLabels = fallbackKeyDisplayLabels(for: keyCode)
        return sentenceCase
            ? fallbackKeyDisplayLabels.sentenceLabel
            : fallbackKeyDisplayLabels.lowercaseLabel
    }

    private static func keyDisplayLabels(from event: NSEvent) -> (lowercaseLabel: String, sentenceLabel: String) {
        fallbackKeyDisplayLabels(for: event.keyCode)
    }

    private static func fallbackKeyDisplayLabels(
        for keyCode: UInt16
    ) -> (lowercaseLabel: String, sentenceLabel: String) {
        switch keyCode {
        case 0: return ("a", "A")
        case 1: return ("s", "S")
        case 2: return ("d", "D")
        case 3: return ("f", "F")
        case 4: return ("h", "H")
        case 5: return ("g", "G")
        case 6: return ("z", "Z")
        case 7: return ("x", "X")
        case 8: return ("c", "C")
        case 9: return ("v", "V")
        case 11: return ("b", "B")
        case 12: return ("q", "Q")
        case 13: return ("w", "W")
        case 14: return ("e", "E")
        case 15: return ("r", "R")
        case 16: return ("y", "Y")
        case 17: return ("t", "T")
        case 18: return ("1", "1")
        case 19: return ("2", "2")
        case 20: return ("3", "3")
        case 21: return ("4", "4")
        case 22: return ("6", "6")
        case 23: return ("5", "5")
        case 24: return ("=", "=")
        case 25: return ("9", "9")
        case 26: return ("7", "7")
        case 27: return ("-", "-")
        case 28: return ("8", "8")
        case 29: return ("0", "0")
        case 30: return ("]", "]")
        case 31: return ("o", "O")
        case 32: return ("u", "U")
        case 33: return ("[", "[")
        case 34: return ("i", "I")
        case 35: return ("p", "P")
        case 36: return ("return", "Return")
        case 37: return ("l", "L")
        case 38: return ("j", "J")
        case 39: return ("'", "'")
        case 40: return ("k", "K")
        case 41: return (";", ";")
        case 42: return ("\\", "\\")
        case 43: return (",", ",")
        case 44: return ("/", "/")
        case 45: return ("n", "N")
        case 46: return ("m", "M")
        case 47: return (".", ".")
        case 48: return ("tab", "Tab")
        case 49: return ("space", "Space")
        case 50: return ("`", "`")
        case 51: return ("delete", "Delete")
        case 53: return ("escape", "Escape")
        case 115: return ("home", "Home")
        case 116: return ("page up", "Page Up")
        case 117: return ("forward delete", "Forward Delete")
        case 118: return ("f4", "F4")
        case 119: return ("end", "End")
        case 120: return ("f2", "F2")
        case 121: return ("page down", "Page Down")
        case 122: return ("f1", "F1")
        case 123: return ("left arrow", "Left Arrow")
        case 124: return ("right arrow", "Right Arrow")
        case 125: return ("down arrow", "Down Arrow")
        case 126: return ("up arrow", "Up Arrow")
        default:
            return ("key \(keyCode)", "Key \(keyCode)")
        }
    }

    private static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }
}

private extension NSEvent.ModifierFlags {
    var shortcutModifierCount: Int {
        [
            NSEvent.ModifierFlags.control,
            NSEvent.ModifierFlags.option,
            NSEvent.ModifierFlags.shift,
            NSEvent.ModifierFlags.command,
            NSEvent.ModifierFlags.function
        ]
        .filter { contains($0) }
        .count
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private let transcriptionProvider: any BuddyTranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        super.init()
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()

        resetSessionState()
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // If the task is cancelled while we are waiting for macOS to bring
            // the app forward, we can safely continue into the permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        guard !isDictationInProgress else { return }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        do {
            try await startRecognitionSession()
            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                activeTranscriptionSession?.cancel()
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private func startRecognitionSession() async throws {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")

        let activeTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.latestRecognizedText = transcriptText
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        self.activeTranscriptionSession = activeTranscriptionSession
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't transcribe that. try again."
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
        let finalTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else { return }

        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    private func buildTranscriptionKeyterms() -> [String] {
        let baseKeyterms = [
            "makesomething",
            "Learning Buddy",
            "Codex",
            "Claude",
            "Anthropic",
            "OpenAI",
            "SwiftUI",
            "Xcode",
            "Vercel",
            "Next.js",
            "localhost"
        ]

        let combinedKeyterms = baseKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}
