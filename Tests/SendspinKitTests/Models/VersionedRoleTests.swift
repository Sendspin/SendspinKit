// ABOUTME: Tests for VersionedRole parsing, encoding, and wire format
// ABOUTME: Validates role@version format handling for protocol negotiation

import Foundation
@testable import SendspinKit
import Testing

struct VersionedRoleTests {
    // MARK: - String literal initialization

    @Test
    func `String literal with version parses correctly`() {
        let role: VersionedRole = "player@v1"
        #expect(role.role == "player")
        #expect(role.version == "v1")
        #expect(role.identifier == "player@v1")
    }

    @Test
    func `String literal without version defaults to v1`() {
        let role: VersionedRole = "player"
        #expect(role.role == "player")
        #expect(role.version == "v1")
        #expect(role.identifier == "player@v1")
    }

    @Test
    func `String literal with v2 version`() {
        let role: VersionedRole = "player@v2"
        #expect(role.role == "player")
        #expect(role.version == "v2")
    }

    @Test
    func `String literal with custom role`() {
        let role: VersionedRole = "_myapp_display@v1"
        #expect(role.role == "_myapp_display")
        #expect(role.version == "v1")
    }

    @Test
    func `String literal with @ in version is accepted`() {
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
    func `Memberwise init sets role and version`() {
        let role = VersionedRole(role: "artwork", version: "v1")
        #expect(role.role == "artwork")
        #expect(role.version == "v1")
        #expect(role.identifier == "artwork@v1")
    }

    // Note: precondition failures (empty role, empty version, @ in role name)
    // cannot be tested in Swift Testing — they abort the process.

    // MARK: - JSON encoding

    @Test
    func `Encodes as single string`() throws {
        let role: VersionedRole = "player@v1"
        let data = try JSONEncoder().encode(role)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "\"player@v1\"")
    }

    @Test
    func `Round-trips through JSON`() throws {
        let original: VersionedRole = "controller@v1"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VersionedRole.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func `Encodes in array matching spec format`() throws {
        let roles: [VersionedRole] = [.playerV1, .controllerV1, .metadataV1]
        let data = try JSONEncoder().encode(roles)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"player@v1\""))
        #expect(json.contains("\"controller@v1\""))
        #expect(json.contains("\"metadata@v1\""))
    }

    // MARK: - JSON decoding (strict)

    @Test
    func `Decodes valid role@version from JSON`() throws {
        let json = Data("\"artwork@v1\"".utf8)
        let role = try JSONDecoder().decode(VersionedRole.self, from: json)
        #expect(role.role == "artwork")
        #expect(role.version == "v1")
    }

    @Test
    func `Decodes role with @ in version from JSON`() throws {
        // "player@v1@extra" → role: "player", version: "v1@extra"
        // firstIndex(of: "@") splits on the first @ only.
        let json = Data("\"player@v1@extra\"".utf8)
        let role = try JSONDecoder().decode(VersionedRole.self, from: json)
        #expect(role.role == "player")
        #expect(role.version == "v1@extra")
    }

    @Test
    func `Rejects versionless role in JSON`() {
        let json = Data("\"player\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func `Rejects empty role before @ in JSON`() {
        let json = Data("\"@v1\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func `Rejects empty version after @ in JSON`() {
        let json = Data("\"player@\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func `Rejects bare @ in JSON`() {
        let json = Data("\"@\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func `Rejects empty string in JSON`() {
        let json = Data("\"\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionedRole.self, from: json)
        }
    }

    @Test
    func `Decodes array of roles from JSON`() throws {
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
        (VersionedRole.visualizerV1, "visualizer", "v1"),
    ])
    func `Spec role constant`(role: VersionedRole, expectedName: String, expectedVersion: String) {
        #expect(role.role == expectedName)
        #expect(role.version == expectedVersion)
        #expect(role.identifier == "\(expectedName)@\(expectedVersion)")
    }

    // MARK: - Hashable / Equatable

    @Test
    func `Equal roles from different init paths including decode`() throws {
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
    func `Different versions are not equal`() {
        let v1: VersionedRole = "player@v1"
        let v2: VersionedRole = "player@v2"
        #expect(v1 != v2)
    }

    @Test
    func `Different roles are not equal`() {
        let player: VersionedRole = "player@v1"
        let controller: VersionedRole = "controller@v1"
        #expect(player != controller)
    }
}
