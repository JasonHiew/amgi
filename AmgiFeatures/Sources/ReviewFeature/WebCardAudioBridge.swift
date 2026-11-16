//
//  WebCardAudioBridge.swift
//  ReviewFeature
//

import AVFoundation
import Foundation

/// Plays card media that the page would otherwise hand to WebKit.
///
/// `WKWebView` takes over the app's audio session when web content plays media and
/// ducks every other app, whatever category the app set — WebKit #167788, open
/// since iOS 10. Routing asset-scheme audio through here keeps playback inside the
/// app's own session, which is the only place the review playback mode can apply.
///
/// Only `amgi-asset:` URLs are intercepted. WebAudio and anything a card builds in
/// JS with a data/blob URL still runs in the page, where WebKit keeps the session.
@Observable @MainActor
final class WebCardAudioBridge {
    /// Token of the item the page is waiting on, so its `ended` event can be
    /// replayed once native playback finishes.
    private var player: AVPlayer?
    private var endObserver: (any NSObjectProtocol)?

    func play(url: URL, token: Int, onEnd: @escaping (Int) -> Void) {
        stop()
        // Re-assert for every item: a lookup popup or a TTS utterance may have
        // changed the category since the review session started.
        ReviewAudioSession.applyCurrentPreferences()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in onEnd(token) }
        }
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

/// Injected at document start. Replaces playback of `amgi-asset:` media with a
/// message to native and keeps the element's event contract intact, so templates
/// that listen for `play`/`playing`/`ended` see the sequence they expect.
enum WebCardAudioScript {
    static let source = """
    (function () {
      if (window.__amgiNativeAudioInstalled) { return; }
      window.__amgiNativeAudioInstalled = true;
      var SCHEME = 'amgi-asset:';
      var seq = 0;
      var pending = {};
      var nativePlay = HTMLMediaElement.prototype.play;
      var nativePause = HTMLMediaElement.prototype.pause;

      HTMLMediaElement.prototype.play = function () {
        var src = this.currentSrc || this.src || '';
        if (src.indexOf(SCHEME) !== 0) { return nativePlay.apply(this, arguments); }
        var token = ++seq;
        pending[token] = this;
        try {
          this.dispatchEvent(new Event('play'));
          this.dispatchEvent(new Event('playing'));
        } catch (e) {}
        try {
          window.webkit.messageHandlers.amgiPlayAudio.postMessage({ src: src, token: token });
        } catch (e) {}
        return Promise.resolve();
      };

      HTMLMediaElement.prototype.pause = function () {
        var any = false;
        for (var key in pending) { any = true; delete pending[key]; }
        if (any) {
          try { window.webkit.messageHandlers.amgiStopAudio.postMessage({}); } catch (e) {}
        }
        return nativePause.apply(this, arguments);
      };

      window.__amgiNativeAudioEnded = function (token) {
        var element = pending[token];
        if (!element) { return; }
        delete pending[token];
        try { element.dispatchEvent(new Event('ended')); } catch (e) {}
      };
    })();
    """
}
