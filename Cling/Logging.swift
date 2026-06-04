//
//  Logging.swift
//  Cling
//
//  Each file/component creates its own os.Logger with a descriptive category:
//
//      private let log = Logger(subsystem: clingSubsystem, category: "MyComponent")
//
//  Note: os.Logger interpolation uses `@autoclosure @escaping` closures, so a value
//  that needs `self` should be hoisted into a local before the log call to avoid
//  capturing `self` (or requiring an explicit `self.` inside escaping closures).
//

import Foundation
import OSLog

let clingSubsystem = Bundle.main.bundleIdentifier ?? "com.lowtechguys.Cling"
