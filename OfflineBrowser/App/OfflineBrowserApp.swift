import SwiftUI
@main struct OfflineBrowserApp: App {
    @UIApplicationDelegateAdaptor(BackgroundDelegate.self) private var delegate
    @StateObject private var environment = AppEnvironment.shared
    var body: some Scene { WindowGroup { LibraryView(environment:environment).onAppear { delegate.environment=environment } } }
}
