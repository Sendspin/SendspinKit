import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("Starscream_Starscream.bundle").path
        let buildPath = "/Users/harper/Public/src/personal/ma-interface/SendspinKit/Examples/ControllerClient/.build/arm64-apple-macosx/debug/Starscream_Starscream.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}