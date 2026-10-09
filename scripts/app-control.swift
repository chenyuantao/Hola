import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 3,
      ["quit", "verify"].contains(CommandLine.arguments[1]) else {
    fputs("Usage: swift app-control.swift quit|verify /absolute/path/HolaDev.app\n", stderr)
    exit(2)
}

let action = CommandLine.arguments[1]
let expected = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard let bundleID = Bundle(url: expected)?.bundleIdentifier else {
    fputs("The app bundle has no bundle identifier.\n", stderr)
    exit(2)
}

func instances() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { !$0.isTerminated }
}

if action == "quit" {
    // Stop the former local build that shared the release ID, without stopping an installed release.
    let legacyURL = expected.deletingLastPathComponent().appendingPathComponent("Hola.app").standardizedFileURL
    let legacy = NSRunningApplication.runningApplications(withBundleIdentifier: "local.hola")
        .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == legacyURL }
    let running = instances() + legacy
    func remaining() -> [NSRunningApplication] { running.filter { Darwin.kill($0.processIdentifier, 0) == 0 } }
    for app in running { _ = app.terminate() }
    let gracefulDeadline = Date().addingTimeInterval(8)
    while !remaining().isEmpty && Date() < gracefulDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    for app in remaining() { _ = app.forceTerminate() }
    let forcedDeadline = Date().addingTimeInterval(3)
    while !remaining().isEmpty && Date() < forcedDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard remaining().isEmpty else {
        fputs("HolaDev did not quit; the new build was not launched.\n", stderr)
        exit(1)
    }
    print("Stopped \(running.count) development instance(s).")
} else {
    let deadline = Date().addingTimeInterval(8)
    var firstSeen: Date?
    while Date() < deadline {
        if let app = instances().first(where: { $0.bundleURL?.standardizedFileURL == expected }) {
            if firstSeen == nil { firstSeen = Date() }
            if Date().timeIntervalSince(firstSeen!) >= 2 {
                print("Running: \(expected.path) (pid \(app.processIdentifier))")
                exit(0)
            }
        } else {
            firstSeen = nil
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fputs("The new HolaDev build did not appear as a running app.\n", stderr)
    exit(1)
}
