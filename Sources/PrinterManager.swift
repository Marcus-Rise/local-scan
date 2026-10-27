import SwiftUI

struct PrinterManager: View {
    @ObservedObject var model: ScanModel
    @ObservedObject var store: PrinterStore
    @StateObject private var discovery = PrinterDiscovery()
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: SavedPrinter?
    @State private var deleting: SavedPrinter?
    @State private var resetting: SavedPrinter?
    @State private var manual = false
    @State private var draftName = ""
    @State private var draftAddress = ""
    @State private var formError: String?
    private let accent = Color(red: 0.12, green: 0.48, blue: 0.57)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if editing != nil { editor }
                    else if adding { discoveryContent }
                    else { library }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack {
                Label("Только ваша локальная сеть", systemImage: "network")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }.controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: 720, height: 650).tint(accent)
        .onAppear { discovery.start(); adding = store.printers.isEmpty }
        .onDisappear { discovery.stop() }
        .confirmationDialog("Сбросить привязку?", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), titleVisibility: .visible) {
            Button("Сбросить привязку", role: .destructive) {
                if let printer = resetting { model.forgetCertificate(for: printer.address) }
                resetting = nil
            }
            Button("Отмена", role: .cancel) { resetting = nil }
        } message: { Text("При следующем подключении к этому принтеру потребуется снова подтвердить его сертификат.") }
        .confirmationDialog("Удалить принтер?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let printer = deleting {
                    let selected = store.selectedAddress == printer.address
                    store.remove(printer)
                    if selected { model.online = false; model.connectionError = nil; model.status = "Выберите принтер" }
                }
                deleting = nil
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        } message: { Text("\(deleting?.name ?? "") будет удалён из сохранённых устройств. Его можно добавить снова.") }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: editing != nil ? "slider.horizontal.3" : (adding ? "plus.viewfinder" : "printer.fill"))
                .font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                .frame(width: 56, height: 56).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(editing != nil ? "Изменить принтер" : (adding ? "Добавить принтер" : "Принтеры"))
                    .font(.system(size: 25, weight: .semibold))
                Text(editing != nil ? "Имя для вас и адрес устройства в сети" : (adding ? "Найдите устройство в сети или укажите его адрес" : "Выберите принтер для сканирования"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if adding || editing != nil {
                Button("К списку") { adding = false; editing = nil; formError = nil }
                    .controlSize(.large).disabled(model.checking)
            } else {
                Button { adding = true; manual = false; draftName = ""; draftAddress = ""; formError = nil } label: {
                    Label("Добавить", systemImage: "plus")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.checking)
            }
        }.padding(28)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Мои принтеры").font(.headline); Text("\(store.printers.count)").foregroundStyle(.secondary); Spacer() }
            if store.printers.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "printer").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Добавьте первый принтер").font(.title3.weight(.semibold))
                    Text("Приложение найдёт доступные сканеры в вашей сети.").foregroundStyle(.secondary)
                    Button("Найти принтер") { adding = true }.buttonStyle(.borderedProminent).controlSize(.large)
                }.frame(maxWidth: .infinity).padding(.vertical, 45)
            }
            ForEach(store.printers) { printer in savedCard(printer) }
        }
    }

    private func savedCard(_ printer: SavedPrinter) -> some View {
        let selected = store.selectedAddress == printer.address
        let connecting = model.checking && model.connectionAddress == printer.address
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "printer.fill").font(.system(size: 25)).foregroundStyle(selected ? accent : .secondary)
                    .frame(width: 46, height: 46).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(printer.name).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                    Text(printer.address).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if connecting { ProgressView().controlSize(.small); Text("Подключение…").font(.callout).foregroundStyle(.secondary) }
                else if selected {
                    Label(model.online ? "Подключён" : "Выбран · нет связи", systemImage: model.online ? "checkmark.circle.fill" : "circle.inset.filled")
                        .font(.callout.weight(.medium)).foregroundStyle(model.online ? .green : accent)
                }
            }
            if selected, let error = model.connectionError {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { store.select(printer); model.check(targetAddress: printer.address) } label: {
                    Text(selected ? "Проверить связь" : "Выбрать").frame(minWidth: 110)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Изменить") { editing = printer; draftName = printer.name; draftAddress = printer.address; formError = nil }
                    .controlSize(.large)
                Spacer()
                Button("Удалить", role: .destructive) { deleting = printer }.controlSize(.large)
            }.disabled(model.checking || model.busy)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? accent.opacity(0.65) : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 1))
    }

    private var discoveryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Найдены в сети").font(.headline)
                Spacer()
                if discovery.searching && discovery.printers.isEmpty { ProgressView().controlSize(.small) }
                Button { discovery.start() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .controlSize(.large).disabled(model.checking)
            }
            if discovery.printers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 34)).foregroundStyle(accent)
                    Text(discovery.failure == nil ? (discovery.searching ? "Ищем сканеры рядом" : "Пока ничего не найдено") : "Поиск недоступен").font(.headline)
                    Text(discovery.failure ?? "Включите принтер и подключите его к вашей сети. Устройства появятся здесь автоматически.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
                }.frame(maxWidth: .infinity).padding(28).background(.background, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(discovery.printers) { printer in
                let saved = store.printers.contains { $0.address == printer.address }
                HStack(spacing: 14) {
                    Image(systemName: "printer").font(.system(size: 25)).foregroundStyle(accent).frame(width: 42)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(printer.name).font(.system(size: 16, weight: .semibold))
                        Text(printer.address).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if saved { Label("Добавлен", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    else {
                        Button("Добавить") { add(name: printer.name, address: printer.address) }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.checking || model.busy)
                    }
                }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 16))
            }
            if let formError { Text(formError).foregroundStyle(.red).font(.callout) }
            Divider().padding(.vertical, 6)
            if manual { manualForm }
            else {
                Button { manual = true; draftName = ""; draftAddress = ""; formError = nil } label: {
                    HStack { Label("Добавить по IP-адресу", systemImage: "network"); Spacer(); Image(systemName: "chevron.right") }
                        .padding(8)
                }.controlSize(.large).frame(maxWidth: .infinity)
            }
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить по IP-адресу").font(.headline)
            fields
            Button("Добавить принтер") { add(name: draftName, address: draftAddress) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(ScanValidation.baseURL(draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || model.checking || model.busy)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Название").font(.callout.weight(.medium))
                TextField("Например, Домашний HP", text: $draftName).textFieldStyle(.roundedBorder).controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("IP-адрес в локальной сети").font(.callout.weight(.medium))
                TextField("192.168.1.50", text: $draftAddress).textFieldStyle(.roundedBorder).controlSize(.large)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            fields
            if let formError { Text(formError).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { editing = nil; formError = nil }.controlSize(.large)
                Spacer()
                Button("Сохранить изменения") {
                    guard let original = editing else { return }
                    do {
                        let selected = store.selectedAddress == original.address
                        let printer = try store.save(name: draftName, address: draftAddress, replacing: original.id)
                        editing = nil; adding = false; formError = nil
                        if selected && printer.address != original.address { model.check(targetAddress: printer.address) }
                    } catch { formError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(ScanValidation.baseURL(draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || model.checking)
            }
            if let printer = editing {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Привязка к устройству").font(.callout.weight(.medium))
                        Text("Если у принтера изменился сертификат").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Сбросить привязку") { resetting = printer }.controlSize(.large)
                        .disabled((UserDefaults.standard.dictionary(forKey: "printerCertificates") as? [String: String])?[printer.address] == nil)
                }
            }
        }.padding(24).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func add(name: String, address: String) {
        do {
            let printer = try store.save(name: name, address: address)
            store.select(printer)
            adding = false; manual = false; formError = nil
            model.check(targetAddress: printer.address)
        } catch { formError = error.localizedDescription }
    }
}
