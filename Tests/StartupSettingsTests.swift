import AppKit
import Foundation

@MainActor
private final class FakeLoginItem: LoginItemManaging {
    var state: LoginItemState = .notRegistered
    var registrations = 0
    var removals = 0
    var settingsOpened = 0
    var nextState: LoginItemState = .enabled
    var failure: Error?
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        state = nextState
    }
    func unregister() throws {
        removals += 1
        if let failure { throw failure }
        state = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}

@main
struct StartupSettingsTests {
    @MainActor static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            precondition(condition(), message)
        }
        let service = FakeLoginItem()
        let settings = StartupSettings(service: service)
        check(!settings.registered && service.registrations == 0, "启动不自动注册登录项")
        settings.setEnabled(true)
        check(settings.state == .enabled && settings.registered, "从真实服务状态确认开启")
        settings.setEnabled(true)
        check(service.registrations == 1, "不重复注册")
        settings.setEnabled(false)
        check(!settings.registered && service.removals == 1, "可关闭登录项")
        settings.setEnabled(false)
        check(service.removals == 1, "不重复注销")
        service.nextState = .requiresApproval
        settings.setEnabled(true)
        check(settings.state == .requiresApproval && settings.registered, "保留待批准状态而非冒充已启用")
        check(settings.menuTitle.contains("等待系统允许") && settings.notice != nil, "显示系统批准指引")
        settings.openSystemSettings()
        check(service.settingsOpened == 1, "登录项设置入口")
        settings.setEnabled(false)
        check(!settings.registered, "待批准的申请也能取消")
        service.failure = NSError(domain: "Test", code: 5, userInfo: [NSLocalizedDescriptionKey: "拒绝注册"])
        settings.setEnabled(true)
        check(!settings.registered && settings.notice?.contains("拒绝注册") == true, "注册失败不能保存虚假的开启状态")
        service.failure = nil
        service.state = .enabled
        settings.refresh()
        check(settings.registered, "跟随系统外部开启")
        service.failure = NSError(domain: "Test", code: 6)
        settings.setEnabled(false)
        check(settings.registered && settings.notice != nil, "注销失败保留实际启用状态")
        service.state = .notRegistered
        settings.refresh()
        check(!settings.registered && service.registrations == 3, "系统关闭后不偷偷重新注册")
        service.failure = nil
        service.state = .notFound
        service.nextState = .enabled
        settings.refresh()
        check(!settings.registered, "未发现登录项时视为关闭")
        settings.setEnabled(true)
        check(settings.state == .enabled, "首次没有登录项也可发起注册")
        check(!StartupPolicy.shouldShowPanel(force: false, firstLaunch: false, preferred: false), "默认后续启动静默驻留")
        check(StartupPolicy.shouldShowPanel(force: true, firstLaunch: false, preferred: false), "手动强制展开")
        check(StartupPolicy.shouldShowPanel(force: false, firstLaunch: true, preferred: false), "首次启动指引")
        check(StartupPolicy.shouldShowPanel(force: false, firstLaunch: false, preferred: true), "启动展开偏好生效")
        print("PASS: \(count) startup settings checks — registration / approval / errors / external changes / launch behavior")
    }
}
