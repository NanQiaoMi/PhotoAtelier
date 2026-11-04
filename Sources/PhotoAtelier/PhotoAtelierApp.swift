import SwiftUI
import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false
    private var batchObserver: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        batchObserver = AppModel.shared.$batchRunning.removeDuplicates().sink { [weak self] running in
            if !running { self?.finishTerminationIfNeeded() }
        }
        // Test/verification hook: open a folder on launch without driving the
        // NSOpenPanel through accessibility automation. Only active when the
        // explicit `--open-folder <path>` argument is passed.
        if let index = CommandLine.arguments.firstIndex(of: "--open-folder"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let url = URL(fileURLWithPath: path, isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppModel.shared.loadFolder(url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.batchRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "批量处理仍在进行"
        alert.informativeText = "退出会停止尚未完成的照片，已导出的照片会保留。"
        alert.addButton(withTitle: "继续处理"); alert.addButton(withTitle: "停止并退出")
        if alert.runModal() == .alertSecondButtonReturn {
            // The modal run loop can deliver batch completion before this choice.
            // With no work left, no further publisher event will finish a deferred quit.
            guard AppModel.shared.batchRunning else { return .terminateNow }
            terminationPending = true
            AppModel.shared.cancelBatch()
            return .terminateLater
        }
        return .terminateCancel
    }

    func finishTerminationIfNeeded() {
        if terminationPending { NSApp.reply(toApplicationShouldTerminate: true) }
    }
}

@main
struct PhotoAtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        WindowGroup("光屿 · Photo Atelier") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1120, minHeight: 740)
                .onAppear { SmokeHarness.startIfRequested(model: model) }
        }
        .defaultSize(width: 1400, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!model.canUndo || model.batchRunning)
                Button("重做") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo || model.batchRunning)
            }
            CommandGroup(replacing: .newItem) {
                Button("打开照片…") { model.chooseInput() }.keyboardShortcut("o")
                    .disabled(model.batchRunning)
                Button("导入 LUT…") { model.importLUT() }.keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.batchRunning || model.lutLibraryBusy)
                Divider()
                Button("保存配方…") { model.saveRecipe() }.keyboardShortcut("s")
                Button("载入配方…") { model.loadRecipe() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.batchRunning)
            }
        }
    }
}
