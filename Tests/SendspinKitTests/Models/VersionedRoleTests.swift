// ABOUTME: Tests for VersionedRole parsing, encoding, and wire format
// ABOUTME: Validates role@version format handling for protocol negotiation

import Foundation
@testable import SendspinKit
import Testing

struct VersionedRoleTests {
    // MARK: - String literal initialization

    @Test
    func stringLiteralWithVersionParsesCorrectly() {
        let role: VersionedRole = "player@v1"
        #expect(role.role == "player")
        #expect(role.version == "v1")
        #expect(role.identifier == "player@v1")
    }

    @Test
    func stringLiteralWithoutVersionDefaultsToV1() {
        let role: VersionedRole = "player"
        #expect(role.role == "player")
        #expect(role.version == "v1")
        #expect(role.identifier == "player@v1")
    }

    @Test
    func stringLiteralWithV2Version() {
        let role: VersionedRole = "player@v2"
        #expect(role.role == "player")
        #expect(role.version == "v2")
    }

    @Test
    func stringLiteralWithCustomRole() {
        let role: VersionedRole = "_myapp_display@v1"
        #expect(role.role == "_myapp_display")
        #expect(role.version == "v1")
    }

    @Test
    func stringLiteralWithAtInVersionIsAccepted() {
        // parse() uses firstIndex(of: "@"), so only the first @ splits.
        // "player@v1@extra" → role: "player", version: "v1@extra"
        let role: VersionedRole = "player@v1@extra"
        #expect(role.role == "player")
        #expect(role.version == "v1@extra")
    }

    // Note: malformed literals like "player@", "@v1", and "" now trap via
    // precondition, matching the memberwise init's strictness. These cannot
    // be tested in Swift Testing. The decode path covers the same edge cases
    // with throwing validation.

    // MARK: - Memberwise init

    @Test
    func memberwiseInitSetsRoleAndVersion() {
        let role = VersionedRole(role: "artwork", version: "v1")
        #expect(role.role == "artwork")
        #expect(role.version == "v1")
        #expect(role.identifier == "artwork@v1")
    }

    // Note: precondition failures (empty role, empty version, @ in role name)
    // cannot be tested in Swift Testing — they abort the process.

    // MARK: - JSON encoding

    @Test
    func encodesAsSingleString() throws {
        let role: VersionedRole = "player@v1"
        let data = try JSONEncoder().encode(role)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "\"player@v1\"")
    }

    @Test
    func roundTripsThroughJSON() throws {
        let original: VersionedRole = "controller@v1"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VersionedRole.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func encodesInArrayMatchingSpecFormat() throws {
        let roles: [VersionedRole] = [.playerV1, .controllerV1, .metadataV1]
        let data = try JSONEncoder().encode(roles)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"player@v1\""))
        #expect(json.contains("\"controller@v1\""))
        #expect(json.contains("\"metadata@v1\""))
    }

    // MARK: - JSON decoding (strict)

    @Test
    func decodesValidRoleAtVersionFromJSON() throws {
        let json = Data("\"artwork@v1\"".utf8)
        let role = try JSONDecoder().decode(VersionedRole.self, from: json)
        #expect(role.role == "artwork")
        #expect(role.version == "v1")
    }

    @Test
    func decodesRoleWithAtInVersionFromJSON() throws {
        // "player@v1@extra" → role: "player", version: "v1@extra"
        // firstIndex(of: "@") splits on the first @ only.
        let json = Data("\"player@v1@extra\"".utf8)
        let role = try JSONDecoder().decode(VersionedRole.self, from: json)
        #expect(role.role == "player")
        #expect(role.version == "v1@extra")
    }

    @Test
    func rejectsVersionlessRoleInJSON() {
        let json = Data("\"player\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func rejectsEmptyRoleBeforeAtInJSON() {
        let json = Data("\"@v1\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func rejectsEmptyVersionAfterAtInJSON() {
        let json = Data("\"player@\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func rejectsBareAtInJSON() {
        let json = Data("\"@\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func rejectsEmptyStringInJSON() {
        let json = Data("\"\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func decodesArrayOfRolesFromJSON() throws {
        let json = Data("[\"player@v1\",\"controller@v1\"]".utf8)
        let roles = try JSONDecoder().decode([VersionedRole].self, from: json)
        #expect(roles == [.playerV1, .controllerV1])
    }

    // MARK: - Constants

    @Test(arguments: [
        (VersionedRole.playerV1, "player", "v1"),
        (VersionedRole.controllerV1, "controller", "v1"),
        (VersionedRole.metadataV1, "metadata", "v1"),
        (VersionedRole.artworkV1, "artwork", "v1"),
        (VersionedRole.visualizerV1, "visualizer", "v1")
    ])
    func specRoleConstant(role: VersionedRole, expectedName: String, expectedVersion: String) {
        #expect(role.role == expectedName)
        #expect(role.version == expectedVersion)
        #expect(role.identifier == "\(expectedName)@\(expectedVersion)")
    }

    // MARK: - Hashable / Equatable

    @Test
    func equalRolesFromDifferentInitPathsIncludingDecode() throws {
        let fromLiteral: VersionedRole = "player@v1"
        let fromMemberwise = VersionedRole(role: "player", version: "v1")
        let fromConstant = VersionedRole.playerV1
        let fromDecode = try JSONDecoder().decode(
            VersionedRole.self, from: Data("\"player@v1\"".utf8)
        )

        #expect(fromLiteral == fromMemberwise)
        #expect(fromMemberwise == fromConstant)
        #expect(fromConstant == fromDecode)

        let set: Set = [fromLiteral, fromMemberwise, fromConstant, fromDecode]
        #expect(set.count == 1)
    }

    @Test
    func differentVersionsAreNotEqual() {
        let v1: VersionedRole = "player@v1"
        let v2: VersionedRole = "player@v2"
        #expect(v1 != v2)
    }

    @Test
    func differentRolesAreNotEqual() {
        let player: VersionedRole = "player@v1"
        let controller: VersionedRole = "controller@v1"
        #expect(player != controller)
    }
}
