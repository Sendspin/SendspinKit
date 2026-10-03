import Foundation

/// Whether normal roles may be activated before the server is cryptographically paired.
/// Both policies use Noise encryption and permit the setup traffic needed for pairing.
public enum AccessPolicy: Sendable, Equatable {
    case pairedOnly
    case allowUnpaired
}

/// The code presentation the device can actually provide, in addition to Pairing PSK.
public enum PairingPresentation: Sendable, Equatable {
    /// Present the device's persistent setup token through an intentional operator flow.
    case tokenOnly
    /// A display capable of showing digits and rendering QR codes.
    case display
    /// A display that can show decimal digits but cannot render QR codes.
    case digitDisplay
    /// A speaker with no display. Audio is presented by the host application.
    case speaker
    /// A display and speaker, with QR support on the display.
    case displayAndSpeaker
    /// Use the static code already provisioned in the persistent device.
    case staticCode

    var usesDynamicCode: Bool {
        switch self {
        case .tokenOnly, .staticCode: false
        case .display, .digitDisplay, .speaker, .displayAndSpeaker: true
        }
    }

    var outChannels: [String] {
        switch self {
        case .display, .digitDisplay: ["display"]
        case .speaker: ["speaker"]
        case .displayAndSpeaker: ["display", "speaker"]
        case .tokenOnly, .staticCode: []
        }
    }

    var formats: [String] {
        switch self {
        case .display, .displayAndSpeaker: ["digits", "qr_code"]
        case .digitDisplay, .speaker: ["digits"]
        case .tokenOnly, .staticCode: []
        }
    }
}
