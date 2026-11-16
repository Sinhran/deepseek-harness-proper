import AppKit
import DSHCore

if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    DSHApplication.renderIcon(to: CommandLine.arguments[i + 1])
    exit(0)
}

DSHApplication.run()
