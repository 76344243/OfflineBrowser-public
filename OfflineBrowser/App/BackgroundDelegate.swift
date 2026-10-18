import UIKit
final class BackgroundDelegate:NSObject,UIApplicationDelegate {
    var environment:AppEnvironment? = AppEnvironment.shared
    func application(_ application:UIApplication,handleEventsForBackgroundURLSession identifier:String,completionHandler:@escaping ()->Void) {
        Task { do { guard let environment else { completionHandler(); return }; try await environment.broker.backgroundEvents(identifier,completion:completionHandler) } catch { completionHandler() } }
    }
}
