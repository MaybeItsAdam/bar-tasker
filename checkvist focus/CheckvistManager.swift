import Foundation
import SwiftUI
import Combine

struct CheckvistTask: Codable, Identifiable {
    let id: Int
    let content: String
    let status: Int
    let due: String?
    let position: Int?
    let parentId: Int?
    let level: Int?

    enum CodingKeys: String, CodingKey {
        case id, content, status, due, position
        case parentId = "parent_id"
        case level
    }

    var dueDate: Date? {
        guard let due else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: due)
    }

    var isOverdue: Bool {
        guard let d = dueDate else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let d = dueDate else { return false }
        return Calendar.current.isDateInToday(d)
    }
}

@MainActor
class CheckvistManager: ObservableObject {
    @Published var username: String
    @Published var remoteKey: String
    @Published var listId: String

    @Published var tasks: [CheckvistTask] = []
    @Published var currentTaskIndex: Int = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    var currentTaskText: String {
        guard !tasks.isEmpty else { return "" }
        return tasks[currentTaskIndex].content
    }

    var currentTask: CheckvistTask? {
        guard !tasks.isEmpty, tasks.indices.contains(currentTaskIndex) else { return nil }
        return tasks[currentTaskIndex]
    }

    private var token: String? = nil
    private var cancellables = Set<AnyCancellable>()

    // Bypass system PAC proxy scripts that cause -1003 errors
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [AnyHashable: Any]()
        return URLSession(configuration: config)
    }()

    init() {
        self.username = UserDefaults.standard.string(forKey: "checkvistUsername") ?? ""
        self.remoteKey = UserDefaults.standard.string(forKey: "checkvistRemoteKey") ?? ""
        self.listId = UserDefaults.standard.string(forKey: "checkvistListId") ?? ""
        setupBindings()
    }

    private func setupBindings() {
        $username.sink { UserDefaults.standard.set($0, forKey: "checkvistUsername") }.store(in: &cancellables)
        $remoteKey.sink { UserDefaults.standard.set($0, forKey: "checkvistRemoteKey") }.store(in: &cancellables)
        $listId.sink { UserDefaults.standard.set($0, forKey: "checkvistListId") }.store(in: &cancellables)
    }

    // MARK: - Navigation

    func nextTask() {
        guard !tasks.isEmpty else { return }
        currentTaskIndex = (currentTaskIndex + 1) % tasks.count
    }

    func previousTask() {
        guard !tasks.isEmpty else { return }
        currentTaskIndex = (currentTaskIndex - 1 + tasks.count) % tasks.count
    }

    // MARK: - API

    func login() async -> Bool {
        guard !username.isEmpty, !remoteKey.isEmpty else {
            errorMessage = "Username or Remote Key is missing."
            return false
        }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/auth/login.json") else {
            errorMessage = "Invalid login URL."
            isLoading = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        let body: [String: String] = ["username": username, "remote_key": remoteKey]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                errorMessage = "Login failed. Check your credentials."
                isLoading = false
                return false
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tokenString = json["token"] as? String {
                self.token = tokenString
            } else if let tokenString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")) {
                self.token = tokenString
            } else {
                errorMessage = "Failed to parse token."
                isLoading = false
                return false
            }

            isLoading = false
            return true
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func fetchTopTask() async {
        guard !listId.isEmpty else { return }

        if token == nil {
            let success = await login()
            if !success { return }
        }

        guard let validToken = token else { return }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json") else {
            errorMessage = "Invalid list URL."
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                self.token = nil
                self.isLoading = false
                return
            }

            let decoder = JSONDecoder()
            let allTasks = try decoder.decode([CheckvistTask].self, from: data)

            // Only open tasks, walk depth-first respecting Checkvist's tree order
            let open = allTasks.filter { $0.status == 0 }
            
            // Build a depth-first order: sort each level by position, recurse children
            func depthFirst(parentId: Int, all: [CheckvistTask]) -> [CheckvistTask] {
                let children = all
                    .filter { ($0.parentId ?? 0) == parentId }
                    .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
                return children.flatMap { [$0] + depthFirst(parentId: $0.id, all: all) }
            }
            let sorted = depthFirst(parentId: 0, all: open)

            self.tasks = sorted
            if currentTaskIndex >= sorted.count { currentTaskIndex = 0 }
            print("DEBUG fetchTopTask: \(sorted.count) tasks loaded")

        } catch {
            print("DEBUG fetchTopTask error: \(error)")
            errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func markCurrentTaskDone() async {
        guard let task = currentTask, let validToken = token else { return }

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["status": 1]])

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to mark task as done."
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    func addTask(content: String) async {
        guard !content.isEmpty, !listId.isEmpty else { return }

        if token == nil {
            let success = await login()
            if !success { return }
        }

        guard let validToken = token else { return }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json") else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["content": content]])

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to add task."
                isLoading = false
            }
        } catch {
            errorMessage = "Error adding task: \(error.localizedDescription)"
            isLoading = false
        }
    }
}
