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

    /// Opens the word in Shirabe Jisho, or its App Store page when the app is
    /// not installed — a dead end that at least leads somewhere.
    @MainActor
    static func open(query: String) {
        guard let url = searchURL(for: query) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            UIApplication.shared.open(appStoreURL)
        }
    }
}
