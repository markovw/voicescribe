import SwiftUI
import AppKit
import CoreText

@main @MainActor struct VoiceScribeApp: App {
    init() {
        if let url = Bundle.main.url(forResource: "GeistMono", withExtension: "ttf", subdirectory: "Assets/Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    @StateObject private var studio = AppDependencies.makeStudio()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(studio).preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 700).tint(accent)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }.defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Open file…") { studio.choose() }.keyboardShortcut("o") }
        }
    }
}
