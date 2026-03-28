import AppKit
import SwiftUI

private final class DraggableHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class RecordingHUDController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let hostingView: DraggableHostingView<RecordingHUDView>
    private var isVisible = false
    private var cachedAnchorRect: CGRect?
    private var lastAnchorRefreshAt = Date.distantPast
    private var manualOrigin: NSPoint?
    private var isApplyingProgrammaticOrigin = false

    override init() {
        hostingView = DraggableHostingView(rootView: RecordingHUDView(runtime: AppRuntimeState()))

        let panel = DraggableHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.alphaValue = 0
        panel.contentView = hostingView

        self.panel = panel
        super.init()
        panel.delegate = self
    }

    func sync(runtime: AppRuntimeState) {
        guard shouldDisplay(runtime: runtime) else {
            hidePanel()
            return
        }

        positionPanel(forceRefreshAnchor: !isVisible || runtime.isRecording)
        hostingView.rootView = RecordingHUDView(runtime: runtime)
        showPanel()
    }

    private func shouldDisplay(runtime: AppRuntimeState) -> Bool {
        runtime.isRecording || runtime.isTranscribing || runtime.pendingTranscriptionCount > 0
    }

    private func positionPanel(forceRefreshAnchor: Bool) {
        let now = Date()
        if forceRefreshAnchor || now.timeIntervalSince(lastAnchorRefreshAt) > 0.22 {
            cachedAnchorRect = FocusedInputAnchorResolver.resolveAnchorRect()
            lastAnchorRefreshAt = now
        }

        let panelSize = panel.frame.size

        if let manualOrigin {
            applyPanelOrigin(manualOrigin)
            return
        }

        guard let anchorRect = cachedAnchorRect else {
            positionPanelFallback(panelSize: panelSize)
            return
        }

        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main
        guard let targetScreen else {
            positionPanelFallback(panelSize: panelSize)
            return
        }

        let visibleFrame = targetScreen.visibleFrame.insetBy(dx: 12, dy: 12)
        var originX = anchorRect.midX - panelSize.width / 2
        var originY = anchorRect.maxY + 12

        if originX + panelSize.width > visibleFrame.maxX {
            originX = visibleFrame.maxX - panelSize.width
        }
        if originX < visibleFrame.minX {
            originX = visibleFrame.minX
        }

        if originY + panelSize.height > visibleFrame.maxY {
            originY = anchorRect.minY - panelSize.height - 12
        }
        if originY < visibleFrame.minY {
            originY = max(visibleFrame.minY, visibleFrame.midY - panelSize.height / 2)
        }

        applyPanelOrigin(NSPoint(x: originX, y: originY))
    }

    private func positionPanelFallback(panelSize: CGSize) {
        if let manualOrigin {
            applyPanelOrigin(manualOrigin)
            return
        }

        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let targetScreen else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let originX = visibleFrame.midX - panelSize.width / 2
        let originY = visibleFrame.midY - panelSize.height / 2 + visibleFrame.height * 0.05
        applyPanelOrigin(NSPoint(x: originX, y: originY))
    }

    private func applyPanelOrigin(_ origin: NSPoint) {
        isApplyingProgrammaticOrigin = true
        panel.setFrameOrigin(origin)
        isApplyingProgrammaticOrigin = false
    }

    private func showPanel() {
        if !isVisible {
            panel.orderFrontRegardless()
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            isVisible = true
            return
        }

        panel.orderFrontRegardless()
        panel.alphaValue = 1
    }

    private func hidePanel() {
        guard isVisible else {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
        isVisible = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingProgrammaticOrigin else {
            return
        }
        manualOrigin = panel.frame.origin
    }
}
