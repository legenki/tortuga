import Foundation

/// What DemoEngine shows: real app identifiers and believable relays.
enum DemoData {
    static let countries = ["DE", "NL", "FR", "SE", "CH", "PL", "FI", "US", "CA", "RO", "IS", "NO", "AT", "CZ", "LU"]
    static let nicknames = ["Quintex", "ForPrivacyNET", "artikel10", "NTHrelay", "prsv", "relayon", "torpidsDE",
                            "CalyxInstitute", "emeraldonion", "nothingtohide", "Tortilla", "Spigot", "Hydra",
                            "Unnamed", "boldsuck"]

    /// Apps that connect one by one in the normal scenario.
    static let normalApps = [
        AppID("com.apple.Safari", name: "Safari"),
        AppID("ru.keepcoder.Telegram", name: "Telegram"),
        AppID("com.tinyspeck.slackmacgap", name: "Slack"),
        AppID("com.apple.Music", name: "Music"),
    ]

    /// Excepted from the start in the normal scenario.
    static let mail = AppID("com.apple.mail", name: "Mail")

    static let manyApps = [
        AppID("com.apple.Safari", name: "Safari"),
        AppID("ru.keepcoder.Telegram", name: "Telegram"),
        AppID("com.tinyspeck.slackmacgap", name: "Slack"),
        AppID("com.apple.Music", name: "Music"),
        AppID("com.google.Chrome", name: "Google Chrome"),
        AppID("org.mozilla.firefox", name: "Firefox"),
        AppID("us.zoom.xos", name: "zoom.us"),
        AppID("com.spotify.client", name: "Spotify"),
        AppID("com.hnc.Discord", name: "Discord"),
        AppID("net.whatsapp.WhatsApp", name: "WhatsApp"),
        AppID("org.whispersystems.signal-desktop", name: "Signal"),
        AppID("notion.id", name: "Notion"),
        AppID("com.figma.Desktop", name: "Figma"),
        AppID("com.microsoft.VSCode", name: "Visual Studio Code"),
        AppID("com.apple.dt.Xcode", name: "Xcode"),
        AppID("com.apple.Terminal", name: "Terminal"),
        AppID("com.apple.Maps", name: "Maps"),
        AppID("com.apple.news", name: "News"),
        AppID("com.apple.weather", name: "Weather"),
        AppID("com.apple.AppStore", name: "App Store"),
        AppID("com.apple.MobileSMS", name: "Messages"),
        AppID("com.apple.FaceTime", name: "FaceTime"),
        AppID("com.apple.Photos", name: "Photos"),
        AppID("com.apple.podcasts", name: "Podcasts"),
        AppID("com.apple.TV", name: "TV"),
        AppID("md.obsidian", name: "Obsidian"),
        AppID("com.1password.1password", name: "1Password"),
        AppID("com.getdropbox.dropbox", name: "Dropbox"),
        AppID("com.valvesoftware.steam", name: "Steam"),
        AppID("com.apple.mail", name: "Mail"),
    ]

    /// Seven well-formed obfs4 lines from documentation addresses.
    static let obfs4Lines: [String] = (1...7).map { i in
        let fingerprint = String(repeating: String(format: "%X", i), count: 40)
        return "Bridge obfs4 192.0.2.\(i):443 \(fingerprint) cert=ZGVtbyBjZXJ0aWZpY2F0ZQ iat-mode=0"
    }

    static func downloads() -> [Download] {
        [
            Download(name: "debian-13.2.0-arm64-netinst.iso", size: 754_974_720, done: 0.35,
                     downRate: 2_400_000, state: .downloading),
            Download(name: "archlinux-2026.11.01-x86_64.iso", size: 1_288_490_188, done: 1, state: .done),
        ]
    }
}
