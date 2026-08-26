import Foundation
@testable import SendspinKit
import Testing

@Suite("Management role")
struct ManagementTests {
    @Test("list-records succeeds only in a paired management activity")
    func listRecordsGatingAndSuccess() async throws {
        let sessionPsk = Psk.generate()
        let pairingPsk = Psk.generate()
        let record = PairingRecord(psk: Psk.generate(), serverId: "server")
        let store = try InMemoryPairingRecordStore(records: [record], pairingPsk: pairingPsk)
        let runtime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairingPsk, recordModePskId: record.pskId))
        let fixture = try await managementFixture(psk: sessionPsk, store: store, runtime: runtime)
        try await fixture.server.sendJSON(request(ManagementListRecordsMessage.typeString))
        let reply = try await waitForManagementResult(from: fixture.server)
        let message = try JSONDecoder().decode(ManagementResultMessage.self, from: reply)
        #expect(message.payload.result == ManagementResultCode.success)
        #expect(message.payload.data != nil)
        await fixture.connection.shutdown()
    }

    @Test("add-record stores shared and stored-pubkey records with unused state")
    func addRecordVariants() async throws {
        for serverId in [String?.none, "server-id"] {
            let pairingPsk = Psk.generate()
            let store = InMemoryPairingRecordStore(pairingPsk: pairingPsk)
            let runtime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairingPsk))
            let fixture = try await managementFixture(store: store, runtime: runtime)
            let added = Psk.generate()
            try await fixture.server.sendJSON(addRecordRequest(added, serverId: serverId))
            let result = try await waitForManagementResult(from: fixture.server)
            #expect(resultCode(result) == .success)
            let baseline = await fixture.server.clientJSONMessages(ofType: ManagementResultMessage.typeString).count
            try await fixture.server.sendJSON(request(ManagementListRecordsMessage.typeString))
            let listed = try await waitForManagementResult(from: fixture.server, after: baseline)
            let record = try #require(records(in: listed).first { $0["psk_id"] as? String == added.pskId })
            #expect(record["used"] as? Bool == false)
            if let serverId {
                #expect(record["server_id"] as? String == serverId)
            } else {
                #expect(record["server_id"] == nil)
            }
            await fixture.connection.shutdown()
        }
    }

    @Test("add-record rejects every occupied psk_id")
    func addRecordAlreadyExistsSources() async throws {
        let existing = Psk.generate()
        let pairing = Psk.generate()
        let cases: [(Psk, Psk, [PairingRecord])] = [
            (Psk.generate(), pairing, [PairingRecord(psk: existing)]),
            (Psk.sentinel, pairing, []),
            (Psk.generate(), pairing, []),
            (Psk.generate(), pairing, [])
        ]
        for (index, item) in cases.enumerated() {
            let session = index == 2 ? item.0 : Psk.generate()
            let requestPsk = index == 0 ? existing : index == 1 ? Psk.sentinel : index == 2 ? session : pairing
            let store = try InMemoryPairingRecordStore(records: item.2, pairingPsk: pairing)
            let runtime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing))
            let fixture = try await managementFixture(psk: session, store: store, runtime: runtime)
            try await fixture.server.sendJSON(addRecordRequest(requestPsk))
            let reply = try await waitForManagementResult(from: fixture.server)
            #expect(resultCode(reply) == .alreadyExists)
            await fixture.connection.shutdown()
        }
    }

    @Test("add-record rejects wrong-length and non-base64url PSKs")
    func addRecordInvalid() async throws {
        for malformed in ["AA", String(repeating: "!", count: 43)] {
            let fixture = try await managementFixture()
            try await fixture.server
                .sendJSON(#"{"type":"management/add-record","payload":{"psk":"MALFORMED","server_id":null}}"#.replacingOccurrences(
                    of: "MALFORMED",
                    with: malformed
                ))
            let reply = try await waitForManagementResult(from: fixture.server)
            #expect(resultCode(reply) == .invalid)
            await fixture.connection.shutdown()
        }
    }

    @Test("add-record reports storage_exhausted when insert cannot persist")
    func addRecordStorageExhausted() async throws {
        let store = TranscriptPairingStore(insertError: .storageExhausted)
        let fixture = try await managementFixture(store: store)
        try await fixture.server.sendJSON(addRecordRequest(Psk.generate()))
        let reply = try await waitForManagementResult(from: fixture.server)
        #expect(resultCode(reply) == .storageExhausted)
        await fixture.connection.shutdown()
    }

    @Test("remove-record removes a record and reports not_found for an unknown identifier")
    func removeRecordOutcomes() async throws {
        let target = Psk.generate()
        let fallback = Psk.generate()
        let pairing = Psk.generate()
        let store = try InMemoryPairingRecordStore(records: [PairingRecord(psk: target), PairingRecord(psk: fallback)], pairingPsk: pairing)
        let runtime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing, recordModePskId: fallback.pskId))
        let fixture = try await managementFixture(store: store, runtime: runtime)
        try await fixture.server.sendJSON(removeRecordRequest(target.pskId))
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .success)
        #expect(await !store.listRecords().contains { $0.pskId == target.pskId })
        let baseline = await fixture.server.clientJSONMessages(ofType: ManagementResultMessage.typeString).count
        try await fixture.server.sendJSON(request(ManagementListRecordsMessage.typeString))
        let listed = try await waitForManagementResult(from: fixture.server, after: baseline)
        let listedRecords = try records(in: listed)
        #expect(listedRecords.contains { $0["psk_id"] as? String == target.pskId } == false)
        try await fixture.server.sendJSON(removeRecordRequest(Psk.generate().pskId))
        #expect(try await resultCode(waitForManagementResult(from: fixture.server, after: baseline + 1)) == .notFound)
        await fixture.connection.shutdown()
    }

    @Test("remove-record rejects the record-mode fallback and removes the own record only after replying")
    func removeRecordInvalidAndOwnRecordOrdering() async throws {
        let fallback = Psk.generate()
        let pairing = Psk.generate()
        let store = try InMemoryPairingRecordStore(records: [PairingRecord(psk: fallback)], pairingPsk: pairing)
        let runtime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing, recordModePskId: fallback.pskId))
        let fixture = try await managementFixture(store: store, runtime: runtime)
        try await fixture.server.sendJSON(removeRecordRequest(fallback.pskId))
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .invalid)
        await fixture.connection.shutdown()

        let own = Psk.generate()
        let ownStore = try InMemoryPairingRecordStore(records: [PairingRecord(psk: own)], pairingPsk: pairing)
        let ownRuntime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing))
        let ownFixture = try await managementFixture(psk: own, store: ownStore, runtime: ownRuntime)
        try await ownFixture.server.sendJSON(removeRecordRequest(own.pskId))
        let ownServer = ownFixture.server
        #expect(await waitUntil { await ownServer.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count == 1 })
        let messages = await ownFixture.server.decryptedMessages.compactMap { message -> (String, Data)? in
            guard message.first == NoiseFrameType.json else { return nil }
            let json = Data(message.dropFirst())
            guard let type = SendspinEncoding.messageType(of: json) else { return nil }
            return (type, json)
        }
        let resultIndex = try #require(messages.firstIndex { $0.0 == ManagementResultMessage.typeString })
        let goodbyeIndex = try #require(messages.firstIndex { $0.0 == ClientGoodbyeMessage.typeString })
        #expect(resultIndex < goodbyeIndex)
        let goodbye = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: messages[goodbyeIndex].1)
        #expect(goodbye.payload.reason == .unauthorized)
        #expect(await ownStore.listRecords().isEmpty)
        #expect(await ownFixture.server.disconnectCalled)
        await ownFixture.connection.shutdown()
    }

    @Test("get-pairing-config exposes only public configuration and omits secrets and unimplemented methods")
    func getPairingConfigShape() async throws {
        let pairing = Psk.generate()
        let fallback = Psk.generate()
        let store = try InMemoryPairingRecordStore(records: [PairingRecord(psk: fallback)], pairingPsk: pairing)
        let runtime = PairingConfigurationRuntime(configuration: configuration(
            pairingPsk: pairing,
            recordModePskId: fallback.pskId,
            pairingEnabled: false,
            unpaired: false
        ))
        let fixture = try await managementFixture(store: store, runtime: runtime)
        try await fixture.server.sendJSON(request(ManagementGetPairingConfigMessage.typeString))
        let reply = try await waitForManagementResult(from: fixture.server)
        let payload = try rawPayload(reply)
        let data = try #require(payload["data"] as? [String: Any])
        #expect((data["pairing_psk"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((data["record_mode"] as? [String: Any])?["psk_id"] as? String == fallback.pskId)
        #expect((data["unpaired_access"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect(data["static_pairing_code"] == nil)
        #expect(data["dynamic_pairing_code"] == nil)
        #expect((data["pairing_psk"] as? [String: Any])?["psk"] == nil)
        #expect(String(data: reply, encoding: .utf8)?.contains(pairing.base64URL) == false)
        await fixture.connection.shutdown()
    }

    @Test("set-pairing-config applies an unpaired-access patch without changing pairing PSK settings")
    func setPairingConfigPatchSemantics() async throws {
        let pairing = Psk.generate()
        let store = TranscriptPairingStore()
        let runtime = PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing, pairingEnabled: false, unpaired: true))
        let fixture = try await managementFixture(store: store, runtime: runtime)
        try await fixture.server.sendJSON(#"{"type":"management/set-pairing-config","payload":{"unpaired_access":{"enabled":false}}}"#)
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .success)
        try await fixture.server.sendJSON(request(ManagementGetPairingConfigMessage.typeString))
        let reply = try await waitForManagementResult(from: fixture.server, after: 1)
        let data = try #require(try rawPayload(reply)["data"] as? [String: Any])
        #expect((data["pairing_psk"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((data["unpaired_access"] as? [String: Any])?["enabled"] as? Bool == false)
        await fixture.connection.shutdown()
    }

    @Test("set-pairing-config rotates the pairing PSK and the new PSK is reserved")
    func setPairingConfigPairingPskRotation() async throws {
        let old = Psk.generate()
        let replacement = Psk.generate()
        let fixture = try await managementFixture(
            store: TranscriptPairingStore(),
            runtime: PairingConfigurationRuntime(configuration: configuration(pairingPsk: old))
        )
        try await fixture.server.sendJSON(setPairingPskRequest(replacement))
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .success)
        try await fixture.server.sendJSON(request(ManagementGetPairingConfigMessage.typeString))
        let configReply = try await waitForManagementResult(from: fixture.server, after: 1)
        let data = try #require(try rawPayload(configReply)["data"] as? [String: Any])
        #expect((data["pairing_psk"] as? [String: Any])?["enabled"] as? Bool == true)
        try await fixture.server.sendJSON(addRecordRequest(replacement))
        #expect(try await resultCode(waitForManagementResult(from: fixture.server, after: 2)) == .alreadyExists)
        await fixture.connection.shutdown()
    }

    @Test("set-pairing-config accepts record mode only for an existing shared record")
    func setPairingConfigRecordModeSuccess() async throws {
        let pairing = Psk.generate()
        let shared = Psk.generate()
        let store = try InMemoryPairingRecordStore(records: [PairingRecord(psk: shared)], pairingPsk: pairing)
        let fixture = try await managementFixture(
            store: store,
            runtime: PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing))
        )
        try await fixture.server.sendJSON(setRecordModeRequest(shared.pskId))
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .success)
        try await fixture.server.sendJSON(request(ManagementGetPairingConfigMessage.typeString))
        let reply = try await waitForManagementResult(from: fixture.server, after: 1)
        let configData = try #require(try rawPayload(reply)["data"] as? [String: Any])
        _ = try #require(configData["record_mode"] as? [String: Any])
        #expect(try (#require(try rawPayload(reply)["data"] as? [String: Any])["record_mode"] as? [String: Any])?["psk_id"] as? String == shared
            .pskId)
        await fixture.connection.shutdown()
    }

    @Test("set-pairing-config rejects missing, stored-pubkey, static-code, and dynamic-code configuration")
    func setPairingConfigInvalid() async throws {
        let pairing = Psk.generate()
        let stored = Psk.generate()
        let store = try InMemoryPairingRecordStore(records: [PairingRecord(psk: stored, serverId: "server")], pairingPsk: pairing)
        let fixture = try await managementFixture(
            store: store,
            runtime: PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing))
        )
        // record_mode without psk_id fails payload decoding; the malformed request
        // still owes the server its single ordered invalid reply.
        let missing = #"{"type":"management/set-pairing-config","payload":{"record_mode":{}}}"#
        try await fixture.server.sendJSON(missing)
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .invalid)
        let storedRequest = setRecordModeRequest(stored.pskId)
        try await fixture.server.sendJSON(storedRequest)
        #expect(try await resultCode(waitForManagementResult(from: fixture.server, after: 1)) == .invalid)
        try await fixture.server.sendJSON(#"{"type":"management/set-pairing-config","payload":{"static_pairing_code":{"enabled":true}}}"#)
        #expect(try await resultCode(waitForManagementResult(from: fixture.server, after: 2)) == .invalid)
        try await fixture.server.sendJSON(#"{"type":"management/set-pairing-config","payload":{"dynamic_pairing_code":{"enabled":true}}}"#)
        #expect(try await resultCode(waitForManagementResult(from: fixture.server, after: 3)) == .invalid)
        await fixture.connection.shutdown()
    }

    @Test("set-pairing-config reports already_exists for Sentinel and stored-record collisions")
    func setPairingConfigAlreadyExists() async throws {
        let stored = Psk.generate()
        for collision in [Psk.sentinel, stored] {
            let pairing = Psk.generate()
            let store = try InMemoryPairingRecordStore(records: [PairingRecord(psk: stored)], pairingPsk: pairing)
            let fixture = try await managementFixture(
                store: store,
                runtime: PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing))
            )
            try await fixture.server.sendJSON(setPairingPskRequest(collision))
            #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .alreadyExists)
            await fixture.connection.shutdown()
        }
    }

    @Test("set-pairing-config reports storage_exhausted when saving fails")
    func setPairingConfigStorageExhausted() async throws {
        let fixture = try await managementFixture(store: TranscriptPairingStore(saveError: .storageExhausted))
        try await fixture.server.sendJSON(#"{"type":"management/set-pairing-config","payload":{"unpaired_access":{"enabled":false}}}"#)
        #expect(try await resultCode(waitForManagementResult(from: fixture.server)) == .storageExhausted)
        await fixture.connection.shutdown()
    }

    @Test("the default in-memory store omits storage accounting from every result")
    func defaultStoreOmitsStorage() async throws {
        let fixture = try await managementFixture()
        let requests = [
            request(ManagementListRecordsMessage.typeString),
            addRecordRequest(Psk.generate()),
            addRecordRequest(Psk.sentinel),
            #"{"type":"management/add-record","payload":{"psk":"AA"}}"#,
            removeRecordRequest(Psk.generate().pskId),
            request(ManagementGetPairingConfigMessage.typeString),
            #"{"type":"management/set-pairing-config","payload":{"unpaired_access":{"enabled":false}}}"#
        ]
        for (index, body) in requests.enumerated() {
            try await fixture.server.sendJSON(body)
            let reply = try await waitForManagementResult(from: fixture.server, after: index)
            #expect(try rawPayload(reply)["storage"] == nil)
        }
        await fixture.connection.shutdown()
    }

    @Test("bounded storage reports free on ordinary outcomes and details only on list and config")
    func storageAccountingShape() async throws {
        let pairing = Psk.generate()
        let existing = Psk.generate()
        let store = TranscriptPairingStore(
            records: [PairingRecord(psk: existing)],
            accounting: PairingStorageAccounting(free: 17, capacity: 100, costIndividual: 11, costShared: 7)
        )
        let fixture = try await managementFixture(
            store: store,
            runtime: PairingConfigurationRuntime(configuration: configuration(pairingPsk: pairing))
        )
        try await fixture.server.sendJSON(addRecordRequest(Psk.generate()))
        try await assertStorage(waitForManagementResult(from: fixture.server), detailed: false)
        try await fixture.server.sendJSON(addRecordRequest(existing))
        try await assertStorage(waitForManagementResult(from: fixture.server, after: 1), detailed: false)
        try await fixture.server.sendJSON(addRecordRequest(Psk.generate().base64URL))
        try await assertStorage(waitForManagementResult(from: fixture.server, after: 2), detailed: false)
        try await fixture.server.sendJSON(removeRecordRequest(Psk.generate().pskId))
        try await assertStorage(waitForManagementResult(from: fixture.server, after: 3), detailed: false)
        try await fixture.server.sendJSON(request(ManagementListRecordsMessage.typeString))
        try await assertStorage(waitForManagementResult(from: fixture.server, after: 4), detailed: true)
        try await fixture.server.sendJSON(request(ManagementGetPairingConfigMessage.typeString))
        try await assertStorage(waitForManagementResult(from: fixture.server, after: 5), detailed: true)
        await fixture.connection.shutdown()
    }

    @Test("set-pairing-config outside management activity is denied without storage accounting")
    func setPairingConfigOutsideActivityDenied() async throws {
        let store = TranscriptPairingStore(accounting: PairingStorageAccounting(free: 17, capacity: 100, costIndividual: 11, costShared: 7))
        let fixture = try await makeEstablishedConnection(activities: [], psk: Psk.generate(), pskCategory: .longTerm, pairingStore: store)
        try await fixture.server.sendJSON(#"{"type":"management/set-pairing-config","payload":{"unpaired_access":{"enabled":false}}}"#)
        let reply = try await waitForManagementResult(from: fixture.server)
        #expect(resultCode(reply) == .permissionDenied)
        #expect(try rawPayload(reply)["storage"] == nil)
        await fixture.connection.shutdown()
    }

    private func configuration(
        pairingPsk: Psk,
        recordModePskId: String = "unused-record-mode",
        pairingEnabled: Bool = true,
        unpaired: Bool = true
    ) -> PairingManagementConfiguration {
        PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: pairingEnabled,
            recordModePskId: recordModePskId,
            unpairedAccessEnabled: unpaired
        )
    }

    private func managementFixture(
        psk: Psk = Psk.generate(),
        store: any PairingRecordStore = InMemoryPairingRecordStore(),
        runtime: PairingConfigurationRuntime? = nil
    ) async throws -> EstablishedConnectionFixture {
        let resolvedRuntime = runtime ?? PairingConfigurationRuntime(configuration: configuration(pairingPsk: Psk.generate()))
        return try await makeEstablishedConnection(
            activities: [.management],
            activeRoles: [],
            psk: psk,
            pskCategory: .longTerm,
            pairingStore: store,
            pairingConfigurationRuntime: resolvedRuntime
        )
    }

    private func request(_ type: String) -> String {
        "{\"type\":\"\(type)\",\"payload\":{}}"
    }

    private func addRecordRequest(_ psk: Psk, serverId: String? = nil) -> String {
        addRecordRequest(psk.base64URL, serverId: serverId)
    }

    private func addRecordRequest(_ psk: String, serverId: String? = nil) -> String {
        let server = serverId.map { ",\"server_id\":\"\($0)\"" } ?? ""
        return "{\"type\":\"management/add-record\",\"payload\":{\"psk\":\"\(psk)\"\(server)}}"
    }

    private func removeRecordRequest(_ pskId: String) -> String {
        "{\"type\":\"management/remove-record\",\"payload\":{\"psk_id\":\"\(pskId)\"}}"
    }

    private func setPairingPskRequest(_ psk: Psk) -> String {
        "{\"type\":\"management/set-pairing-config\",\"payload\":{\"pairing_psk\":{\"psk\":\"\(psk.base64URL)\"}}}"
    }

    private func setRecordModeRequest(_ pskId: String) -> String {
        "{\"type\":\"management/set-pairing-config\",\"payload\":{\"record_mode\":{\"psk_id\":\"\(pskId)\"}}}"
    }

    private func resultCode(_ data: Data) -> ManagementResultCode {
        (try? JSONDecoder().decode(ManagementResultMessage.self, from: data).payload.result) ?? .invalid
    }

    private func rawPayload(_ data: Data) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(envelope["payload"] as? [String: Any])
    }

    private func records(in data: Data) throws -> [[String: Any]] {
        let payload = try rawPayload(data)
        let dataObject = try #require(payload["data"] as? [String: Any])
        return try #require(dataObject["records"] as? [[String: Any]])
    }

    private func assertStorage(_ data: Data, detailed: Bool) throws {
        let payload = try rawPayload(data)
        let storage = try #require(payload["storage"] as? [String: Any])
        #expect(storage["free"] as? Int == 17)
        #expect((storage["capacity"] is Int) == detailed)
        #expect((storage["cost_individual"] is Int) == detailed)
        #expect((storage["cost_shared"] is Int) == detailed)
    }

    private func waitForManagementResult(from server: MockNoiseServer, after count: Int = 0) async throws -> Data {
        try #require(await waitUntil(timeout: .seconds(2)) {
            await server.clientJSONMessages(ofType: ManagementResultMessage.typeString).count > count
        })
        let messages = await server.clientJSONMessages(ofType: ManagementResultMessage.typeString)
        try #require(messages.count > count)
        return messages[count]
    }
}

private actor TranscriptPairingStore: PairingRecordStore {
    private var records: [PairingRecord]
    private var configuration: PairingManagementConfiguration?
    private let insertError: PairingRecordStoreError?
    private let saveError: PairingRecordStoreError?
    private let accounting: PairingStorageAccounting?

    init(
        records: [PairingRecord] = [],
        insertError: PairingRecordStoreError? = nil,
        saveError: PairingRecordStoreError? = nil,
        accounting: PairingStorageAccounting? = nil
    ) {
        self.records = records
        self.insertError = insertError
        self.saveError = saveError
        self.accounting = accounting
    }

    func listRecords() async -> [PairingRecord] {
        records
    }

    func insert(_ record: PairingRecord) async throws {
        if let insertError {
            throw insertError
        }
        guard !records.contains(where: { $0.pskId == record.pskId }) else { throw PairingRecordStoreError.duplicatePskId }
        records.append(record)
    }

    func remove(pskId: String) async {
        records.removeAll { $0.pskId == pskId }
    }

    func markUsed(pskId: String) async {
        guard let index = records.firstIndex(where: { $0.pskId == pskId }) else { return }
        records[index].used = true
    }

    func storageAccounting() async -> PairingStorageAccounting? {
        accounting
    }

    func loadManagementConfiguration(default configuration: PairingManagementConfiguration) async -> PairingManagementConfiguration {
        self.configuration ?? configuration
    }

    func saveManagementConfiguration(_ configuration: PairingManagementConfiguration) async throws {
        if let saveError {
            throw saveError
        }
        self.configuration = configuration
    }
}
