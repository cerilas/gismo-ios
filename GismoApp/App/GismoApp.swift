import SwiftUI
import GoogleSignIn

@main
struct GismoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var userAuth = AuthService.shared
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(3)
                } else if !userAuth.isAuthenticated {
                    AuthView()
                        .transition(.opacity)
                        .zIndex(2)
                } else if userAuth.needsRobotNamingOnboarding {
                    RobotNamingOnboardingView()
                        .transition(.opacity)
                        .zIndex(1)
                } else {
                    RobotListView()
                        .transition(.opacity)
                        .zIndex(0)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: showSplash)
            .animation(.easeInOut(duration: 0.4), value: userAuth.isAuthenticated)
            .animation(.easeInOut(duration: 0.4), value: userAuth.needsRobotNamingOnboarding)
            .onAppear {
                GoogleAuthService.shared.checkStatus()
                userAuth.loadSavedSession()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    showSplash = false
                }
            }
            .onOpenURL { url in
                GIDSignIn.sharedInstance.handle(url)
            }
            .preferredColorScheme(.dark)
        }
    }
}
