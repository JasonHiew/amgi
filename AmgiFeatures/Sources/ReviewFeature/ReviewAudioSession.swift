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
        let category: AVAudioSession.Category = playInSilent ? .playback : .ambient
        do {
            try session.setCategory(category, mode: .default, options: categoryOptions(for: mode))
            try session.setActive(true, options: [])
        } catch {
            // Audio category failures are non-fatal — a card whose audio cannot
            // play due to category mismatch will still render correctly.
        }
        #endif
    }

    static func apply(playInSilent: Bool, modeRaw: String) {
        apply(playInSilent: playInSilent, mode: ReviewAudioPlaybackMode.resolved(modeRaw))
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
    private static func categoryOptions(
        for mode: ReviewAudioPlaybackMode
    ) -> AVAudioSession.CategoryOptions {
        switch mode {
        case .interrupt: return []
        case .duck: return [.mixWithOthers, .duckOthers]
        case .mix: return [.mixWithOthers]
        }
    }
    #endif
}
