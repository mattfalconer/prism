import AppKit
import SwiftUI

/// Opens a new GitHub issue with the details that matter for Prism filled in. Nothing is sent until the
/// person submits the issue themselves.
enum ReportProblem {
    static func open() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let body = """
        **What happened?**


        **What were you listening to, and in which app?**


        ---
        Prism \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(sysctl("machdep.cpu.brand_string")), \(memory) GB · \(sysctl("hw.model"))
        """
        var components = URLComponents(string: "https://github.com/mattfalconer/prism/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct ReportProblemButton: View {
    var body: some View {
        Button("Report a Problem…") { ReportProblem.open() }
    }
}
