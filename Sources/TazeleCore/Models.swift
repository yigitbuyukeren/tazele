import Foundation

public enum SourceKind: String, Sendable, CaseIterable {
    case homebrewFormula, homebrewCask, appStore, npm, system

    public var title: String {
        switch self {
        case .homebrewFormula: "Homebrew (formül)"
        case .homebrewCask: "Homebrew (cask)"
        case .appStore: "App Store"
        case .npm: "npm (global)"
        case .system: "macOS"
        }
    }
}

public struct OutdatedItem: Identifiable, Hashable, Sendable {
    public let source: SourceKind
    public let name: String
    public let installed: String
    public let latest: String
    public var id: String { "\(source.rawValue):\(name)" }

    public init(source: SourceKind, name: String, installed: String, latest: String) {
        self.source = source
        self.name = name
        self.installed = installed
        self.latest = latest
    }
}
