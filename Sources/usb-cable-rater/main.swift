// usb-cable-rater: macOS CLI for reading USB-C cable e-marker data over IOKit
// and sorting cables by their data-rate bucket.
//
// This entry point is intentionally thin: it forwards the command-line arguments
// (minus the program name) to runCLI in CableRater/CLI.swift and exits with the
// returned code. The live-watch path inside runCLI runs the main dispatch loop
// and exits via its own SIGINT handler.

import Foundation
import CableRater

// Drop argv[0] (the program path) and hand the rest to the CLI driver.
let arguments = Array(CommandLine.arguments.dropFirst())
let exitCode = runCLI(arguments)
exit(exitCode)
