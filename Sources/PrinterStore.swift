import Foundation
import Combine

struct SavedPrinter: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var address: String
}

@MainActor final class PrinterStore: ObservableObject {
    @Published private(set) var printers: [SavedPrinter]
    @Published private(set) var selectedAddress: String
    private let defaults: UserDefaults
    private let key = "savedPrintersV2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedAddress = defaults.string(forKey: "printerAddress") ?? ""
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([SavedPrinter].self, from: data) {
            printers = saved
        } else {
            let previous = defaults.dictionary(forKey: "knownPrinters") as? [String: String] ?? [:]
            printers = previous.keys.sorted().filter { ScanValidation.baseURL($0) != nil }.map {
                SavedPrinter(id: UUID(), name: previous[$0] ?? "Сетевой принтер", address: $0)
            }
            if ScanValidation.baseURL(selectedAddress) != nil, !printers.contains(where: { $0.address == selectedAddress }) {
                printers.insert(SavedPrinter(id: UUID(), name: defaults.string(forKey: "printerName") ?? "Сетевой принтер", address: selectedAddress), at: 0)
            }
            persist()
        }
    }

    @discardableResult func save(name: String, address: String, replacing id: UUID? = nil) throws -> SavedPrinter {
        guard let normalized = ScanValidation.baseURL(address.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
            throw ScanFailure(message: "Введите локальный IP-адрес, например 192.168.1.50.")
        }
        guard !printers.contains(where: { $0.address == normalized && $0.id != id }) else {
            throw ScanFailure(message: "Принтер с этим адресом уже добавлен.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = SavedPrinter(id: id ?? UUID(), name: trimmed.isEmpty ? "Сетевой принтер" : String(trimmed.prefix(100)), address: normalized)
        if let id {
            guard let index = printers.firstIndex(where: { $0.id == id }) else { throw ScanFailure(message: "Этот принтер уже удалён.") }
            let wasSelected = printers[index].address == selectedAddress
            printers[index] = record
            if wasSelected { select(record) }
        } else { printers.append(record) }
        persist()
        return record
    }

    func select(_ printer: SavedPrinter) {
        selectedAddress = printer.address
        defaults.set(printer.address, forKey: "printerAddress")
        defaults.set(printer.name, forKey: "printerName")
    }

    func remove(_ printer: SavedPrinter) {
        printers.removeAll { $0.id == printer.id }
        var pins = defaults.dictionary(forKey: "printerCertificates") as? [String: String] ?? [:]
        pins.removeValue(forKey: printer.address)
        defaults.set(pins, forKey: "printerCertificates")
        if selectedAddress == printer.address {
            selectedAddress = ""
            defaults.removeObject(forKey: "printerAddress")
            defaults.removeObject(forKey: "printerName")
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(printers) { defaults.set(data, forKey: key) }
    }
}
