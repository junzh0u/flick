// Flick: two-finger swipes on a window's title bar fill or split the window,
// Stage Manager-aware.
//
//   flick                                   run the menu-bar app
//   flick fill [--dry-run] [--duration S]   fill the focused window
//   flick tile [--dry-run] [--duration S] left|right|top|bottom
//   flick probe X Y                         is there a title bar at X Y?
//
// The commands act once and exit; they need Accessibility permission for
// whatever runs them.

import AppKit
import FlickCore

let usage = """
    usage: flick
           flick fill [--dry-run] [--duration SECONDS]
           flick tile [--dry-run] [--duration SECONDS] left|right|top|bottom
           flick probe X Y
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("flick: \(message)\n".data(using: .utf8)!)
    exit(1)
}

@MainActor
func arrangeFrontmost(_ command: String, _ args: ArraySlice<String>) -> Never {
    var args = args
    var dryRun = false
    var duration = 0.2
    var action: Action? = command == "fill" ? .fill : nil
    while let arg = args.popFirst() {
        switch arg {
        case "--dry-run":
            dryRun = true
        case "--duration":
            guard let value = args.popFirst().flatMap(Double.init), value >= 0 else {
                fail("--duration needs a number of seconds")
            }
            duration = value
        case _ where command == "tile" && action == nil
            && ["left", "right", "top", "bottom"].contains(arg):
            action = Action(rawValue: arg)
        default:
            fail("unknown argument \(arg)\n\(usage)")
        }
    }
    guard let action else { fail(usage) }
    guard AXIsProcessTrusted() else { fail("needs Accessibility permission") }
    guard let target = AppWindow.frontmost() else { fail("the frontmost app has no focused window") }
    do {
        let arrangement = try arrangement(action, for: target, stageWait: 0.25)
        if dryRun {
            print(arrangement.summary)
        } else {
            perform(arrangement, duration: duration)
        }
    } catch {
        fail(error.description)
    }
    exit(0)
}

@MainActor
func probe(_ args: ArraySlice<String>) -> Never {
    guard args.count == 2, let x = Double(args.first!), let y = Double(args.last!) else {
        fail(usage)
    }
    guard AXIsProcessTrusted() else { fail("needs Accessibility permission") }
    guard let target = AppWindow.titleBar(at: CGPoint(x: x, y: y)) else {
        print("no title bar at \(Int(x)) \(Int(y))")
        exit(1)
    }
    print("\(target.appName): \(target.title ?? "untitled")")
    exit(0)
}

var args = CommandLine.arguments.dropFirst()
// Launched as an app, the arguments are empty or macOS's own -flags.
if let command = args.first, !command.hasPrefix("-") {
    args = args.dropFirst()
    switch command {
    case "fill", "tile": arrangeFrontmost(command, args)
    case "probe": probe(args)
    default: fail(usage)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
