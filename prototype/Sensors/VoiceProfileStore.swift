import Foundation
import SQLite3
import CryptoKit

public struct SpeakerReference: Identifiable, Sendable {
    public let id: UUID
    public let personID: String
    public let label: String
    public let templates: [[Float]]

    public var embedding: [Float] { templates.first ?? [] }
    public var templateCount: Int { templates.count }

    public init(id: UUID = UUID(), personID: String, label: String, templates: [[Float]]) {
        self.id = id
        self.personID = personID
        self.label = label
        self.templates = templates
    }
}

public enum SpeakerReferenceStore {
    private static let modelKey = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    private static let alexSampleFiveReferenceID = "00000000-0000-4000-8000-000000000005"
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct LegacySpeakerReference: Decodable {
        let id: UUID
        let label: String
        let embedding: [Float]
    }

    public static func load(from appSupportDirectory: URL) -> [SpeakerReference] {
        do {
            let databaseURL = appSupportDirectory.appending(path: "Users/people.sqlite")
            try ensureCompatibilityDatabase(databaseURL)
            try importLegacyReferences(from: appSupportDirectory, databaseURL: databaseURL)
            return try loadProfiles(databaseURL: databaseURL)
        } catch {
            NSLog("Vera speaker profile database error: %@", error.localizedDescription)
            return []
        }
    }

    public static func appendTemplate(_ embedding: [Float], label: String,
                                      appSupportDirectory: URL) throws -> [SpeakerReference] {
        guard isValidEmbedding(embedding) else { throw ProfileStoreError.invalidEmbedding }
        let databaseURL = appSupportDirectory.appending(path: "Users/people.sqlite")
        try ensureCompatibilityDatabase(databaseURL)
        try withDatabase(databaseURL, write: true) { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let personID = try findOrCreatePerson(db, label: label)
                let nextIndex = try nextTemplateIndex(db, personID: personID)
                let referenceID = "ui-enrollment:\(UUID().uuidString.lowercased())"
                try insertTemplate(db, personID: personID, index: nextIndex, embedding: embedding,
                                   source: "Vera 2 manual profile enrollment · \(referenceID)")
                try updateTemplateCount(db, personID: personID)
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
        protectDatabaseFiles(databaseURL)
        return try loadProfiles(databaseURL: databaseURL)
    }

    public static func disableProfile(personID: String, appSupportDirectory: URL) throws -> [SpeakerReference] {
        let databaseURL = appSupportDirectory.appending(path: "Users/people.sqlite")
        try ensureCompatibilityDatabase(databaseURL)
        try withDatabase(databaseURL, write: true) { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let statement = try prepare(db, "DELETE FROM speaker_templates WHERE person_id=?")
                bindText(statement, 1, personID)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    let message = String(cString: sqlite3_errmsg(db))
                    sqlite3_finalize(statement)
                    throw ProfileStoreError.sqlite(message)
                }
                sqlite3_finalize(statement)
                let update = try prepare(db, "UPDATE people SET profile_status='disabled_by_user', template_count=0 WHERE person_id=?")
                bindText(update, 1, personID)
                guard sqlite3_step(update) == SQLITE_DONE else {
                    let message = String(cString: sqlite3_errmsg(db))
                    sqlite3_finalize(update)
                    throw ProfileStoreError.sqlite(message)
                }
                sqlite3_finalize(update)
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
        protectDatabaseFiles(databaseURL)
        return try loadProfiles(databaseURL: databaseURL)
    }

    public static func bestCosine(_ query: [Float], against reference: SpeakerReference) -> (similarity: Double, templateIndex: Int)? {
        reference.templates.enumerated().compactMap { index, candidate in
            cosine(query, candidate).map { ($0, index) }
        }.max { $0.similarity < $1.similarity }
    }

    public static func cosine(_ left: [Float], _ right: [Float]) -> Double? {
        guard left.count == right.count, !left.isEmpty,
              left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else { return nil }
        let dot = zip(left, right).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        let leftNorm = sqrt(left.reduce(Float.zero) { $0 + $1 * $1 })
        let rightNorm = sqrt(right.reduce(Float.zero) { $0 + $1 * $1 })
        guard leftNorm > 0, rightNorm > 0 else { return nil }
        return Double(dot / (leftNorm * rightNorm))
    }

    private static func loadProfiles(databaseURL: URL) throws -> [SpeakerReference] {
        try withDatabase(databaseURL, write: false) { db in
            let statement = try prepare(db, """
                SELECT p.person_id, p.display_name, t.vector
                FROM people p JOIN speaker_templates t ON t.person_id=p.person_id
                WHERE p.profile_status!='disabled_by_user'
                ORDER BY p.person_id, t.template_index
                """)
            defer { sqlite3_finalize(statement) }
            var grouped: [(personID: String, label: String, vectors: [[Float]])] = []
            var positions: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let personID = columnText(statement, 0), let label = columnText(statement, 1),
                      let blob = columnBlob(statement, 2), blob.count == 192 * MemoryLayout<Float>.size else { continue }
                let values = blob.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
                guard values.count == 192, isValidEmbedding(values) else { continue }
                if let index = positions[personID] {
                    grouped[index].vectors.append(values)
                } else {
                    positions[personID] = grouped.count
                    grouped.append((personID, label, [values]))
                }
            }
            return grouped.map { SpeakerReference(id: stableID(for: $0.personID), personID: $0.personID,
                                                  label: $0.label, templates: $0.vectors) }
        }
    }

    private static func importLegacyReferences(from appSupportDirectory: URL, databaseURL: URL) throws {
        let legacyURL = appSupportDirectory.appending(path: "speaker-references.json")
        guard FileManager.default.isReadableFile(atPath: legacyURL.path) else { return }
        let data = try Data(contentsOf: legacyURL)
        let legacyReferences = try JSONDecoder().decode([LegacySpeakerReference].self, from: data)
        guard !legacyReferences.isEmpty else { return }

        try withDatabase(databaseURL, write: true) { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                for reference in legacyReferences {
                    guard isValidEmbedding(reference.embedding) else { throw ProfileStoreError.invalidEmbedding }
                    let sourceReferenceID = "speaker-references.json:\(reference.id.uuidString.lowercased())"
                    let sourceVector = floatData(reference.embedding)
                    let importKey = "legacy_reference:\(reference.id.uuidString.lowercased())"
                    if let existingValue = try metadataValue(db, key: importKey) {
                        guard existingValue.contains("vector_sha256=\(SHA256.hex(sourceVector))") else {
                            throw ProfileStoreError.sourceReferenceConflict(sourceReferenceID)
                        }
                        continue
                    }

                    let personID = try legacyPersonID(db, reference: reference)
                    if let duplicateIndex = try obviousDuplicateTemplate(db, personID: personID, embedding: reference.embedding) {
                        try setMetadata(db, key: importKey,
                                        value: "person_id=\(personID); deduplicated_to_template_index=\(duplicateIndex); source_reference=\(sourceReferenceID); vector_sha256=\(SHA256.hex(sourceVector)); file_sha256=\(SHA256.hex(data)); mapping=profile_level_only")
                        continue
                    }
                    let index = try nextTemplateIndex(db, personID: personID)
                    try insertTemplate(db, personID: personID, index: index, embedding: reference.embedding,
                                       source: sourceReferenceID)
                    try updateTemplateCount(db, personID: personID)
                    let provenance = "person_id=\(personID); source_reference=\(sourceReferenceID); source=speaker-references.json; vector_sha256=\(SHA256.hex(sourceVector)); file_sha256=\(SHA256.hex(data)); mapping=profile_level_only"
                    try setMetadata(db, key: importKey, value: provenance)
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
        protectDatabaseFiles(databaseURL)
    }

    private static func legacyPersonID(_ db: OpaquePointer, reference: LegacySpeakerReference) throws -> String {
        if reference.id.uuidString.lowercased() == alexSampleFiveReferenceID { return "alex" }
        if let exact = try findPersonID(db, label: reference.label) { return exact }
        let personID = "legacy-\(reference.id.uuidString.lowercased())"
        try insertPerson(db, personID: personID, label: reference.label,
                         sourceProfilePath: "speaker-references.json")
        return personID
    }

    private static func findPersonID(_ db: OpaquePointer, label: String) throws -> String? {
        let statement = try prepare(db, "SELECT person_id FROM people WHERE display_name=? COLLATE NOCASE LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, label)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private static func findOrCreatePerson(_ db: OpaquePointer, label: String) throws -> String {
        if let personID = try findPersonID(db, label: label) { return personID }
        let personID = "user-\(UUID().uuidString.lowercased())"
        try insertPerson(db, personID: personID, label: label, sourceProfilePath: "manual UI enrollment")
        return personID
    }

    private static func insertPerson(_ db: OpaquePointer, personID: String, label: String,
                                     sourceProfilePath: String) throws {
        let statement = try prepare(db, """
            INSERT INTO people (person_id,display_name,participant_type,is_synthetic,is_owner,profile_status,
                                source_profile_path,source_template_path,model_key,embedding_dim,template_count)
            VALUES (?,?, 'human',0,0,'user_added',?, 'manual enrollment', ?,192,0)
            """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, personID); bindText(statement, 2, label); bindText(statement, 3, sourceProfilePath)
        bindText(statement, 4, modelKey)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private static func insertTemplate(_ db: OpaquePointer, personID: String, index: Int,
                                       embedding: [Float], source: String) throws {
        let statement = try prepare(db, """
            INSERT INTO speaker_templates
              (person_id,model_key,template_index,vector_dtype,embedding_dim,vector,source_database,
               source_profile_path,mapping_status)
            VALUES (?,?,?,'float32_le',192,?,?,?,'profile_level_only')
            """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, personID); bindText(statement, 2, modelKey); sqlite3_bind_int(statement, 3, Int32(index))
        bindBlob(statement, 4, floatData(embedding)); bindText(statement, 5, source); bindText(statement, 6, source)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private static func nextTemplateIndex(_ db: OpaquePointer, personID: String) throws -> Int {
        let statement = try prepare(db, "SELECT COALESCE(MAX(template_index),-1)+1 FROM speaker_templates WHERE person_id=? AND model_key=?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, personID); bindText(statement, 2, modelKey)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ProfileStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func updateTemplateCount(_ db: OpaquePointer, personID: String) throws {
        let statement = try prepare(db, "UPDATE people SET template_count=(SELECT count(*) FROM speaker_templates WHERE person_id=?), profile_status='confirmed_curated_profile' WHERE person_id=?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, personID); bindText(statement, 2, personID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private static func obviousDuplicateTemplate(_ db: OpaquePointer, personID: String,
                                                embedding: [Float]) throws -> Int? {
        let statement = try prepare(db, "SELECT template_index,vector FROM speaker_templates WHERE person_id=? AND model_key=?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, personID); bindText(statement, 2, modelKey)
        while sqlite3_step(statement) == SQLITE_ROW {
            let index = Int(sqlite3_column_int(statement, 0))
            guard let blob = columnBlob(statement, 1), blob.count == 192 * MemoryLayout<Float>.size else { continue }
            let candidate = blob.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
            if let similarity = cosine(embedding, candidate), similarity >= 0.9999 { return index }
        }
        return nil
    }

    private static func metadataValue(_ db: OpaquePointer, key: String) throws -> String? {
        let statement = try prepare(db, "SELECT metadata_value FROM import_metadata WHERE metadata_key=?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private static func setMetadata(_ db: OpaquePointer, key: String, value: String) throws {
        let statement = try prepare(db, "INSERT INTO import_metadata(metadata_key,metadata_value) VALUES (?,?) ON CONFLICT(metadata_key) DO NOTHING")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key); bindText(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private static func ensureCompatibilityDatabase(_ url: URL) throws {
        try withDatabase(url, write: true) { db in
            try execute(db, "CREATE TABLE IF NOT EXISTS import_metadata (metadata_key TEXT PRIMARY KEY, metadata_value TEXT NOT NULL)")
        }
        protectDatabaseFiles(url)
    }

    private static func withDatabase<T>(_ url: URL, write: Bool, body: (OpaquePointer) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProfileStoreError.databaseMissing(url.path) }
        var db: OpaquePointer?
        let flags = write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            if let db { sqlite3_close(db) }
            throw ProfileStoreError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        try execute(db, "PRAGMA foreign_keys=ON")
        return try body(db)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProfileStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw ProfileStoreError.sqlite(message)
        }
    }

    private static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        value.withCString { _ = sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
    }

    private static func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), sqliteTransient) }
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func floatData(_ values: [Float]) -> Data {
        var floats = values
        return floats.withUnsafeMutableBytes { Data($0) }
    }

    private static func isValidEmbedding(_ values: [Float]) -> Bool {
        values.count == 192 && values.allSatisfy(\.isFinite) && values.contains { abs($0) > 0 }
    }

    private static func protectDatabaseFiles(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            }
        }
    }

    private static func stableID(for personID: String) -> UUID {
        if let value = UUID(uuidString: personID) { return value }
        var hash = Array(SHA256.hash(data: Data(personID.utf8)).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
    }
}

private enum SHA256 {
    static func hash(data: Data) -> [UInt8] { Array(CryptoKit.SHA256.hash(data: data)) }
    static func hex(_ data: Data) -> String { hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private enum ProfileStoreError: Error, LocalizedError {
    case sqlite(String)
    case databaseMissing(String)
    case invalidEmbedding
    case sourceReferenceConflict(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "SQLite: \(message)"
        case .databaseMissing(let path): return "People database is missing: \(path)"
        case .invalidEmbedding: return "CAM++ embedding must contain 192 finite float32 values"
        case .sourceReferenceConflict(let key): return "Legacy source reference already exists with different data: \(key)"
        }
    }
}
