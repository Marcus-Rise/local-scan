import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum AppArtwork {
    static let icon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName)!
}

@MainActor final class ScanModel: ObservableObject {
    static let shared = ScanModel()
    @Published var document = PDFDocument()
    @Published var revision = UUID()
    @Published var busy = false
    @Published var checking = false
    @Published var online = false
    @Published var status = "Проверка принтера…"
    @Published var error: String?
    @Published var dirty = false
    @Published var savedURL: URL?
    @Published var selectedPage = 0
    var task: Task<Void, Never>?
    weak var pdfView: PDFView?
    var pageCount: Int { document.pageCount }
    var address: String { UserDefaults.standard.string(forKey: "printerAddress") ?? "" }
    var fingerprint: String? {
        (UserDefaults.standard.dictionary(forKey: "printerCertificates") as? [String: String])?[address]
    }
    func forgetCertificate() {
        var pins = UserDefaults.standard.dictionary(forKey: "printerCertificates") as? [String: String] ?? [:]
        pins.removeValue(forKey: address)
        UserDefaults.standard.set(pins, forKey: "printerCertificates")
        online = false
    }

    func check() {
        guard !busy && !checking else { return }
        checking = true
        online = false
        let targetAddress = address
        Task {
            defer { checking = false }
            do {
                var pin = fingerprint
                if pin == nil {
                    let probe = try ScannerClient(address: targetAddress)
                    let observed = try await probe.observedFingerprint()
                    let alert = NSAlert()
                    alert.messageText = "Подключить этот принтер?"
                    alert.informativeText = "Адрес: \(targetAddress)\n\nSHA-256 сертификата:\n\(observed)\n\nПодтвердите, что это ваш принтер в доверенной домашней сети. При первом подключении приложение ещё не знает его подлинность. Сертификат будет запомнен; при его изменении соединение будет заблокировано."
                    alert.addButton(withTitle: "Подключить")
                    alert.addButton(withTitle: "Отмена")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        status = "Подключение отменено"; return
                    }
                    var pins = UserDefaults.standard.dictionary(forKey: "printerCertificates") as? [String: String] ?? [:]
                    pins[targetAddress] = observed
                    UserDefaults.standard.set(pins, forKey: "printerCertificates")
                    pin = observed
                }
                let client = try ScannerClient(address: targetAddress, fingerprint: pin)
                let name = try await client.check()
                UserDefaults.standard.set(name, forKey: "printerName")
                online = true
                status = "Готов к сканированию"
            } catch {
                online = false
                status = "Принтер недоступен"
                self.error = error.localizedDescription
            }
        }
    }
    func scan(color: Bool, dpi: Int, fullGlass: Bool) {
        guard !busy && !checking else { return }
        busy = true; status = "Сканирование со стекла…"; error = nil
        let address = self.address
        task = Task {
            defer { busy = false; task = nil }
            do {
                guard let pin = fingerprint else { throw ScanFailure(message: "Сначала подключите принтер в настройках.") }
                let client = try ScannerClient(address: address, fingerprint: pin)
                let data = try await client.scan(ScanOptions(color: color, dpi: dpi, fullGlass: fullGlass))
                try Task.checkCancellation()
                guard let received = ScanValidation.pdf(data) else { throw ScanFailure(message: "Не удалось открыть PDF сканера.") }
                let firstNew = document.pageCount
                for i in 0..<received.pageCount {
                    guard let page = received.page(at: i)?.copy() as? PDFPage else { continue }
                    document.insert(page, at: document.pageCount)
                }
                selectedPage = firstNew
                dirty = true; online = true; revision = UUID()
                status = "Страница добавлена · \(color ? "цвет" : "оттенки серого") · \(dpi) dpi"
            } catch is CancellationError {
                status = "Сканирование отменено"
            } catch {
                status = "Не удалось получить страницу"
                self.error = error.localizedDescription
            }
        }
    }
    func cancel() { task?.cancel(); status = "Отмена сканирования…" }
    func save() -> Bool {
        guard pageCount > 0 && !busy else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH-mm"
        panel.nameFieldStringValue = savedURL?.lastPathComponent ?? "Скан \(formatter.string(from: Date())).pdf"
        panel.directoryURL = savedURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.title = "Сохранить скан"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            guard let data = document.dataRepresentation() else { throw ScanFailure(message: "Не удалось сформировать PDF.") }
            try data.write(to: url, options: .atomic)
            guard let verified = PDFDocument(url: url), verified.pageCount == pageCount else {
                throw ScanFailure(message: "Не удалось проверить сохранённый PDF.")
            }
            dirty = false; savedURL = url; status = "Сохранено: \(url.lastPathComponent)"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func allowClosing() -> Bool {
        if busy {
            let alert = NSAlert()
            alert.messageText = "Сканирование ещё идёт"
            alert.informativeText = "Дождитесь завершения или отмените сканирование кнопкой в окне."
            alert.addButton(withTitle: "Вернуться")
            alert.runModal(); return false
        }
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Сохранить отсканированные страницы?"
        alert.informativeText = "Несохранённые страницы будут потеряны после закрытия."
        alert.addButton(withTitle: "Сохранить…")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: dirty = false; return true
        default: return false
        }
    }
    func newDocument() {
        guard allowClosing() else { return }
        document = PDFDocument(); savedURL = nil; dirty = false; selectedPage = 0; revision = UUID()
        status = online ? "Готов к сканированию" : "Принтер недоступен"
    }
    func rotate() {
        guard !busy, let page = document.page(at: selectedPage) else { return }
        page.rotation = (page.rotation + 90) % 360
        dirty = true; revision = UUID()
    }
    func remove() {
        guard !busy, pageCount > 0 else { return }
        document.removePage(at: selectedPage)
        selectedPage = max(0, min(selectedPage, pageCount - 1)); dirty = true; revision = UUID()
        if pageCount == 0 { dirty = false }
    }
}

struct PDFPreview: NSViewRepresentable {
    @ObservedObject var model: ScanModel
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = .windowBackgroundColor
        model.pdfView = view
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.revision != model.revision {
            context.coordinator.rendering = true
            view.document = nil; view.document = model.document; view.autoScales = true
            if let page = model.document.page(at: model.selectedPage) { view.go(to: page) }
            context.coordinator.revision = model.revision
            context.coordinator.rendering = false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject {
        weak var model: ScanModel?
        var revision: UUID?
        var rendering = false
        init(model: ScanModel) { self.model = model }
        @objc func pageChanged(_ note: Notification) {
            guard !rendering, let model, let view = note.object as? PDFView,
                  let page = view.currentPage else { return }
            let index = model.document.index(for: page)
            if index != NSNotFound && index != model.selectedPage { model.selectedPage = index }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppArtwork.icon
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ScanModel.shared.allowClosing() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { ScanModel.shared.allowClosing() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct WindowHook: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = delegate }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.delegate = delegate }
}

struct ScanWindow: View {
    @ObservedObject var model: ScanModel
    @AppStorage("printerAddress") private var address = ""
    @AppStorage("printerName") private var name = "Ваш сетевой сканер"
    @AppStorage("colorScan") private var color = true
    @AppStorage("scanDPI") private var dpi = 300
    @AppStorage("fullGlass") private var fullGlass = false
    @State private var editingPrinter = false
    @State private var draftAddress = ""
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: AppArtwork.icon).resizable()
                        .interpolation(.high).frame(width: 64, height: 64)
                    Text("Локальный сканер").font(.title2.bold())
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Circle().fill(model.online ? Color.green : Color.gray).frame(width: 7, height: 7)
                        Text(model.online ? "Подключён · \(address)" : (address.isEmpty ? "Принтер не выбран" : address)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Настроить принтер…") { draftAddress = address; editingPrinter = true }.buttonStyle(.link).font(.caption)
                        .disabled(model.busy || model.checking)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Цвет").font(.headline)
                    Picker("Цвет", selection: $color) {
                        Text("Цветной").tag(true)
                        Text("Серый").tag(false)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Качество").font(.headline)
                    Picker("Качество", selection: $dpi) {
                        Text("200 dpi · быстро").tag(200)
                        Text("300 dpi · документы").tag(300)
                        Text("600 dpi · детали").tag(600)
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Область").font(.headline)
                    Picker("Область", selection: $fullGlass) {
                        Text("A4").tag(false)
                        Text("Всё стекло").tag(true)
                    }.labelsHidden()
                }
                Spacer(minLength: 8)
                if model.busy {
                    HStack { ProgressView().controlSize(.small); Text("Сканирование…").font(.subheadline) }
                    Button("Отменить сканирование") { model.cancel() }.frame(maxWidth: .infinity)
                } else {
                    Button { model.scan(color: color, dpi: dpi, fullGlass: fullGlass) } label: {
                        Label(model.pageCount == 0 ? "Сканировать" : "Добавить страницу", systemImage: "scanner")
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [])
                        .disabled(model.checking || !model.online)
                }
                Text("Положите документ на стекло лицевой стороной вниз и закройте крышку.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("Только домашняя сеть", systemImage: "house.fill").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(minWidth: 250, idealWidth: 280, maxWidth: 310)
                .background(Color(nsColor: .controlBackgroundColor))
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.savedURL?.lastPathComponent ?? "Новый документ").font(.headline).lineLimit(1)
                        Text(model.pageCount == 0 ? "Предпросмотр появится после сканирования" : "Страниц: \(model.pageCount)\(model.dirty ? " · не сохранено" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = model.savedURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                            .help("Показать сохранённый файл")
                    }
                    Button("Сохранить PDF…") { _ = model.save() }
                        .disabled(model.pageCount == 0 || model.busy).keyboardShortcut("s", modifiers: .command)
                }.padding(18)
                Divider()
                if model.pageCount == 0 {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.viewfinder").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text("Ваш документ появится здесь").font(.title3)
                        Text("Нажмите «Сканировать». Для нескольких страниц\nпереложите лист и нажмите «Добавить страницу».")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PDFPreview(model: model)
                    Divider()
                    HStack {
                        Button { if model.selectedPage > 0 { model.selectedPage -= 1; model.revision = UUID() } } label: { Image(systemName: "chevron.left") }
                            .disabled(model.selectedPage <= 0)
                        Text("\(model.selectedPage + 1) / \(model.pageCount)").monospacedDigit().frame(minWidth: 55)
                        Button { if model.selectedPage + 1 < model.pageCount { model.selectedPage += 1; model.revision = UUID() } } label: { Image(systemName: "chevron.right") }
                            .disabled(model.selectedPage + 1 >= model.pageCount)
                        Spacer()
                        Button { model.rotate() } label: { Label("Повернуть", systemImage: "rotate.right") }
                        Button { model.remove() } label: { Image(systemName: "trash") }.help("Удалить выбранную страницу")
                    }.padding(12).disabled(model.busy)
                }
                Divider()
                HStack {
                    Text(model.status).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Новый документ") { model.newDocument() }.disabled(model.busy || model.pageCount == 0)
                }.padding(12)
            }.frame(minWidth: 480)
        }
        .frame(minWidth: 820, minHeight: 640)
        .tint(Color(red: 0.12, green: 0.48, blue: 0.57))
        .onAppear {
            if ScanValidation.baseURL(address) == nil { draftAddress = address; editingPrinter = true; model.status = "Подключите принтер" }
            else { model.check() }
        }
        .sheet(isPresented: $editingPrinter) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ваш принтер").font(.title2.bold())
                Text(name).foregroundStyle(.secondary)
                TextField("Локальный IP-адрес", text: $draftAddress).textFieldStyle(.roundedBorder)
                Text("Укажите адрес сканера в домашней сети. После подключения адрес и сертификат сохранятся между запусками.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Сбросить привязку") { model.forgetCertificate() }.disabled(model.fingerprint == nil)
                    Spacer()
                    Button("Отмена") { editingPrinter = false }.keyboardShortcut(.cancelAction)
                    Button("Подключить") {
                        address = ScanValidation.baseURL(draftAddress.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? ""
                        editingPrinter = false; model.check()
                    }.keyboardShortcut(.defaultAction)
                        .disabled(ScanValidation.baseURL(draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                }
            }.padding(26).frame(width: 390)
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@main struct LocalScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Window("Локальный сканер", id: "main") {
            ScanWindow(model: .shared).background(WindowHook(delegate: appDelegate))
        }.defaultSize(width: 1000, height: 740)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Новый документ") { ScanModel.shared.newDocument() }.keyboardShortcut("n", modifiers: .command)
                        .disabled(ScanModel.shared.busy)
                }
            }
    }
}
