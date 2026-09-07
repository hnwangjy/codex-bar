import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
