//
//  ShirabeJisho.swift
//  ReaderFeature
//
//  One-way hand-off from the lookup popup to the Shirabe Jisho dictionary.
//

import Foundation
import UIKit

/// Deep links into Shirabe Jisho, the offline Japanese dictionary.
///
/// The app has never published URL-scheme documentation — its author confirmed
/// the `shirabelookup://search` form by mail when v1.8 added URL support, and
/// these are the only keys that scheme is known to accept:
///
/// - `shirabelookup://search?w=<word>`  — word search
/// - `shirabelookup://search?n=<name>`  — name search
/// - `shirabelookup://search?k=<text>`  — kanji search
/// - `shirabelookup://search?e=<text>`  — example-sentence search
///
/// `w` is what a tapped card word or reader selection wants. The hand-off is
/// one-way on purpose: nothing comes back into Amgi.
enum ShirabeJisho {
    /// Also listed under `LSApplicationQueriesSchemes` in
    /// `AmgiApp/Info.plist`. Without that entry `canOpenURL` answers `false`
    /// for every scheme, installed or not, so the button would always land on
    /// the App Store fallback.
    static let scheme = "shirabelookup"

    static let appStoreURL = URL(string: "https://apps.apple.com/app/id1005203380")!

    /// `nil` for a blank query, so callers can disable the button instead of
    /// opening an empty search.
    static func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "search"
        // `queryItems` percent-encodes the value; the word never needs escaping
        // by hand, and kanji survive intact.
        components.queryItems = [URLQueryItem(name: "w", value: trimmed)]
        return components.url
    }

    enum Outcome: Equatable {
        /// A handler was registered and the app was launched on the word.
        case opened
        /// No registered handler; the word is on the pasteboard instead.
        case copied
        /// Nothing to look up — the query was blank.
        case emptyQuery
    }

    /// Opens the word in Shirabe Jisho, falling back to the pasteboard when no
    /// app is registered for the scheme.
    ///
    /// The fallback exists because `canOpenURL` answers `false` for reasons
    /// that have nothing to do with Shirabe being installed: a guest app under
    /// LiveContainer never registers its schemes with SpringBoard at all
    /// ("custom URL scheme queries often fail" — LiveContainer's own docs).
    /// The App Store page is deliberately *not* an automatic fallback; being
    /// thrown into the store for tapping a lookup button is worse than the
    /// word quietly landing on the pasteboard, so the caller offers that link
    /// explicitly instead.
    @MainActor
    static func handOff(query: String) -> Outcome {
        guard let url = searchURL(for: query) else { return .emptyQuery }

        // Apple documents `open` as unconstrained by `LSApplicationQueriesSchemes`,
        // so a `canOpenURL` false still gets one attempt: it costs nothing and
        // covers a handler the query list cannot see.
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return .opened
        }

        UIPasteboard.general.string = query.trimmingCharacters(in: .whitespacesAndNewlines)
        UIApplication.shared.open(url)
        return .copied
    }
}
