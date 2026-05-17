import SwiftUI

@main
struct GismoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                } else {
                    RobotListView()
                        .transition(.opacity)
                        .zIndex(0)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: showSplash)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    showSplash = false
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
