import SendspinKit
import Testing

@Suite("Public pairing surface")
struct PublicSurfaceTests {
    @Test("host-local pairing configuration and pairing window APIs remain public")
    @MainActor
    func pairingSurfaceCompiles() async throws {
        let pairingPsk = Psk.generate()
        let configuration = PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: true,
            recordModePskId: "record-mode",
            unpairedAccessEnabled: true
        )
        let runtime = PairingConfigurationRuntime(configuration: configuration)
        await runtime.update(configuration)
        #expect(await runtime.snapshot() == configuration)

        let client = try SendspinClient(
            identity: .generate(),
            name: "Public Surface",
            roles: [],
            pairing: PairingConfiguration(pairingPsk: pairingPsk)
        )
        do {
            try await client.openPairingWindow()
        } catch SendspinClientError.notConnected {
            // The API remains callable before a transport is connected.
        }
    }
}
