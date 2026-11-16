//
//  ReviewAudioSession.swift
//  ReviewFeature
//
//  Created by Vladimir Gusev on 04.05.2026.
//

import AVFoundation
import AppCore
import Foundation

@MainActor
enum ReviewAudioSession {
    /// Configures the shared audio session for a review session.
    ///
    /// `mode` decides how review audio coexists with other apps' playback, so a
    /// user listening to music or a video keeps hearing it. It mirrors the
    /// dictionary lookup player's three modes; `.mix` is the default because
    /// ducking background audio by surprise is the behaviour users complain about.
    static func apply(playInSilent: Bool, mode: ReviewAudioPlaybackMode = .mix) {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        let category = category(for: mode, playInSilent: playInSilent)
        do {
            try session.setCategory(category, mode: .default, options: categoryOptions(for: mode))
            try session.setActive(true, options: [])
        } catch {
            // Audio category failures are non-fatal — a card whose audio cannot
            // play due to category mismatch will still render correctly.
        }
        #endif
    }

    /// Sets the category without activating the session.
    ///
    /// Opening a review screen must not duck or interrupt anything by itself: with
    /// `.duckOthers` and an active session, the other app is already quiet while the
    /// user reads the question. Take the session only when a sound actually starts.
    static func prepare(playInSilent: Bool, mode: ReviewAudioPlaybackMode = .mix) {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                category(for: mode, playInSilent: playInSilent),
                mode: .default,
                options: categoryOptions(for: mode)
            )
            if mode == .mix {
                // Mixing is the resting state: activating it changes nothing for
                // other apps, and it avoids a category/activation race on first play.
                try session.setActive(true, options: [])
            }
        } catch {
            // Non-fatal: a category mismatch only affects how this audio coexists.
        }
        #endif
    }

    /// Puts other apps back the way they were once review audio goes quiet.
    ///
    /// `.duckOthers` and an interrupting session both keep the other app's volume
    /// reduced for as long as the session stays active, so music stays quiet after
    /// the card has finished. Deactivating hands the session back; `.mix` never
    /// touched the other app, so it has nothing to undo.
    static func restoreIfNeeded(mode: ReviewAudioPlaybackMode) {
        guard mode != .mix else { return }
        release()
    }

    static func apply(playInSilent: Bool, modeRaw: String) {
        apply(playInSilent: playInSilent, mode: ReviewAudioPlaybackMode.resolved(modeRaw))
    }

    /// Reads the persisted preferences and applies them. Playback paths that can
    /// start without the review view re-appearing (card audio routed out of the
    /// WebView) call this so the category is never left from another screen.
    static func applyCurrentPreferences(defaults: UserDefaults = .standard) {
        let playInSilent = defaults.bool(forKey: ReviewPreferences.Keys.playAudioInSilentMode)
        apply(playInSilent: playInSilent, mode: currentMode(defaults: defaults))
    }

    static func currentMode(defaults: UserDefaults = .standard) -> ReviewAudioPlaybackMode {
        ReviewAudioPlaybackMode.resolved(
            defaults.string(forKey: ReviewPreferences.Keys.audioPlaybackMode)
                ?? ReviewAudioPlaybackMode.mix.rawValue
        )
    }

    static func release() {
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        #endif
    }

    #if canImport(UIKit)
    /// `.ambient` is mixable by definition, so it can never interrupt or duck
    /// another app — those two modes need a non-mixable `.playback` session.
    /// Only `.mix` gets to stay ambient and honour the ring/silent switch.
    private static func category(
        for mode: ReviewAudioPlaybackMode,
        playInSilent: Bool
    ) -> AVAudioSession.Category {
        switch mode {
        case .interrupt, .duck: return .playback
        case .mix: return playInSilent ? .playback : .ambient
        }
    }

    private static func categoryOptions(
        for mode: ReviewAudioPlaybackMode
    ) -> AVAudioSession.CategoryOptions {
        switch mode {
        case .interrupt: return []
        // `duckOthers` implicitly sets `mixWithOthers` (Apple's docs), so listing
        // both was redundant; ducking lasts from activation to deactivation, which
        // is why the restore path matters more than this bit.
        case .duck: return [.duckOthers]
        case .mix: return [.mixWithOthers]
        }
    }
    #endif
}
