import Foundation
@main struct LiveProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            print("Usage: live-probe PRIVATE_IP SHA256_CERTIFICATE_PIN OUTPUT.pdf")
            exit(2)
        }
        let client = try ScannerClient(address: CommandLine.arguments[1], fingerprint: CommandLine.arguments[2])
        print(try await client.check())
        let data = try await client.scan(ScanOptions())
        let output = CommandLine.arguments[3]
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Saved color scan: \(data.count) bytes")
    }
}
