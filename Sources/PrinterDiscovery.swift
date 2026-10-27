import Foundation
import Darwin

struct DiscoveredPrinter: Identifiable, Equatable {
    let name: String
    let address: String
    var id: String { address }
}

final class PrinterDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var printers: [DiscoveredPrinter] = []
    @Published private(set) var searching = false
    @Published private(set) var failure: String?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var searchDeadline: DispatchWorkItem?

    override init() { super.init(); browser.delegate = self }
    func start() {
        stop()
        printers = []; failure = nil; searching = true
        browser.searchForServices(ofType: "_uscans._tcp.", inDomain: "local.")
        let deadline = DispatchWorkItem { [weak self] in self?.searching = false }
        searchDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    }
    func stop() {
        searchDeadline?.cancel(); searchDeadline = nil
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        searching = false
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        searching = false
        failure = "Не удалось начать поиск. Проверьте доступ приложения к локальной сети."
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        service.stop()
        services.removeAll { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
        printers.removeAll { $0.name == service.name }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services.contains(where: { $0 === sender }), sender.port == 443 else { return }
        for data in sender.addresses ?? [] {
            let address: String? = data.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr_in>.size,
                      let base = raw.baseAddress else { return nil }
                var socket = sockaddr_in()
                memcpy(&socket, base, MemoryLayout<sockaddr_in>.size)
                guard Int32(socket.sin_family) == AF_INET else { return nil }
                var ip = socket.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            guard let address, ScanValidation.baseURL(address) != nil else { continue }
            let printer = DiscoveredPrinter(name: sender.name, address: address)
            if !printers.contains(where: { $0.address == address }) { printers.append(printer) }
        }
    }
}
