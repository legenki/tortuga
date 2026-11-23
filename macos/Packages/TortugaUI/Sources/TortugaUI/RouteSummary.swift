import Foundation
import TortugaKit

/// The route map in words, for VoiceOver.
enum RouteSummary {
    private static let english = Locale(identifier: "en")

    static func country(_ code: String) -> String {
        english.localizedString(forRegionCode: code) ?? code
    }

    /// "Safari: Germany, France, Sweden; Telegram: …". `name`: an app's name
    /// (AppInfo.name in the app; injected for tests).
    static func text(for state: EngineState, name: (AppID) -> String) -> String {
        let routed = state.apps.filter { !state.exceptions.contains($0.app) }
        guard !routed.isEmpty else { return "World map: no routes yet" }
        let guardCountry = state.trunk.guardRelay.map { [country($0.country)] } ?? []
        return routed.map { route in
            "\(name(route.app)): " + (guardCountry + [country(route.middle.country), country(route.exit.country)]).joined(separator: ", ")
        }.joined(separator: "; ")
    }
}
