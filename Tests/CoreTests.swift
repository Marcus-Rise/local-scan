import Foundation
import PDFKit

@main struct CoreTests {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let data = try ScanOptions().xml()
        let doc = try? XMLDocument(data: data)
        func value(_ path: String) -> String? { (try? doc?.nodes(forXPath: path))?.first?.stringValue }
        check(value("//*[local-name()='ColorMode']") == "RGB24", "default scan requests actual RGB color")
        check(value("//*[local-name()='XResolution']") == "300", "default resolution is 300 dpi")
        check(value("//*[local-name()='ScanRegions']") != nil && (try? doc?.nodes(forXPath: "//*[local-name()='ScanRegions']"))?.first?.uri == "http://www.pwg.org/schemas/2010/12/sm", "scan region uses PWG namespace")
        check(value("//*[local-name()='ContentRegionUnits']") == "escl:ThreeHundredthsOfInches", "physical size units are explicit")
        check(value("//*[local-name()='Width']") == "2480" && value("//*[local-name()='Height']") == "3508", "A4 physical area")
        var gray = ScanOptions(); gray.color = false; gray.fullGlass = true; gray.dpi = 600
        let grayXML = String(data: try gray.xml(), encoding: .utf8) ?? ""
        check(grayXML.contains("Grayscale8") && grayXML.contains(">2550<") && grayXML.contains(">600<"), "grayscale and full-glass options")
        var invalid = ScanOptions(); invalid.dpi = 1200
        check((try? invalid.xml()) == nil, "unsupported resolution is rejected")
        let base = URL(string: "https://192.168.1.50/eSCL/")!
        check(ScanValidation.baseURL("192.168.1.50") == base, "printer private address accepted")
        check(ScanValidation.baseURL("8.8.8.8") == nil && ScanValidation.baseURL("127.0.0.1") == nil && ScanValidation.baseURL("192.168.1.50/evil") == nil, "public, loopback and URL-injection addresses rejected")
        let pin = String(repeating: "a", count: 64)
        check(PrinterTrust.matches(pin, expected: pin), "paired certificate accepted")
        check(!PrinterTrust.matches(pin, expected: nil), "unpaired certificate rejected")
        check(!PrinterTrust.matches(pin, expected: String(repeating: "b", count: 64)), "changed certificate rejected")
        check(!PrinterTrust.matches("", expected: ""), "empty certificate pin rejected")
        check(ScanValidation.jobURL("/eSCL/ScanJobs/test-1", base: base)?.path == "/eSCL/ScanJobs/test-1", "relative job URL accepted")
        check(ScanValidation.jobURL("https://192.168.1.50:443/eSCL/ScanJobs/test-1", base: base) != nil, "device's explicit HTTPS port accepted")
        for bad in ["https://example.com/eSCL/ScanJobs/x", "http://192.168.1.50/eSCL/ScanJobs/x", "/admin", "/eSCL/ScanJobs/x/NextDocument", "/eSCL/ScanJobs/%2e%2e", "https://user@192.168.1.50/eSCL/ScanJobs/x", "/eSCL/ScanJobs/x?secret=y"] {
            check(ScanValidation.jobURL(bad, base: base) == nil, "unsafe job URL rejected: \(bad)")
        }
        check(ScanValidation.pdf(Data("<html>error</html>".utf8)) == nil, "HTML is never accepted as a successful scan")
        check(ScanValidation.pdf(Data("%PDF-1.4\nnot a PDF".utf8)) == nil, "truncated PDF is rejected")
        let fixture = PDFDocument()
        let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        fixture.insert(page, at: 0)
        check(fixture.dataRepresentation().flatMap(ScanValidation.pdf)?.pageCount == 1, "valid PDF accepted")
        if CommandLine.arguments.count > 1 {
            let valid = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            check(ScanValidation.pdf(valid) != nil, "real printer PDF accepted")
        }
        if failures > 0 { print("\(failures) failed"); exit(1) }
    }
}
