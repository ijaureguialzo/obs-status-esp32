//
//  AppDelegate.swift
//  Application delegate: when the app quits, return a connected ESP32
//  board to its initial screen before the process exits.
//

import AppKit
import Foundation

/// NSApplication delegate that intercepts app termination.
///
/// Quitting the app (Cmd+Q, the Quit menu item, or the menu bar "Quit"
/// button) with a connected ESP32 must not just drop the USB link: the
/// board is first returned to the initial screen (title, firmware version
/// and auth secret — the display's "no host" state, black background),
/// and only then does the quit proceed. Without this, a board would keep
/// showing the last scene on the recording background after the host is
/// gone. (If the app dies abruptly, the firmware's 10 s no-command
/// timeout returns the display to the same initial screen.)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's shared view model, wired in `ObsStatusApp.init()`.
    var viewModel: AppViewModel?

    /// Completes the deferred termination once the board has been returned.
    /// Indirected so tests can substitute a no-op for the reply.
    var finishTermination: @MainActor () -> Void = {
        // Answers the pending `terminateLater` decision: the board is back
        // on its initial screen, so proceed with the quit.
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    /// Set while the quit-time cleanup runs, so a repeated quit request
    /// (Cmd+Q again while it is in flight) defers again instead of
    /// spawning a second cleanup.
    private var cleanupInFlight = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.espConnected else {
            return .terminateNow
        }
        if cleanupInFlight {
            return .terminateLater
        }
        cleanupInFlight = true
        // Defer the quit: the board must be back on its initial screen
        // before the process exits. `disconnectESP` pushes the empty scene
        // (best effort, one attempt) and closes the USB link.
        Task {
            await viewModel.disconnectESP()
            finishTermination()
        }
        return .terminateLater
    }
}
