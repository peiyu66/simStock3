import Foundation

/// One stable list of work subjects, shared by every phase of an operation.
/// Month counts are a separate unit and must never replace this denominator.
struct OperationProgress {
    enum Subject: Hashable {
        case market
        case stock(String)
    }

    let subjects: [Subject]

    init(subjects: [Subject]) {
        var seen: Set<Subject> = []
        self.subjects = subjects.filter { seen.insert($0).inserted }
    }

    func position(of subject: Subject) -> Int? {
        subjects.firstIndex(of: subject).map { $0 + 1 }
    }

    func message(for subject: Subject, _ text: String) -> String {
        guard let position = position(of: subject) else { return text }
        return Self.message(position: position, total: subjects.count, text)
    }

    static func message(position: Int, total: Int, _ text: String) -> String {
        total > 1 ? "\(position)/\(total) \(text)" : text
    }

    static func monthDetail(position: Int, total: Int) -> String {
        total > 1 ? "（本批第 \(position)/\(total) 個月）" : ""
    }
}
