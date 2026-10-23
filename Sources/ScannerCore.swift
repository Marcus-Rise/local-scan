import Foundation
import PDFKit
import CryptoKit
import Security

struct ScanFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ScanOptions: Sendable {
    var color = true
    var dpi = 300
    var fullGlass = false
    func xml() throws -> Data {
        guard [200, 300, 600].contains(dpi) else {
            throw ScanFailure(message: "Выберите качество 200, 300 или 600 dpi.")
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
        <pwg:Version>2.0</pwg:Version><scan:Intent>Document</scan:Intent>
        <pwg:ScanRegions><pwg:ScanRegion>
        <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
        <pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset>
        <pwg:Width>\(fullGlass ? 2550 : 2480)</pwg:Width><pwg:Height>3508</pwg:Height>
        </pwg:ScanRegion></pwg:ScanRegions><pwg:InputSource>Platen</pwg:InputSource>
        <scan:ColorMode>\(color ? "RGB24" : "Grayscale8")</scan:ColorMode>
        <pwg:DocumentFormat>application/pdf</pwg:DocumentFormat><scan:DocumentFormatExt>application/pdf</scan:DocumentFormatExt>
        <scan:XResolution>\(dpi)</scan:XResolution><scan:YResolution>\(dpi)</scan:YResolution>
        </scan:ScanSettings>
        """.utf8)
    }
}

enum ScanValidation {
    static func baseURL(_ address: String) -> URL? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        let n = parts.compactMap { UInt8($0) }
        guard n[0] == 10 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && (16...31).contains(n[1])) else { return nil }
        guard n[3] != 0 && n[3] != 255 else { return nil }
        return URL(string: "https://\(n.map(String.init).joined(separator: "."))/eSCL/")
    }
    static func jobURL(_ location: String, base: URL) -> URL? {
        guard let url = URL(string: location, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == base.host, (url.port ?? 443) == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/eSCL/ScanJobs/") else { return nil }
        let job = String(url.path.dropFirst("/eSCL/ScanJobs/".count))
        guard !job.isEmpty, job != ".", job != "..",
              job.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return url
    }
    static func pdf(_ data: Data) -> PDFDocument? {
        guard data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data), pdf.pageCount > 0,
              !pdf.isLocked, (0..<pdf.pageCount).allSatisfy({ pdf.page(at: $0) != nil }) else { return nil }
        return pdf
    }
}

// Trust only the certificate explicitly paired by the user; no global TLS exception.
final class PrinterTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let fingerprint: String?
    private let lock = NSLock()
    private var observed: String?
    var observedFingerprint: String? { lock.withLock { observed } }
    init(host: String, fingerprint: String?) { self.host = host; self.fingerprint = fingerprint }
    static func matches(_ observed: String, expected: String?) -> Bool {
        guard let expected, expected.count == 64 else { return false }
        return observed == expected
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
        lock.withLock { observed = digest }
        guard Self.matches(digest, expected: fingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ScannerClient {
    let base: URL
    let session: URLSession
    let trust: PrinterTrust
    init(address: String, fingerprint: String? = nil) throws {
        guard let url = ScanValidation.baseURL(address) else {
            throw ScanFailure(message: "Укажите локальный IP принтера, например 192.168.1.50.")
        }
        base = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        trust = PrinterTrust(host: url.host!, fingerprint: fingerprint)
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }
    // Probe stops at the TLS challenge: no HTTP response is accepted before pairing.
    func observedFingerprint() async throws -> String {
        _ = try? await session.data(from: base.appendingPathComponent("ScannerCapabilities"))
        try Task.checkCancellation()
        guard let fingerprint = trust.observedFingerprint else {
            throw ScanFailure(message: "Не удалось получить сертификат принтера. Проверьте IP, питание и доступность HTTPS.")
        }
        return fingerprint
    }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method; req.httpBody = body
        if body != nil { req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: req)
            guard let response = response as? HTTPURLResponse else { throw ScanFailure(message: "Некорректный ответ сканера.") }
            return (data, response)
        } catch let e as URLError {
            if Task.isCancelled { throw CancellationError() }
            if e.code == .serverCertificateUntrusted || e.code == .cancelled || e.code == .secureConnectionFailed {
                throw ScanFailure(message: "Сертификат устройства отличается от сохранённого. Проверьте IP и сам принтер. Для повторной привязки используйте настройки принтера.")
            }
            throw ScanFailure(message: "Нет ответа от принтера. Проверьте питание, Wi-Fi и сохранённый адрес. \(e.localizedDescription)")
        }
    }
    func check() async throws -> String {
        let (data, response) = try await request(base.appendingPathComponent("ScannerCapabilities"))
        guard response.statusCode == 200,
              let xml = try? XMLDocument(data: data),
              let model = try? xml.nodes(forXPath: "//*[local-name()='MakeAndModel']").first?.stringValue,
              !model.isEmpty else { throw ScanFailure(message: "Сканер не найден по этому адресу.") }
        guard String(data: data, encoding: .utf8)?.contains("RGB24") == true else {
            throw ScanFailure(message: "Устройство не сообщает о поддержке цветного сканирования.")
        }
        return model
    }
    func scan(_ options: ScanOptions) async throws -> Data {
        _ = try await check()
        try Task.checkCancellation()
        let (_, created) = try await request(base.appendingPathComponent("ScanJobs"), method: "POST", body: options.xml())
        if created.statusCode == 409 || created.statusCode == 503 {
            throw ScanFailure(message: "Сканер занят. Дождитесь завершения другой задачи и попробуйте снова.")
        }
        guard created.statusCode == 201, let location = created.value(forHTTPHeaderField: "Location"),
              let job = ScanValidation.jobURL(location, base: base) else {
            throw ScanFailure(message: "Принтер не принял задание (HTTP \(created.statusCode)). Проверьте, закрыта ли крышка и нет ли ошибки на панели.")
        }
        do {
            let deadline = Date().addingTimeInterval(150)
            while Date() < deadline {
                try Task.checkCancellation()
                let (data, response) = try await request(job.appendingPathComponent("NextDocument"))
                if response.statusCode == 200 {
                    guard ScanValidation.pdf(data) != nil else { throw ScanFailure(message: "Получен повреждённый PDF. Предыдущие страницы сохранены в окне.") }
                    return data
                }
                guard response.statusCode == 503 else {
                    throw ScanFailure(message: "Не удалось получить страницу (HTTP \(response.statusCode)). Предыдущие страницы сохранены.")
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw ScanFailure(message: "Принтер не завершил сканирование за отведённое время.")
        } catch {
            let session = self.session
            Task.detached {
                var req = URLRequest(url: job); req.httpMethod = "DELETE"; req.timeoutInterval = 10
                _ = try? await session.data(for: req)
            }
            throw error
        }
    }
}
