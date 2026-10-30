import Foundation

public enum SourceKind: String, Sendable, CaseIterable {
    case homebrewFormula, homebrewCask, selfUpdatingCask, appStore, sparkle, npm, rustup, gem, pythonTools, ohMyZsh, system

    public var title: String {
        switch self {
        case .homebrewFormula: String(localized: "Homebrew (formül)", bundle: .main)
        case .homebrewCask: String(localized: "Homebrew (cask)", bundle: .main)
        case .selfUpdatingCask: String(localized: "Kendi güncelleyen cask'ler", bundle: .main)
        case .appStore: String(localized: "App Store", bundle: .main)
        case .sparkle: String(localized: "Uygulamalar (kendi güncelleyicisi)", bundle: .main)
        case .npm: String(localized: "npm (global)", bundle: .main)
        case .rustup: String(localized: "Rust (rustup)", bundle: .main)
        case .gem: String(localized: "RubyGems", bundle: .main)
        case .pythonTools: String(localized: "Python araçları (pipx / uv)", bundle: .main)
        case .ohMyZsh: String(localized: "Oh My Zsh", bundle: .main)
        case .system: String(localized: "macOS", bundle: .main)
        }
    }
}

public struct OutdatedItem: Identifiable, Hashable, Sendable {
    public let source: SourceKind
    public let name: String
    public let installed: String
    public let latest: String
    /// App Store için uygulama kimliği (`mas update <id>`).
    public let appID: String?
    /// Sparkle uygulamaları için .app yolu (güncelleyicisini kullanıcı açar).
    public let path: String?
    /// Sparkle uygulamasının Homebrew cask karşılığı varsa belirteci (`brew upgrade --cask --greedy <token>`).
    public let caskToken: String?
    /// Paket yöneticisi: pythonTools için "pipx" veya "uv"; system için softwareupdate etiketi.
    public let manager: String?
    /// macOS güncellemesi Tazele'den kurulabilir mi (yeniden başlatma istemiyor).
    public let installable: Bool
    public var id: String { "\(source.rawValue):\(name)" }

    public init(source: SourceKind, name: String, installed: String, latest: String, appID: String? = nil, path: String? = nil,
                caskToken: String? = nil, manager: String? = nil, installable: Bool = false) {
        self.source = source
        self.name = name
        self.installed = installed
        self.latest = latest
        self.appID = appID
        self.path = path
        self.caskToken = caskToken
        self.manager = manager
        self.installable = installable
    }
}

extension OutdatedItem {
    /// Aynı öğeyi, Homebrew cask belirteciyle döndürür (Sparkle uygulaması cask ile kurulmuşsa).
    public func withCaskToken(_ token: String?) -> OutdatedItem {
        OutdatedItem(source: source, name: name, installed: installed, latest: latest, appID: appID,
                     path: path, caskToken: token, manager: manager, installable: installable)
    }
}
