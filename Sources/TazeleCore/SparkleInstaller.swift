import Foundation

public enum SparkleInstallError: Error, LocalizedError {
    case notSupported
    public var errorDescription: String? { String(localized: "Bu uygulama Tazele'den kurulamaz", bundle: .main) }
}

/// Sparkle uygulamasını imza doğrulayarak kendisi kurar. (Henüz uygulanmadı.)
public enum SparkleInstaller {
    /// Bu öğe Tazele'den kurulabilir mi?
    public static func canInstall(_ item: OutdatedItem) -> Bool { false }

    public static func install(_ item: OutdatedItem, onLine: @Sendable (String) -> Void) async throws {
        throw SparkleInstallError.notSupported
    }
}
