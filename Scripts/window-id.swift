#!/usr/bin/env swift
// Prints the id of the largest window a process owns. `screencapture -l` takes that number.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("Usage: window-id.swift <pid>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

let mine = windows.filter { $0[kCGWindowOwnerPID as String] as? Int == pid }
let biggest = mine.max { first, second in
    func area(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
        else { return 0 }
        return width * height
    }
    return area(first) < area(second)
}

guard let id = biggest?[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
