//
//  fullmoonApp.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI
import SwiftData
import MLXLLM

@main
struct LunarApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @StateObject private var appPreferences: AppPreferences
    @StateObject private var modelSettings: ModelSettingsStore
    @StateObject private var usageStats: UsageStatsStore
    @StateObject private var knowledgeBase = KnowledgeBaseIndex()
    @StateObject private var localhostServer: LocalhostServerController
    @State private var llm: LLMEvaluator

    init() {
        let modelSettings = ModelSettingsStore()
        let appPreferences = AppPreferences()
        let llm = LLMEvaluator(modelSettingsStore: modelSettings)
        _appPreferences = StateObject(wrappedValue: appPreferences)
        _modelSettings = StateObject(wrappedValue: modelSettings)
        _usageStats = StateObject(wrappedValue: UsageStatsStore())
        _localhostServer = StateObject(
            wrappedValue: LocalhostServerController(
                appPreferences: appPreferences,
                modelSettings: modelSettings,
                llm: llm
            )
        )
        _llm = State(wrappedValue: llm)
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Thread.self, Message.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            // If the store is corrupted or incompatible, delete it and retry
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeURL = appSupport.appendingPathComponent("default.store")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent().appendingPathComponent("default.store" + suffix))
            }
            do {
                return try ModelContainer(for: schema)
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(sharedModelContainer)
                .environmentObject(appPreferences)
                .environmentObject(modelSettings)
                .environmentObject(usageStats)
                .environmentObject(knowledgeBase)
                .environmentObject(localhostServer)
                .environment(llm)
                .environment(DeviceStat())
                .preferredColorScheme(appPreferences.appColorScheme.colorScheme)
                .onAppear {
                    knowledgeBase.resolveBookmark()
                }
                .task {
                    await localhostServer.restoreIfNeeded()
                }
                #if os(macOS)
                .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
                #endif
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Main Window") {
                    if let mainWindow = NSApp.windows.first {
                        mainWindow.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        #endif
    }
}

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var closedWindowsStack = [NSWindow]()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainWindow = NSApp.windows.first
        mainWindow?.delegate = self
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // if there’s a recently closed window, bring that back
        if let lastClosed = closedWindowsStack.popLast() {
            lastClosed.makeKeyAndOrderFront(self)
        } else {
            // otherwise, un-minimize any minimized windows
            for window in sender.windows where window.isMiniaturized {
                window.deminiaturize(nil)
            }
        }
        return false
    }
    
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            closedWindowsStack.append(window)
        }
    }
}
#endif
