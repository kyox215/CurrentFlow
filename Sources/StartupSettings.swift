import AppKit
import Combine
import ServiceManagement

enum LoginItemState: String {
    case notRegistered, enabled, requiresApproval, notFound
    var registered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemManaging {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
struct SystemLoginItem: LoginItemManaging {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws {
        let path = Bundle.main.bundleURL.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            throw NSError(domain: "CurrentFlow.Startup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "请先将 App 拖入“应用程序”文件夹，从那里打开后再开启开机自启。"])
        }
        try SMAppService.mainApp.register()
    }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum StartupPolicy {
    static let showOnLaunchKey = "showPanelOnLaunch"
    static func shouldShowPanel(force: Bool, firstLaunch: Bool, preferred: Bool) -> Bool {
        force || firstLaunch || preferred
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    @MainActor static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "电流脉动",
            .applicationVersion: version,
            .credits: NSAttributedString(string: "实时功耗与供电流向\n电源 · 主板 · 电池\nmacOS 13+ · Apple Silicon")
        ])
    }
}

@MainActor
final class StartupSettings: ObservableObject {
    @Published private(set) var state: LoginItemState
    @Published var notice: String?
    private let service: any LoginItemManaging

    init(service: (any LoginItemManaging)? = nil) {
        let resolved = service ?? SystemLoginItem()
        self.service = resolved
        self.state = resolved.state
    }

    var registered: Bool { state.registered }
    var menuTitle: String { state == .requiresApproval ? "开机自启 · 等待系统允许" : "开机自启" }

    func refresh() { state = service.state }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != registered else { return }
        notice = nil
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            refresh()
            if state == .requiresApproval {
                notice = "macOS 正在等待你允许登录项。请在系统设置的“登录项”中允许电流脉动，之后登录时会自动启动。"
            } else if enabled && state != .enabled {
                notice = "系统尚未启用登录项。请先把 App 放到“应用程序”文件夹，再重试。"
            }
        } catch {
            refresh()
            if state == .requiresApproval {
                notice = "登录项需要系统允许。请在系统设置的“登录项”中允许电流脉动。"
            } else {
                notice = "未能\(enabled ? "开启" : "关闭")开机自启。系统提示：\(error.localizedDescription)"
            }
        }
    }

    func openSystemSettings() { service.openSettings() }
}
