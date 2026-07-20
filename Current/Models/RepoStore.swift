import Foundation

@Observable
final class RepoStore {
    private(set) var repoPaths: [URL]

    private let defaultsKey = "repoPaths"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        repoPaths = saved.map { URL(fileURLWithPath: $0) }
    }

    func addRepo(at url: URL) {
        guard !repoPaths.contains(url) else { return }
        repoPaths.append(url)
        persist()
    }

    func removeRepo(at url: URL) {
        repoPaths.removeAll { $0 == url }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(repoPaths.map(\.path), forKey: defaultsKey)
    }
}
