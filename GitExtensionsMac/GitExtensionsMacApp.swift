import GitUI
import SwiftUI

@main
struct GitExtensionsMacApp: App {
    @NSApplicationDelegateAdaptor(GitExtensionsApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        GitExtensionsAppScene()
    }
}
