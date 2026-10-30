import Foundation

/// Küçük yanıtlar (appcast beslemesi, cask listesi) için sınırlı indirme:
/// - ilk adres ve her yönlendirme adımı https olmalı (http'ye düşürme reddedilir),
/// - yalnızca HTTP 200 kabul edilir ve son yanıtın adresi de https olmalı,
/// - gövde akış hâlinde okunur; üst sınır aşılınca indirme hemen kesilir (bellek tükenmez),
/// - istek ve toplam süre sınırlıdır.
/// Göreli adresler (ör. appcast `enclosure`) yalnızca döndürülen son https adrese göre çözülmelidir.
enum BoundedFetch {
    /// Appcast beslemesi üst sınırı (10 MB).
    static let feedLimit = 10 * 1024 * 1024
    /// Homebrew cask listesi üst sınırı (64 MB).
    static let caskIndexLimit = 64 * 1024 * 1024

    enum Failure: Error, Equatable {
        case insecure, tooLarge, status(Int), transport
    }

    static func isSecure(_ url: URL?) -> Bool { SparkleInstaller.isSecure(url) }

    /// Gövdeyi ve son (yönlendirmeler sonrası) https adresini döndürür.
    static func data(from url: URL, maxBytes: Int, requestTimeout: TimeInterval, resourceTimeout: TimeInterval,
                     configuration: URLSessionConfiguration = .ephemeral) async throws -> (Data, URL) {
        guard isSecure(url) else { throw Failure.insecure }
        let config = configuration
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpAdditionalHeaders = ["User-Agent": "Tazele"]
        let delegate = BoundedDataDelegate(maxBytes: maxBytes)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Tazele", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URL), Error>) in
                delegate.start(cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Akış hâlinde, sınırlı biriktiren veri görevi temsilcisi.
final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URL), Error>?
    private var buffer = Data()
    private var failure: BoundedFetch.Failure?
    private var finalURL: URL?

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func start(_ cont: CheckedContinuation<(Data, URL), Error>) { lock.withLock { continuation = cont } }

    private func fail(_ f: BoundedFetch.Failure) { lock.withLock { if failure == nil { failure = f } } }

    /// Yönlendirme yalnızca https adrese izinlidir.
    static func allowsRedirect(to url: URL?) -> Bool { BoundedFetch.isSecure(url) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if Self.allowsRedirect(to: request.url) { completionHandler(request); return }
        fail(.insecure)
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            fail(.status(http?.statusCode ?? 0)); completionHandler(.cancel); return
        }
        guard BoundedFetch.isSecure(http.url) else { fail(.insecure); completionHandler(.cancel); return }
        if response.expectedContentLength > Int64(maxBytes) { fail(.tooLarge); completionHandler(.cancel); return }
        lock.withLock { finalURL = http.url }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over: Bool = lock.withLock {
            guard failure == nil else { return true }
            if buffer.count + data.count > maxBytes { failure = .tooLarge; return true }
            buffer.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, result): (CheckedContinuation<(Data, URL), Error>?, Result<(Data, URL), Error>) = lock.withLock {
            let c = continuation
            continuation = nil
            if let failure { return (c, .failure(failure)) }
            if let error {
                if (error as? URLError)?.code == .cancelled { return (c, .failure(CancellationError())) }
                return (c, .failure(BoundedFetch.Failure.transport))
            }
            guard let finalURL else { return (c, .failure(BoundedFetch.Failure.transport)) }
            return (c, .success((buffer, finalURL)))
        }
        cont?.resume(with: result)
    }
}
