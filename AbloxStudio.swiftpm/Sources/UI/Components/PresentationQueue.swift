import UIKit
import SwiftUI

/// Holds back a full-screen presentation until whatever is over the screen
/// has gone: a sheet, a popover, a confirmation dialog.
///
/// A game started from inside a sheet (a game's page, the friends list, an
/// invitation, "Host for friends…") began while that sheet was still on its
/// way out. UIKit then either refused the full-screen game, or put it up
/// inside the sheet that was leaving: a card in the middle of the screen
/// rather than the whole screen. Waiting for the sheet to finish leaving
/// costs a third of a second and the game opens over everything.
@MainActor
enum PresentationQueue {
    /// How long to wait for a sheet to go before presenting anyway. A sheet
    /// leaves in about a third of a second; one still up after this was not
    /// asked to go, and presenting over it beats never presenting.
    static let patience: Duration = .seconds(2)

    /// Runs `present` once nothing is presented over the app's screen.
    /// Straight away when nothing is.
    static func whenClear(_ present: @escaping @MainActor () -> Void) {
        guard isShowingSomething else {
            present()
            return
        }
        Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + patience
            // A sheet asked to go is still `presented` until its animation
            // ends; one more short wait after that lets SwiftUI catch up.
            while isShowingSomething && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(50))
            present()
        }
    }

    /// Whether a sheet, popover or dialog is over the window this app is
    /// showing in.
    static var isShowingSomething: Bool {
        rootController?.presentedViewController != nil
    }

    private static var rootController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first
        return window?.rootViewController
    }
}
