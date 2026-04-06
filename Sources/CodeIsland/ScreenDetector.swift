import AppKit

struct ScreenDetector {
    /// Simulated notch width for non-notch screens — scales with screen width
    private static func fakeNotchWidth(for screen: NSScreen) -> CGFloat {
        let screenW = screen.frame.width
        return min(max(screenW * 0.14, 160), 240)
    }

    /// Preferred screen: built-in (notch) first, then main
    static var preferredScreen: NSScreen {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil {
                    return screen
                }
            }
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    static var hasNotch: Bool {
        screenHasNotch(preferredScreen)
    }

    /// Check if a specific screen has a notch
    static func screenHasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
        }
        return false
    }

    /// Height of the notch/menu bar area for a specific screen
    static func topBarHeight(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let real = screen.safeAreaInsets.top
            if real > 0 { return real }
        }
        // Menu bar height — only present on the screen that has it
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // On the primary screen, this is ~25pt (non-notch) or ~37pt (notch)
        // On secondary screens without menu bar, this is 0
        if menuBarHeight > 5 { return menuBarHeight }
        // Fallback: use main screen's menu bar height, or default 25
        if let main = NSScreen.main {
            let mainMenuBar = main.frame.maxY - main.visibleFrame.maxY
            if mainMenuBar > 5 { return mainMenuBar }
        }
        return 25
    }

    /// Height of the notch area — returns menu bar height on non-notch screens
    static var notchHeight: CGFloat {
        topBarHeight(for: preferredScreen)
    }

    /// Width of the notch — returns simulated width on non-notch screens
    static var notchWidth: CGFloat {
        notchWidth(for: preferredScreen)
    }

    /// Width of the notch for a specific screen
    static func notchWidth(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            if leftWidth > 0 || rightWidth > 0 {
                return screen.frame.width - leftWidth - rightWidth
            }
        }
        return fakeNotchWidth(for: screen)
    }
}
