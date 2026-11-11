import SwiftUI

/// Shown once: what Tortuga does, what it doesn't, and the one permission
/// macOS will ask for.
struct FirstRunView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Welcome to Tortuga", systemImage: "tortoise.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.route)
            point("network",
                  "Tortuga sends every app on this Mac through Tor, each app on its own circuit. Sites see a Tor exit, not your IP address.")
            point("person.crop.circle.badge.exclamationmark",
                  "It hides your IP. It doesn't make you anonymous: apps you're signed in to, like iCloud, Telegram or mail, still say who you are. It is not Tor Browser.")
            point("lock.shield",
                  "macOS will ask you once to allow Tortuga's network extension. Until Tor is ready, Tortuga holds traffic back instead of letting it out directly.")
            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.glassProminent)
                    .tint(Color.route)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome.continue")
            }
        }
        .padding(28)
        .frame(width: 470)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
