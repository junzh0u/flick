import AppKit
import Darwin

/// Whether Stage Manager is on, read fresh so toggling it takes effect at once.
public func stageManagerEnabled() -> Bool {
    let domain = "com.apple.WindowManager" as CFString
    CFPreferencesAppSynchronize(domain)
    return CFPreferencesGetAppBooleanValue("GloballyEnabled" as CFString, domain, nil)
}

/// Every display, in Accessibility coordinates: NSScreen's are bottom-left,
/// y up.
@MainActor
public func currentDisplays() -> [Display] {
    let screens = NSScreen.screens
    guard let mainHeight = screens.first?.frame.height else { return [] }
    func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
    return screens.map {
        Display(frame: flip($0.frame), visible: flip($0.visibleFrame),
                fps: max($0.maximumFramesPerSecond, 60), name: $0.localizedName)
    }
}

/// Every display's stage, as WindowManager reports it to AppKit — which keeps
/// new windows inside it — through the private WindowManagement framework: a
/// WMClientWindowManager receives the WMStages shortly after it connects,
/// their frames already in Accessibility coordinates.
///
/// One client stays connected for the life of the process, so a running app
/// reads the current stages at once; a fresh process waits for the first
/// report. Empty if the framework changes or nothing arrives in time.
@MainActor
public final class StageWatcher {
    public static let shared = StageWatcher()

    private let manager: NSObject?

    private init() {
        let framework = "/System/Library/PrivateFrameworks/WindowManagement.framework/WindowManagement"
        guard dlopen(framework, RTLD_NOW) != nil,
              let client = NSClassFromString("WMClientWindowManager") as? NSObject.Type,
              client.instancesRespond(to: NSSelectorFromString("stages")) else {
            manager = nil
            return
        }
        manager = client.init()
    }

    /// The stage frames, running the main run loop up to `timeout` for the
    /// first report.
    public func frames(waitingUpTo timeout: TimeInterval) -> [CGRect] {
        guard let manager else { return [] }
        let deadline = Date(timeIntervalSinceNow: timeout)
        var stages = manager.value(forKey: "stages") as? NSDictionary ?? [:]
        while stages.count == 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            stages = manager.value(forKey: "stages") as? NSDictionary ?? [:]
        }
        return stages.allValues.compactMap {
            ($0 as? NSObject)?.value(forKey: "frame") as? NSValue
        }.map(\.rectValue).filter { !$0.isEmpty }
    }
}
