import AppKit
import Foundation

/// 浮窗该跟哪个 DSH 说话。
///
/// 0.2.2 之前只有一个答案：本机 3080 端口上那个 `dsh web`。
/// 于是所有判断都写死成「3080 有没有在听」，所有跳转都拼
/// `http://127.0.0.1:3080` —— 一旦用户改用桌面版（DeepSeek Harness.app），
/// 浮窗还对着浏览器那个使劲：状态灯认错了人，「新的对话」把消息递给了
/// 另一个实例，截图提问也一样。
///
/// 这里是那件事的唯一出口。别处一律调它，不再各自探测端口。
///
/// ── 两种宿主 ────────────────────────────────────────────────
///   · web   —— `dsh web`，监听 3080（端口由 dsh-launcher 脚本决定）。
///              地址带 token，存在 ~/.dsh/web.url 里，能直接开浏览器。
///   · desktop —— DeepSeek Harness.app，监听一个随机高位端口，
///              界面是自定义协议 dsh-app://app/，**拼不出可用的网址**。
///              只能把自己唤到前台（dsh://open），不能指定会话。
///
/// 拼不出网址不是缺陷，是它的设计：桌面版渲染进程走
/// forwardWebRequest(request, hostUrl, hostCookie)，会话完全在客户端
/// 内部状态里，网址里没有会话段。
@MainActor
enum HostTarget: String, CaseIterable {

    /// 本机 `dsh web`（npm 版），3080 端口。
    case web
    /// DeepSeek Harness 桌面应用。
    case desktop

    /// 菜单上显示的名字。
    var title: String {
        switch self {
        case .web: return "网页版"
        case .desktop: return "桌面版"
        }
    }

    /// 探测不到时给用户看的一句话。
    var notRunningHint: String {
        switch self {
        case .web: return "没找到网页版 DSH（3080 端口没有在听）"
        case .desktop: return "没找到桌面版 DSH（DeepSeek Harness 没在运行）"
        }
    }

    // MARK: - 探测

    /// 桌面版的 bundle id。用 bundle id 而不是进程名：
    /// 改名了也还认得出，而进程名会随版本变（现在是 "DeepSeek Harness"）。
    static let desktopBundleID = "com.deepseek.dsh"

    /// `dsh web` 固定在这个端口（dsh-launcher 脚本与 web.url 都按它写）。
    ///
    /// nonisolated：App 的重启流程在 Task.detached 里等端口释放，
    /// 那里不在主 actor 上，拿不到 MainActor 隔离的静态量。
    nonisolated static let webPort: UInt16 = 3080

    /// 这个宿主当前是否在跑。
    ///
    /// 桌面版只问 LaunchServices，不去扫端口 —— 它的端口是随机的
    /// （实测 50788，每次启动都可能不同），按端口猜必然出错。
    var isRunning: Bool {
        switch self {
        case .web:
            return ProcessManager.isPortListening(Self.webPort)
        case .desktop:
            return !NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.desktopBundleID).isEmpty
        }
    }

    /// 当前真正可用的是哪个（两者都在跑时按优先级挑一个）。
    ///
    /// 桌面版优先：两者并存时用户更可能是在桌面版里说话 ——
    /// 那是他特意装的那一个，网页版更像顺手起的。
    static func runningNow() -> HostTarget? {
        if HostTarget.desktop.isRunning { return .desktop }
        if HostTarget.web.isRunning { return .web }
        return nil
    }

    // MARK: - 打开界面

    /// 把 DSH 的界面带到用户眼前。**不负责启动** ——
    /// 要不要拉起由 AppDelegate 决定（它知道该走启动器还是 open）。
    ///
    /// 返回是否成功。失败时调用方负责告诉用户为什么。
    @discardableResult
    func reveal() -> Bool {
        switch self {
        case .web:
            // 有活着的认证 URL 就开它（带 token，能直达）；
            // 没有只能开裸地址，用户可能撞上 401。
            if let live = DSHLauncher.liveAuthenticatedURL() {
                NSWorkspace.shared.open(live)
                return true
            }
            guard let bare = URL(string: "http://127.0.0.1:\(Self.webPort)") else { return false }
            NSWorkspace.shared.open(bare)
            return true

        case .desktop:
            // 桌面版只有一条路：把自己唤到前台。
            //
            // 用 dsh://open 而不是 open -b：两者都能激活（实测 PID 都不变），
            // 但深链走宿主自己注册的 open-url 处理，它会 restore + show +
            // focus 主窗口；open -b 只让 LaunchServices 激活 app，
            // 窗口被最小化时不一定弹回来。
            guard let url = URL(string: "dsh://open") else { return false }
            return NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 与插件对话

    /// 交给插件的那一侧标识。
    ///
    /// 插件的 reply 文件认这个字段：只有 `target` 与自己所在
    /// profile 对得上才消费这条消息。两个 profile 同时装着插件是常态
    /// （desktop 与 web 各一份），没有这个字段就会两个 poller 抢同一条 ——
    /// 点一次「新的对话」建出两个会话。
    var pluginTarget: String {
        switch self {
        case .web: return "web"
        case .desktop: return "desktop"
        }
    }
}
