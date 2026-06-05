//
//  BookingHistoryStore.swift
//  My GitLab Timetracking
//

import Foundation

enum GitLabTimeNoteParser {
    private static let hoursPerDay = 8
    private static let daysPerWeek = 5

    static func addedMinutes(from body: String) -> Int? {
        let prefix = "added "
        let suffix = " of time spent"

        guard body.hasPrefix(prefix), let suffixRange = body.range(of: suffix) else {
            return nil
        }

        let start = body.index(body.startIndex, offsetBy: prefix.count)
        guard start <= suffixRange.lowerBound else { return nil }
        let durationText = body[start..<suffixRange.lowerBound]

        return minutes(fromDuration: String(durationText))
    }

    static func minutes(fromDuration text: String) -> Int? {
        var total = 0
        var buffer = ""
        var anyUnitFound = false

        for char in text {
            if char.isWhitespace {
                continue
            }

            if char.isNumber {
                buffer.append(char)
                continue
            }

            guard let value = Int(buffer) else {
                buffer = ""
                continue
            }

            switch char {
            case "w", "W":
                total += value * daysPerWeek * hoursPerDay * 60
                anyUnitFound = true
            case "d", "D":
                total += value * hoursPerDay * 60
                anyUnitFound = true
            case "h", "H":
                total += value * 60
                anyUnitFound = true
            case "m", "M":
                total += value
                anyUnitFound = true
            case "s", "S":
                anyUnitFound = true
            default:
                break
            }

            buffer = ""
        }

        return anyUnitFound ? total : nil
    }
}

enum BookingStatus: String, Codable, Hashable {
    case booked
    case uploading
    case pending
}

struct BookingHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let issueID: Int
    let issueReference: String
    let issueTitle: String
    let issueWebURL: URL
    let minutes: Int
    var bookedAt: Date
    var gitLabEventID: Int?
    var status: BookingStatus
    var lastError: String?
    var projectID: Int?
    var issueIID: Int?

    init(
        id: UUID = UUID(),
        issueID: Int,
        issueReference: String,
        issueTitle: String,
        issueWebURL: URL,
        minutes: Int,
        bookedAt: Date,
        gitLabEventID: Int? = nil,
        status: BookingStatus = .booked,
        lastError: String? = nil,
        projectID: Int? = nil,
        issueIID: Int? = nil
    ) {
        self.id = id
        self.issueID = issueID
        self.issueReference = issueReference
        self.issueTitle = issueTitle
        self.issueWebURL = issueWebURL
        self.minutes = minutes
        self.bookedAt = bookedAt
        self.gitLabEventID = gitLabEventID
        self.status = status
        self.lastError = lastError
        self.projectID = projectID
        self.issueIID = issueIID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.issueID = try container.decode(Int.self, forKey: .issueID)
        self.issueReference = try container.decode(String.self, forKey: .issueReference)
        self.issueTitle = try container.decode(String.self, forKey: .issueTitle)
        self.issueWebURL = try container.decode(URL.self, forKey: .issueWebURL)
        self.minutes = try container.decode(Int.self, forKey: .minutes)
        self.bookedAt = try container.decode(Date.self, forKey: .bookedAt)
        self.gitLabEventID = try container.decodeIfPresent(Int.self, forKey: .gitLabEventID)
        self.status = try container.decodeIfPresent(BookingStatus.self, forKey: .status) ?? .booked
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.projectID = try container.decodeIfPresent(Int.self, forKey: .projectID)
        self.issueIID = try container.decodeIfPresent(Int.self, forKey: .issueIID)
    }
}

struct BookingHistoryStore {
    private let defaults: UserDefaults
    private let key = "tracking.bookingHistory"
    private let maxEntries = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [BookingHistoryEntry] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        var entries = (try? JSONDecoder().decode([BookingHistoryEntry].self, from: data)) ?? []
        var didRecover = false
        for index in entries.indices where entries[index].status == .uploading {
            entries[index].status = .pending
            if entries[index].lastError == nil {
                entries[index].lastError = "Booking interrupted — retry to upload."
            }
            didRecover = true
        }
        if didRecover {
            save(entries)
        }
        return entries
    }

    func save(_ entries: [BookingHistoryEntry]) {
        let trimmed = Array(entries.suffix(maxEntries))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    func append(_ entry: BookingHistoryEntry) -> [BookingHistoryEntry] {
        var entries = load()
        entries.append(entry)
        save(entries)
        return entries
    }

    func appendAll(_ newEntries: [BookingHistoryEntry]) -> [BookingHistoryEntry] {
        var entries = load()
        let existingIDs = Set(entries.map(\.id))
        entries.append(contentsOf: newEntries.filter { !existingIDs.contains($0.id) })
        save(entries)
        return entries
    }

    func update(_ entry: BookingHistoryEntry) -> [BookingHistoryEntry] {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        save(entries)
        return entries
    }

    func remove(id: UUID) -> [BookingHistoryEntry] {
        var entries = load()
        entries.removeAll { $0.id == id }
        save(entries)
        return entries
    }

    func mergeRemote(_ remoteEntries: [BookingHistoryEntry]) -> [BookingHistoryEntry] {
        var entries = load()
        let knownEventIDs = Set(entries.compactMap(\.gitLabEventID))

        for remote in remoteEntries where remote.gitLabEventID != nil {
            guard let eventID = remote.gitLabEventID, !knownEventIDs.contains(eventID) else {
                continue
            }

            if let localIndex = entries.firstIndex(where: { local in
                local.gitLabEventID == nil
                    && local.issueID == remote.issueID
                    && local.minutes == remote.minutes
                    && abs(local.bookedAt.timeIntervalSince(remote.bookedAt)) < 180
            }) {
                entries[localIndex].gitLabEventID = eventID
                entries[localIndex].status = .booked
                entries[localIndex].lastError = nil
            } else {
                entries.append(remote)
            }
        }

        entries.sort { $0.bookedAt < $1.bookedAt }
        save(entries)
        return entries
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
