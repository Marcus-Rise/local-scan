import Foundation

@main struct PrinterStoreTests {
    @MainActor static func main() throws {
        let suite = "LocalScan.PrinterStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func expect(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }; print("PASS", message)
        }
        defaults.set("192.168.1.40", forKey: "printerAddress")
        defaults.set("Legacy HP", forKey: "printerName")
        var store = PrinterStore(defaults: defaults)
        expect(store.printers.count == 1 && store.printers[0].name == "Legacy HP", "existing printer migrated")
        let added = try store.save(name: " Office ", address: " 192.168.1.50 ")
        expect(added.name == "Office" && added.address == "192.168.1.50", "add normalizes name and address")
        do { _ = try store.save(name: "Duplicate", address: added.address); fatalError("duplicate allowed") }
        catch { expect(store.printers.count == 2, "duplicate rejected without altering library") }
        store.select(added)
        defaults.set([added.address: String(repeating: "a", count: 64)], forKey: "printerCertificates")
        let renamed = try store.save(name: "My HP", address: added.address, replacing: added.id)
        expect(renamed.id == added.id && defaults.string(forKey: "printerName") == "My HP", "rename preserves identity and updates active name")
        store = PrinterStore(defaults: defaults)
        expect(store.printers.contains(renamed), "saved records survive reopening")
        let edited = try store.save(name: renamed.name, address: "192.168.1.51", replacing: renamed.id)
        expect(store.selectedAddress == edited.address && defaults.string(forKey: "printerAddress") == edited.address, "address edit updates active device")
        expect((defaults.dictionary(forKey: "printerCertificates") as? [String: String])?[edited.address] == nil, "certificate is not transferred to changed address")
        store.remove(edited)
        store = PrinterStore(defaults: defaults)
        expect(store.printers.count == 1 && store.selectedAddress.isEmpty, "delete persists and clears active selection")
        do { _ = try store.save(name: "Remote", address: "8.8.8.8"); fatalError("public address allowed") }
        catch { expect(store.printers.count == 1, "public address rejected without saving") }
        store.remove(store.printers[0])
        store = PrinterStore(defaults: defaults)
        expect(store.printers.isEmpty, "empty library stays empty after reopening")
    }
}
