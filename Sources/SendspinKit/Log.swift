// ABOUTME: Centralized os.Logger instances for SendspinKit subsystems
// ABOUTME: Provides structured logging with subsystem/category filtering via Console.app

import os

/// Centralized loggers for SendspinKit subsystems.
///
/// Each logger uses the `com.sendspin.kit` subsystem with a category matching
/// the module it serves. Filter in Console.app or `log stream` by subsystem
/// and/or category:
///
/// ```bash
/// log stream --level debug --predicate 'subsystem == "com.sendspin.kit"'
/// log stream --level debug --predicate 'subsystem == "com.sendspin.kit" AND category == "audio"'
/// ```
internal enum Log {
    static let client = Logger(subsystem: "com.sendspin.kit", category: "client")
    static let transport = Logger(subsystem: "com.sendspin.kit", category: "transport")
    static let discovery = Logger(subsystem: "com.sendspin.kit", category: "discovery")
    static let audio = Logger(subsystem: "com.sendspin.kit", category: "audio")
    static let volume = Logger(subsystem: "com.sendspin.kit", category: "volume")
}
