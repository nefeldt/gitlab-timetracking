//
//  GitLabAPI.swift
//  My GitLab Timetracking
//

import Foundation

struct AuthorizedGitLabConfiguration {
    let baseURL: URL
    let accessToken: String
}

struct GitLabIssue: Codable, Identifiable, Hashable {
    struct References: Codable, Hashable {
        let short: String
    }

    struct TimeStats: Codable, Hashable {
        let totalTimeSpent: Int

        enum CodingKeys: String, CodingKey {
            case totalTimeSpent = "total_time_spent"
        }
    }

    let id: Int
    let iid: Int
    let projectID: Int
    let title: String
    let webURL: URL
    let updatedAt: Date
    let references: References
    let timeStats: TimeStats

    enum CodingKeys: String, CodingKey {
        case id
        case iid
        case title
        case references
        case timeStats = "time_stats"
        case projectID = "project_id"
        case webURL = "web_url"
        case updatedAt = "updated_at"
    }
}

struct GitLabIssueStatus: Hashable {
    let name: String
    let colorHex: String?
    let iconName: String?
}

struct GitLabIssueParent: Hashable {
    let id: Int
    let title: String
    let webURL: URL
}

struct GitLabIssueWorkItemInfo: Hashable {
    let status: GitLabIssueStatus?
    let parent: GitLabIssueParent?
}

struct GitLabUser: Codable, Hashable {
    let id: Int
    let username: String
    let name: String
    let webURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case name
        case webURL = "web_url"
    }
}

struct GitLabProject: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let nameWithNamespace: String
    let pathWithNamespace: String
    let webURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameWithNamespace = "name_with_namespace"
        case pathWithNamespace = "path_with_namespace"
        case webURL = "web_url"
    }
}

struct GitLabIssueNote: Codable, Hashable, Identifiable {
    let id: Int
    let body: String
    let system: Bool
    let author: GitLabUser
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case system
        case author
        case createdAt = "created_at"
    }
}

struct GitLabCreatedIssue: Codable, Hashable {
    let id: Int
    let iid: Int
    let title: String
    let webURL: URL
    let references: GitLabIssue.References

    var reference: String {
        references.short
    }

    enum CodingKeys: String, CodingKey {
        case id
        case iid
        case title
        case webURL = "web_url"
        case references
    }
}

struct GraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GraphQLErrorMessage]?
}

struct GraphQLErrorMessage: Decodable {
    let message: String
}

enum GitLabAPIError: LocalizedError {
    case missingConfiguration
    case notAuthenticated
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Configure the GitLab base URL and OAuth application ID first."
        case .notAuthenticated:
            return "Connect your GitLab account first."
        case .invalidResponse:
            return "GitLab returned an unexpected response."
        case let .serverError(statusCode, message):
            return "GitLab request failed (\(statusCode)): \(message)"
        }
    }
}

actor GitLabAPI {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = Self.makeDecoder()
    }

    func fetchAssignedIssues(configuration: AuthorizedGitLabConfiguration) async throws -> [GitLabIssue] {
        try await fetchAssignedIssues(state: "opened", configuration: configuration)
    }

    func fetchClosedAssignedIssues(updatedAfter: Date? = nil, configuration: AuthorizedGitLabConfiguration) async throws -> [GitLabIssue] {
        try await fetchAssignedIssues(state: "closed", updatedAfter: updatedAfter, configuration: configuration)
    }

    private func fetchAssignedIssues(state: String, updatedAfter: Date? = nil, configuration: AuthorizedGitLabConfiguration) async throws -> [GitLabIssue] {
        var allIssues: [GitLabIssue] = []
        var nextPage = "1"
        let formatter = ISO8601DateFormatter()

        while !nextPage.isEmpty {
            var queryItems = [
                URLQueryItem(name: "scope", value: "assigned_to_me"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: nextPage)
            ]

            if let updatedAfter {
                queryItems.append(URLQueryItem(name: "updated_after", value: formatter.string(from: updatedAfter)))
            }

            let request = try makeRequest(
                configuration: configuration,
                path: "/api/v4/issues",
                queryItems: queryItems
            )

            let (data, response) = try await session.data(for: request)
            let httpResponse = try validate(response: response, data: data)
            allIssues += try decoder.decode([GitLabIssue].self, from: data)
            nextPage = httpResponse.value(forHTTPHeaderField: "X-Next-Page") ?? ""
        }

        return allIssues
    }

    func fetchCurrentUser(configuration: AuthorizedGitLabConfiguration) async throws -> GitLabUser {
        let request = try makeRequest(
            configuration: configuration,
            path: "/api/v4/user"
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(GitLabUser.self, from: data)
    }

    func fetchProjects(configuration: AuthorizedGitLabConfiguration) async throws -> [GitLabProject] {
        var collectedProjects: [GitLabProject] = []
        var nextPage = "1"

        while !nextPage.isEmpty {
            let request = try makeRequest(
                configuration: configuration,
                path: "/api/v4/projects",
                queryItems: [
                    URLQueryItem(name: "simple", value: "true"),
                    URLQueryItem(name: "archived", value: "false"),
                    URLQueryItem(name: "order_by", value: "path"),
                    URLQueryItem(name: "sort", value: "asc"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: nextPage)
                ]
            )

            let (data, response) = try await session.data(for: request)
            let httpResponse = try validate(response: response, data: data)
            collectedProjects += try decoder.decode([GitLabProject].self, from: data)
            nextPage = httpResponse.value(forHTTPHeaderField: "X-Next-Page") ?? ""
        }

        return collectedProjects
    }

    func createIssue(
        projectID: Int,
        title: String,
        description: String?,
        assigneeID: Int?,
        configuration: AuthorizedGitLabConfiguration
    ) async throws -> GitLabCreatedIssue {
        let request = try makeRequest(
            configuration: configuration,
            path: "/api/v4/projects/\(projectID)/issues",
            method: "POST",
            bodyItems: [
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "description", value: description),
                URLQueryItem(name: "assignee_id", value: assigneeID.map(String.init)),
                URLQueryItem(name: "assignee_ids[]", value: assigneeID.map(String.init))
            ]
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(GitLabCreatedIssue.self, from: data)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }

        return decoder
    }

    func fetchIssue(projectID: Int, iid: Int, configuration: AuthorizedGitLabConfiguration) async throws -> GitLabIssue {
        let request = try makeRequest(
            configuration: configuration,
            path: "/api/v4/projects/\(projectID)/issues/\(iid)"
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(GitLabIssue.self, from: data)
    }

    func fetchIssueNotes(projectID: Int, issueIID: Int, configuration: AuthorizedGitLabConfiguration) async throws -> [GitLabIssueNote] {
        var allNotes: [GitLabIssueNote] = []
        var nextPage = "1"

        while !nextPage.isEmpty {
            let request = try makeRequest(
                configuration: configuration,
                path: "/api/v4/projects/\(projectID)/issues/\(issueIID)/notes",
                queryItems: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: nextPage)
                ]
            )

            let (data, response) = try await session.data(for: request)
            let httpResponse = try validate(response: response, data: data)
            allNotes += try decoder.decode([GitLabIssueNote].self, from: data)
            nextPage = httpResponse.value(forHTTPHeaderField: "X-Next-Page") ?? ""
        }

        return allNotes
    }

    func addSpentTime(issue: GitLabIssue, duration: String, configuration: AuthorizedGitLabConfiguration) async throws {
        try await addSpentTime(projectID: issue.projectID, issueIID: issue.iid, duration: duration, configuration: configuration)
    }

    func addSpentTime(projectID: Int, issueIID: Int, duration: String, configuration: AuthorizedGitLabConfiguration) async throws {
        let path = "/api/v4/projects/\(projectID)/issues/\(issueIID)/add_spent_time"
        let request = try makeRequest(
            configuration: configuration,
            path: path,
            method: "POST",
            queryItems: [URLQueryItem(name: "duration", value: duration)]
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func closeIssue(issue: GitLabIssue, configuration: AuthorizedGitLabConfiguration) async throws {
        let request = try makeRequest(
            configuration: configuration,
            path: "/api/v4/projects/\(issue.projectID)/issues/\(issue.iid)",
            method: "PUT",
            bodyItems: [
                URLQueryItem(name: "state_event", value: "close")
            ]
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func deleteIssue(issue: GitLabIssue, configuration: AuthorizedGitLabConfiguration) async throws {
        let request = try makeRequest(
            configuration: configuration,
            path: "/api/v4/projects/\(issue.projectID)/issues/\(issue.iid)",
            method: "DELETE"
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func fetchIssueWorkItemInfo(
        issueIDs: [Int],
        configuration: AuthorizedGitLabConfiguration
    ) async throws -> [Int: GitLabIssueWorkItemInfo] {
        guard !issueIDs.isEmpty else { return [:] }

        var result: [Int: GitLabIssueWorkItemInfo] = [:]
        let chunkSize = 10

        for chunk in stride(from: 0, to: issueIDs.count, by: chunkSize).map({ start in
            Array(issueIDs[start..<min(start + chunkSize, issueIDs.count)])
        }) {
            let aliased = chunk.map { id in
                "i_\(id): workItem(id: \"gid://gitlab/WorkItem/\(id)\") { ...workItemFields }"
            }.joined(separator: "\n")

            let query = """
            query {
            \(aliased)
            }
            fragment workItemFields on WorkItem {
              widgets {
                ... on WorkItemWidgetStatus {
                  status { name color iconName }
                }
                ... on WorkItemWidgetHierarchy {
                  parent { id title webUrl }
                }
              }
            }
            """

            let (rawData, rawResponse) = try await postGraphQL(query: query, configuration: configuration)
            try validate(response: rawResponse, data: rawData)

            let response: GraphQLResponse<[String: IssueWorkItemInfoNode?]>
            do {
                response = try decoder.decode(GraphQLResponse<[String: IssueWorkItemInfoNode?]>.self, from: rawData)
            } catch {
                logGraphQLFailure(reason: "decode failed: \(error)", body: rawData)
                continue
            }

            if let errors = response.errors, !errors.isEmpty {
                logGraphQLFailure(reason: "errors: \(errors.map(\.message).joined(separator: "; "))", body: rawData)
            }

            guard let nodes = response.data else {
                logGraphQLFailure(reason: "no data field", body: rawData)
                continue
            }

            if nodes.allSatisfy({ $0.value?.extracted() == nil }) {
                logGraphQLFailure(reason: "no work item widgets in response", body: rawData)
            }

            for (alias, node) in nodes {
                guard let node, let info = node.extracted() else { continue }
                guard alias.hasPrefix("i_"), let id = Int(alias.dropFirst(2)) else { continue }
                result[id] = info
            }
        }

        return result
    }

    private func logGraphQLFailure(reason: String, body: Data) {
        let preview = String(data: body.prefix(800), encoding: .utf8) ?? "<non-utf8>"
        NSLog("[GitLabAPI] work item fetch %@. body: %@", reason, preview)
    }

    private func postGraphQL(
        query: String,
        configuration: AuthorizedGitLabConfiguration
    ) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = configuration.baseURL.path + "/api/graphql"

        guard let url = components?.url else {
            throw GitLabAPIError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequestBody(query: query))

        return try await session.data(for: request)
    }

    private struct GraphQLRequestBody: Encodable {
        let query: String
    }

    private struct IssueWorkItemInfoNode: Decodable {
        let widgets: [Widget]?

        struct Widget: Decodable {
            let status: StatusValue?
            let parent: ParentValue?
        }

        struct StatusValue: Decodable {
            let name: String
            let color: String?
            let iconName: String?
        }

        struct ParentValue: Decodable {
            let id: String
            let title: String
            let webUrl: String
        }

        func extracted() -> GitLabIssueWorkItemInfo? {
            guard let widgets else { return nil }
            var status: GitLabIssueStatus?
            var parent: GitLabIssueParent?
            for widget in widgets {
                if let value = widget.status, status == nil {
                    status = GitLabIssueStatus(name: value.name, colorHex: value.color, iconName: value.iconName)
                }
                if let value = widget.parent,
                   parent == nil,
                   let url = URL(string: value.webUrl),
                   let parentID = Self.parseWorkItemID(value.id) {
                    parent = GitLabIssueParent(id: parentID, title: value.title, webURL: url)
                }
            }
            if status == nil, parent == nil { return nil }
            return GitLabIssueWorkItemInfo(status: status, parent: parent)
        }

        private static func parseWorkItemID(_ gid: String) -> Int? {
            guard let last = gid.split(separator: "/").last else { return nil }
            return Int(last)
        }
    }

    private func makeRequest(
        configuration: AuthorizedGitLabConfiguration,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        bodyItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = configuration.baseURL.path + path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw GitLabAPIError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if !bodyItems.isEmpty {
            var bodyComponents = URLComponents()
            bodyComponents.queryItems = bodyItems.filter { item in
                item.value != nil
            }
            request.httpBody = bodyComponents.query?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    @discardableResult
    private func validate(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitLabAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GitLabAPIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        return httpResponse
    }
}
