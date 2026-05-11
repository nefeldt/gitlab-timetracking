//
//  AppSettings.swift
//  My GitLab Timetracking
//

import Foundation

struct GitLabConfiguration {
    let baseURL: URL
    let clientID: String
    let groupPaths: [String]
}

@Observable
final class AppSettings {
    private enum Keys {
        static let gitLabBaseURL = "gitlab.baseURL"
        static let oauthClientID = "gitlab.oauthClientID"
        static let gitLabGroupPath = "gitlab.groupPath"
        static let gitLabGroupPaths = "gitlab.groupPaths"
        static let showTrackedTimeInMenuBar = "ui.showTrackedTimeInMenuBar"
        static let showIssueReferenceInMenuBar = "ui.showIssueReferenceInMenuBar"
        static let showParentIssueOnCard = "ui.showParentIssueOnCard"
        static let showStatusPillOnCard = "ui.showStatusPillOnCard"
        static let lastSelectedProjectID = "gitlab.lastSelectedProjectID"
        static let recentProjectIDs = "gitlab.recentProjectIDs"
        static let recentIssueIDs = "gitlab.recentIssueIDs"
        static let checkpointMinutes = "tracking.checkpointMinutes"
        static let notificationSound = "tracking.notificationSound"
    }

    private let defaults: UserDefaults
    private let cloudStore: NSUbiquitousKeyValueStore
    private var cloudObserver: (any NSObjectProtocol)?
    private var lastPersistedValues: SettingsValues?

    var gitLabBaseURL: String
    var oauthClientID: String
    var showTrackedTimeInMenuBar: Bool
    var showIssueReferenceInMenuBar: Bool
    var showParentIssueOnCard: Bool
    var showStatusPillOnCard: Bool
    private(set) var gitLabGroupPaths: [String]
    private(set) var lastSelectedProjectID: Int?
    private(set) var recentProjectIDs: [Int]
    private(set) var recentIssueIDs: [Int]
    var checkpointMinutes: Int
    var notificationSound: String

    init(
        defaults: UserDefaults = .standard,
        cloudStore: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore

        let localBaseURL = defaults.string(forKey: Keys.gitLabBaseURL) ?? ""
        let localClientID = defaults.string(forKey: Keys.oauthClientID) ?? ""
        let localGroupPath = defaults.string(forKey: Keys.gitLabGroupPath) ?? ""
        let localGroupPaths = defaults.array(forKey: Keys.gitLabGroupPaths) as? [String] ?? []
        let localShowTrackedTimeInMenuBar = defaults.object(forKey: Keys.showTrackedTimeInMenuBar) as? Bool ?? false
        let localShowIssueReferenceInMenuBar = defaults.object(forKey: Keys.showIssueReferenceInMenuBar) as? Bool ?? true
        let localShowParentIssueOnCard = defaults.object(forKey: Keys.showParentIssueOnCard) as? Bool ?? true
        let localShowStatusPillOnCard = defaults.object(forKey: Keys.showStatusPillOnCard) as? Bool ?? true
        let localLastProjectID = defaults.object(forKey: Keys.lastSelectedProjectID) as? Int
        let localRecentProjectIDs = defaults.array(forKey: Keys.recentProjectIDs) as? [Int] ?? []
        let localRecentIssueIDs = defaults.array(forKey: Keys.recentIssueIDs) as? [Int] ?? []
        let localCheckpointMinutes = defaults.object(forKey: Keys.checkpointMinutes) as? Int
        let localNotificationSound = defaults.string(forKey: Keys.notificationSound) ?? ""
        let remoteBaseURL = cloudStore.string(forKey: Keys.gitLabBaseURL) ?? ""
        let remoteClientID = cloudStore.string(forKey: Keys.oauthClientID) ?? ""
        let remoteGroupPath = cloudStore.string(forKey: Keys.gitLabGroupPath) ?? ""
        let remoteGroupPaths = cloudStore.array(forKey: Keys.gitLabGroupPaths) as? [String] ?? []
        let remoteShowTrackedTimeInMenuBar = cloudStore.object(forKey: Keys.showTrackedTimeInMenuBar) as? Bool
        let remoteShowIssueReferenceInMenuBar = cloudStore.object(forKey: Keys.showIssueReferenceInMenuBar) as? Bool
        let remoteShowParentIssueOnCard = cloudStore.object(forKey: Keys.showParentIssueOnCard) as? Bool
        let remoteShowStatusPillOnCard = cloudStore.object(forKey: Keys.showStatusPillOnCard) as? Bool
        let remoteLastProjectID = cloudStore.object(forKey: Keys.lastSelectedProjectID) as? Int
        let remoteRecentProjectIDs = cloudStore.array(forKey: Keys.recentProjectIDs) as? [Int] ?? []
        let remoteRecentIssueIDs = cloudStore.array(forKey: Keys.recentIssueIDs) as? [Int] ?? []
        let remoteCheckpointMinutes = cloudStore.object(forKey: Keys.checkpointMinutes) as? Int
        let remoteNotificationSound = cloudStore.string(forKey: Keys.notificationSound) ?? ""

        gitLabBaseURL = remoteBaseURL.isEmpty ? localBaseURL : remoteBaseURL
        oauthClientID = remoteClientID.isEmpty ? localClientID : remoteClientID
        showTrackedTimeInMenuBar = remoteShowTrackedTimeInMenuBar ?? localShowTrackedTimeInMenuBar
        showIssueReferenceInMenuBar = remoteShowIssueReferenceInMenuBar ?? localShowIssueReferenceInMenuBar
        showParentIssueOnCard = remoteShowParentIssueOnCard ?? localShowParentIssueOnCard
        showStatusPillOnCard = remoteShowStatusPillOnCard ?? localShowStatusPillOnCard
        gitLabGroupPaths = Self.resolveGroupPaths(
            primary: remoteGroupPaths,
            fallbackArray: localGroupPaths,
            fallbackSingle: remoteGroupPath.isEmpty ? localGroupPath : remoteGroupPath
        )
        lastSelectedProjectID = remoteLastProjectID ?? localLastProjectID
        recentProjectIDs = remoteRecentProjectIDs.isEmpty ? localRecentProjectIDs : remoteRecentProjectIDs
        recentIssueIDs = remoteRecentIssueIDs.isEmpty ? localRecentIssueIDs : remoteRecentIssueIDs
        checkpointMinutes = remoteCheckpointMinutes ?? localCheckpointMinutes ?? 20
        notificationSound = remoteNotificationSound.isEmpty ? (localNotificationSound.isEmpty ? "Sosumi" : localNotificationSound) : remoteNotificationSound

        if !gitLabBaseURL.isEmpty || !oauthClientID.isEmpty || showTrackedTimeInMenuBar || !showIssueReferenceInMenuBar || !showParentIssueOnCard || !showStatusPillOnCard || !gitLabGroupPaths.isEmpty || lastSelectedProjectID != nil || !recentProjectIDs.isEmpty || !recentIssueIDs.isEmpty || checkpointMinutes != 20 || notificationSound != "Sosumi" {
            save()
        }

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudStoreChange(notification)
        }

        cloudStore.synchronize()
    }

    deinit {
        if let cloudObserver {
            NotificationCenter.default.removeObserver(cloudObserver)
        }
    }

    var isConfigured: Bool {
        !normalizedBaseURLString.isEmpty && !oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedBaseURLString: String {
        gitLabBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedBaseURL: URL? {
        URL(string: normalizedBaseURLString)
    }

    var normalizedGroupPaths: [String] {
        gitLabGroupPaths
            .map { groupPath in
                groupPath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            .filter { !$0.isEmpty }
    }

    var configuration: GitLabConfiguration? {
        guard
            isConfigured,
            let baseURL = normalizedBaseURL
        else {
            return nil
        }

        return GitLabConfiguration(
            baseURL: baseURL,
            clientID: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            groupPaths: normalizedGroupPaths
        )
    }

    func save() {
        let values = currentSettingsValues()
        guard values != lastPersistedValues else { return }
        lastPersistedValues = values
        writeToDefaults(values)
        writeToCloudStore(values)
        cloudStore.synchronize()
    }

    func addSelectedGroup(path: String) {
        let normalizedPath = Self.normalizeGroupPath(path)
        guard !normalizedPath.isEmpty, !gitLabGroupPaths.contains(normalizedPath) else {
            return
        }

        gitLabGroupPaths = (gitLabGroupPaths + [normalizedPath]).sorted()
        save()
    }

    func removeSelectedGroup(path: String) {
        let normalizedPath = Self.normalizeGroupPath(path)
        gitLabGroupPaths.removeAll { $0 == normalizedPath }
        save()
    }

    func clearSelectedGroups() {
        gitLabGroupPaths = []
        save()
    }

    func rememberSelectedProject(id: Int) {
        lastSelectedProjectID = id
        recentProjectIDs = [id] + recentProjectIDs.filter { $0 != id }
        recentProjectIDs = Array(recentProjectIDs.prefix(5))
        save()
    }

    func rememberUsedIssue(id: Int) {
        recentIssueIDs = [id] + recentIssueIDs.filter { $0 != id }
        recentIssueIDs = Array(recentIssueIDs.prefix(5))
        save()
    }

    private func handleCloudStoreChange(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        else {
            applyCloudValues()
            return
        }

        if changedKeys.contains(Keys.gitLabBaseURL)
            || changedKeys.contains(Keys.oauthClientID)
            || changedKeys.contains(Keys.showTrackedTimeInMenuBar)
            || changedKeys.contains(Keys.showIssueReferenceInMenuBar)
            || changedKeys.contains(Keys.showParentIssueOnCard)
            || changedKeys.contains(Keys.showStatusPillOnCard)
            || changedKeys.contains(Keys.gitLabGroupPath)
            || changedKeys.contains(Keys.gitLabGroupPaths)
            || changedKeys.contains(Keys.lastSelectedProjectID)
            || changedKeys.contains(Keys.recentProjectIDs)
            || changedKeys.contains(Keys.recentIssueIDs)
            || changedKeys.contains(Keys.checkpointMinutes)
            || changedKeys.contains(Keys.notificationSound) {
            applyCloudValues()
        }
    }

    private func applyCloudValues() {
        let remoteBaseURL = cloudStore.string(forKey: Keys.gitLabBaseURL) ?? ""
        let remoteClientID = cloudStore.string(forKey: Keys.oauthClientID) ?? ""
        let remoteShowTrackedTimeInMenuBar = cloudStore.object(forKey: Keys.showTrackedTimeInMenuBar) as? Bool ?? false
        let remoteShowIssueReferenceInMenuBar = cloudStore.object(forKey: Keys.showIssueReferenceInMenuBar) as? Bool ?? true
        let remoteShowParentIssueOnCard = cloudStore.object(forKey: Keys.showParentIssueOnCard) as? Bool ?? true
        let remoteShowStatusPillOnCard = cloudStore.object(forKey: Keys.showStatusPillOnCard) as? Bool ?? true
        let remoteGroupPath = cloudStore.string(forKey: Keys.gitLabGroupPath) ?? ""
        let remoteGroupPaths = cloudStore.array(forKey: Keys.gitLabGroupPaths) as? [String] ?? []
        let remoteLastProjectID = cloudStore.object(forKey: Keys.lastSelectedProjectID) as? Int
        let remoteRecentProjectIDs = cloudStore.array(forKey: Keys.recentProjectIDs) as? [Int] ?? []
        let remoteRecentIssueIDs = cloudStore.array(forKey: Keys.recentIssueIDs) as? [Int] ?? []
        let remoteCheckpointMinutes = cloudStore.object(forKey: Keys.checkpointMinutes) as? Int ?? 20
        let remoteNotificationSound = cloudStore.string(forKey: Keys.notificationSound) ?? "Sosumi"

        let resolvedRemoteGroupPaths = Self.resolveGroupPaths(
            primary: remoteGroupPaths,
            fallbackArray: [],
            fallbackSingle: remoteGroupPath
        )

        if gitLabBaseURL != remoteBaseURL { gitLabBaseURL = remoteBaseURL }
        if oauthClientID != remoteClientID { oauthClientID = remoteClientID }
        if showTrackedTimeInMenuBar != remoteShowTrackedTimeInMenuBar { showTrackedTimeInMenuBar = remoteShowTrackedTimeInMenuBar }
        if showIssueReferenceInMenuBar != remoteShowIssueReferenceInMenuBar { showIssueReferenceInMenuBar = remoteShowIssueReferenceInMenuBar }
        if showParentIssueOnCard != remoteShowParentIssueOnCard { showParentIssueOnCard = remoteShowParentIssueOnCard }
        if showStatusPillOnCard != remoteShowStatusPillOnCard { showStatusPillOnCard = remoteShowStatusPillOnCard }
        if gitLabGroupPaths != resolvedRemoteGroupPaths { gitLabGroupPaths = resolvedRemoteGroupPaths }
        if lastSelectedProjectID != remoteLastProjectID { lastSelectedProjectID = remoteLastProjectID }
        if recentProjectIDs != remoteRecentProjectIDs { recentProjectIDs = remoteRecentProjectIDs }
        if recentIssueIDs != remoteRecentIssueIDs { recentIssueIDs = remoteRecentIssueIDs }
        if checkpointMinutes != remoteCheckpointMinutes { checkpointMinutes = remoteCheckpointMinutes }
        if notificationSound != remoteNotificationSound { notificationSound = remoteNotificationSound }

        let values = SettingsValues(
            baseURL: remoteBaseURL,
            clientID: remoteClientID,
            showTrackedTimeInMenuBar: remoteShowTrackedTimeInMenuBar,
            showIssueReferenceInMenuBar: remoteShowIssueReferenceInMenuBar,
            showParentIssueOnCard: remoteShowParentIssueOnCard,
            showStatusPillOnCard: remoteShowStatusPillOnCard,
            groupPaths: resolvedRemoteGroupPaths,
            legacyGroupPath: remoteGroupPath,
            lastSelectedProjectID: remoteLastProjectID,
            recentProjectIDs: remoteRecentProjectIDs,
            recentIssueIDs: remoteRecentIssueIDs,
            checkpointMinutes: remoteCheckpointMinutes,
            notificationSound: remoteNotificationSound
        )
        writeToDefaults(values)
        lastPersistedValues = values
    }

    private struct SettingsValues: Equatable {
        let baseURL: String
        let clientID: String
        let showTrackedTimeInMenuBar: Bool
        let showIssueReferenceInMenuBar: Bool
        let showParentIssueOnCard: Bool
        let showStatusPillOnCard: Bool
        let groupPaths: [String]
        let legacyGroupPath: String
        let lastSelectedProjectID: Int?
        let recentProjectIDs: [Int]
        let recentIssueIDs: [Int]
        let checkpointMinutes: Int
        let notificationSound: String
    }

    private func currentSettingsValues() -> SettingsValues {
        SettingsValues(
            baseURL: normalizedBaseURLString,
            clientID: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            showTrackedTimeInMenuBar: showTrackedTimeInMenuBar,
            showIssueReferenceInMenuBar: showIssueReferenceInMenuBar,
            showParentIssueOnCard: showParentIssueOnCard,
            showStatusPillOnCard: showStatusPillOnCard,
            groupPaths: normalizedGroupPaths,
            legacyGroupPath: normalizedGroupPaths.first ?? "",
            lastSelectedProjectID: lastSelectedProjectID,
            recentProjectIDs: recentProjectIDs,
            recentIssueIDs: recentIssueIDs,
            checkpointMinutes: checkpointMinutes,
            notificationSound: notificationSound
        )
    }

    private func writeToDefaults(_ v: SettingsValues) {
        defaults.set(v.baseURL, forKey: Keys.gitLabBaseURL)
        defaults.set(v.clientID, forKey: Keys.oauthClientID)
        defaults.set(v.showTrackedTimeInMenuBar, forKey: Keys.showTrackedTimeInMenuBar)
        defaults.set(v.showIssueReferenceInMenuBar, forKey: Keys.showIssueReferenceInMenuBar)
        defaults.set(v.showParentIssueOnCard, forKey: Keys.showParentIssueOnCard)
        defaults.set(v.showStatusPillOnCard, forKey: Keys.showStatusPillOnCard)
        defaults.set(v.groupPaths, forKey: Keys.gitLabGroupPaths)
        defaults.set(v.legacyGroupPath, forKey: Keys.gitLabGroupPath)
        defaults.set(v.lastSelectedProjectID, forKey: Keys.lastSelectedProjectID)
        defaults.set(v.recentProjectIDs, forKey: Keys.recentProjectIDs)
        defaults.set(v.recentIssueIDs, forKey: Keys.recentIssueIDs)
        defaults.set(v.checkpointMinutes, forKey: Keys.checkpointMinutes)
        defaults.set(v.notificationSound, forKey: Keys.notificationSound)
    }

    private func writeToCloudStore(_ v: SettingsValues) {
        cloudStore.set(v.baseURL, forKey: Keys.gitLabBaseURL)
        cloudStore.set(v.clientID, forKey: Keys.oauthClientID)
        cloudStore.set(v.showTrackedTimeInMenuBar, forKey: Keys.showTrackedTimeInMenuBar)
        cloudStore.set(v.showIssueReferenceInMenuBar, forKey: Keys.showIssueReferenceInMenuBar)
        cloudStore.set(v.showParentIssueOnCard, forKey: Keys.showParentIssueOnCard)
        cloudStore.set(v.showStatusPillOnCard, forKey: Keys.showStatusPillOnCard)
        cloudStore.set(v.groupPaths, forKey: Keys.gitLabGroupPaths)
        cloudStore.set(v.legacyGroupPath, forKey: Keys.gitLabGroupPath)
        cloudStore.set(v.lastSelectedProjectID, forKey: Keys.lastSelectedProjectID)
        cloudStore.set(v.recentProjectIDs, forKey: Keys.recentProjectIDs)
        cloudStore.set(v.recentIssueIDs, forKey: Keys.recentIssueIDs)
        cloudStore.set(v.checkpointMinutes, forKey: Keys.checkpointMinutes)
        cloudStore.set(v.notificationSound, forKey: Keys.notificationSound)
    }

    nonisolated private static func resolveGroupPaths(primary: [String], fallbackArray: [String], fallbackSingle: String) -> [String] {
        let combined = !primary.isEmpty ? primary : (!fallbackArray.isEmpty ? fallbackArray : [fallbackSingle])
        return combined
            .map(normalizeGroupPath)
            .filter { !$0.isEmpty }
            .uniquedAndSorted()
    }

    nonisolated private static func normalizeGroupPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private extension Array where Element == String {
    func uniquedAndSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
