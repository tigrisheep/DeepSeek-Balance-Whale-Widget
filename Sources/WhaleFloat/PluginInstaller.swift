import AppKit
import Foundation

/// 随包发布的中介插件（目录名）。
///
/// 0.2.1 起职责反过来了：
///
/// 之前是「app 装好之后，顺手把插件塞进 DSH」——
/// 那时插件没上架，用户只能靠 app 自带的那一份。
/// 现在插件先在 Harness 插件市场里装，再由**插件**负责把 app 装好，
/// 于是这里要退成「只检查、不乱动」：
///
///   · 插件已经由市场装过（~/.dsh/plugins 或 profile/node_modules 里有一份）
///     → 一个字都不要写，那是用户的、也是能自动升级的那个；
///   · 插件完全没有 → 才用包里自带的那份兜底。
///     这是纯离线机器或市场抽风时唯一的活路，不能不给。
///
/// 不这么做的话，两条安装路径会互相覆盖：
/// 用户从市场升级到 0.2.2，一开浮窗，app 又把包里的 0.2.1 盖回去，
/// 表现就是「升了级没变化」，而且没有任何报错可看。
@MainActor
enum PluginInstaller {
    static let bundled = ["dsh-whalefloat-helper"]

    /// 已废弃的旧插件名。启动时顺手摘掉，避免用户升级后两套并存。
    static let legacy = ["dsh-wait-state", "dsh-turn-usage", "dsh-notify-bridge"]

    /// 插件的人类可读说明（用于安装提示）。
    static let descriptions: [String: String] = [
        "dsh-wait-state": "等用户回答 / 授权时，让浮窗冒泡提示",
        "dsh-turn-usage": "采集每轮对话消耗，供浮窗显示¥金额",
        "dsh-whalefloat-helper": "等待提示 / 每轮消耗 / 系统通知 / 拖图解题，四合一中介",
    ]
    static var pluginsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/plugins", isDirectory: true)
    }

    /// DSH 各 profile 的根目录。插件可能被装在任意一个 profile 下，
    /// 不能只看 web —— 用户完全可能只在 desktop 里用。
    static var profilesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles", isDirectory: true)
    }

    static var allProfiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: profilesDir, includingPropertiesForKeys: nil)) ?? []
    }

    /// 市场装的插件长什么样：某 profile 的 node_modules 里有这个包。
    ///
    /// 这是首选判据。plugin add 与插件市场都会把包装进 profile 的
    /// node_modules 并写进该 profile 的 package.json —— 那才是 DSH
    /// 真正加载的那一份，也是下次升级时会被替换的那一份。
    static func installedByMarket(_ name: String) -> Bool {
        allProfiles.contains { profile in
            let pkg = profile
                .appendingPathComponent("node_modules")
                .appendingPathComponent(name)
                .appendingPathComponent("package.json")
            return FileManager.default.fileExists(atPath: pkg.path)
        }
    }

    /// app 自带的兜底安装留下的痕迹：~/.dsh/plugins 下有源目录。
    static func installedByBundle(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent(name + "/index.js").path)
    }

    /// 这个插件是否**已经有人在管**（不管是谁装的）。
    ///
    /// 只要有人管，app 就不该再动它 —— 尤其是市场装的那份，
    /// 覆盖它等于把用户的升级路堵死。
    static func isInstalled(_ name: String) -> Bool {
        installedByMarket(name) || installedByBundle(name)
    }

    /// app 内置插件的来源目录。
    ///
    /// 0.2.1 起包里**不再附插件**（它已经上架，由市场分发）。
    /// 这个目录留着是为了兼容：万一以后又需要随包带，
    /// 或者有人用旧包装了新 app，逻辑不用改。
    static var bundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("plugins", isDirectory: true)
    }

    /// 包里到底有没有这个插件，有才能兜底装。
    static func hasBundled(_ name: String) -> Bool {
        guard let base = bundledDir else { return false }
        return FileManager.default.fileExists(
            atPath: base.appendingPathComponent(name).appendingPathComponent("index.js").path)
    }

    /// 还需要 app 兜底装的插件：市场没装、而包里恰好有一份。
    ///
    /// 包里没有就返回空 —— 「没得装」和「还没装」是两件事，
    /// 混在一起会让每次启动都白跑一趟，还打出一句找不到目录的日志。
    static func missing() -> [String] {
        bundled.filter { !isInstalled($0) && hasBundled($0) }
    }
    /// 兜底安装：把包里那份复制到 ~/.dsh/plugins/。
    ///
    /// **不碰任何 profile 的 package.json，也不调 dsh plugin add。**
    /// 注册这件事交给 DSH 启动时的扫描与用户自己 —— 这里硬写
    /// file: 依赖进去，会跟市场装的那份在同一个 profile 里打架。
    static func install(_ names: [String]) -> String {
        guard let src = bundledDir else { return "找不到内置插件目录" }
        let fm = FileManager.default
        var copied: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        for name in names {
            // 市场已经装了就不动 —— 哪怕包里这份更新也不行。
            // 用户从市场升级到新版后，这里若还按「内容不同」去覆盖，
            // 就变成了降级，而且他无从察觉。
            if installedByMarket(name) {
                skipped.append(name + "（已由插件市场安装，未改动）")
                continue
            }
            let from = src.appendingPathComponent(name)
            let to = pluginsDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else {
                failed.append(name + "（包内缺失）")
                continue
            }
            do {
                try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
                copied.append(name)
            } catch {
                failed.append(name + "（" + error.localizedDescription + "）")
            }
        }

        var lines: [String] = []
        if !copied.isEmpty {
            lines.append("已复制 \(copied.count) 个插件到 ~/.dsh/plugins/")
            lines.append("把下面这几行加进 ~/.dsh/profiles/<profile>/package.json 的 dsh.profile.bundles，再重启 DSH：")
            for name in copied { lines.append("  · " + name) }
        }
        lines.append(contentsOf: skipped)
        if !failed.isEmpty { lines.append("未完成：" + failed.joined(separator: "、")) }
        if copied.isEmpty && skipped.isEmpty && failed.isEmpty {
            lines.append("没有需要处理的插件。")
        }
        return lines.joined(separator: "\n")
    }
    /// 摘掉已废弃的旧插件（升级时清理用）。
    static func removeLegacy() {
        guard let dsh = dshExecutable else { return }
        for name in legacy where isInstalled(name) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dsh)
            p.arguments = ["plugin", "--profile", "web", "remove", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            try? FileManager.default.removeItem(
                at: pluginsDir.appendingPathComponent(name))
            NSLog("WhaleFloat: 已移除旧插件 \(name)")
        }
    }

    /// dsh 可执行文件的位置（摘插件时要调它）。
    private static var dshExecutable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/.npm-global/bin/dsh",
            home + "/.local/bin/dsh",
            "/usr/local/bin/dsh",
            "/opt/homebrew/bin/dsh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 从 DSH 的 profile 里摘除本程序带的插件（卸载时用）。
    ///
    /// 这里刻意只摘 ~/.dsh/plugins 下那份（app 自己装的），
    /// **不碰市场装进 profile/node_modules 的那份** —— 卸载浮窗
    /// 不该顺手把用户从市场装的插件也删了，那是他的东西。
    static func removeAllQuietly() {
        let fm = FileManager.default
        for name in bundled + legacy {
            try? fm.removeItem(at: pluginsDir.appendingPathComponent(name))
        }
    }
    /// 用户主动点菜单时的安装 —— 这条路径可以弹框，
    /// 因为是他自己点的，反馈是必要的。
    static func installWithFeedback() {
        let missing = self.missing()
        let alert = NSAlert()
        if missing.isEmpty && !bundled.contains(where: { isInstalled($0) }) {
            // 既没装、包里也没有 —— 这种情况只有一个可能：
            // 用户跳过了插件市场那一步。直接告诉他去哪儿拿。
            alert.messageText = "还没有安装配套插件"
            alert.informativeText = bundled
                .map { "  · " + $0 + " —— " + (descriptions[$0] ?? "") }
                .joined(separator: "\n")
            + "\n\n在 DSH 的插件市场里搜 whalefloat 装上即可；"
            + "\n装好后重启 DSH，等待提示、每轮消耗这些才会出现。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        if missing.isEmpty {
            alert.messageText = "配套插件都齐了"
            let who = bundled.map { name -> String in
                let how = installedByMarket(name) ? "插件市场安装" : "本程序自带"
                return "  · " + name + "（" + how + "）—— " + (descriptions[name] ?? "")
            }
            alert.informativeText = who.joined(separator: "\n")
                + "\n\n如果浮窗没反应，多半是还没重启 DSH。"
            alert.addButton(withTitle: "好")
        } else {
            alert.messageText = "安装 \(missing.count) 个配套插件"
            alert.informativeText = missing
                .map { "  · " + $0 + " —— " + (descriptions[$0] ?? "") }
                .joined(separator: "\n")
            + "\n\n装到 ~/.dsh/plugins/，装完需要重启一次 DSH。"
            alert.addButton(withTitle: "安装")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let result = install(missing)
            let done = NSAlert()
            done.messageText = "安装结果"
            done.informativeText = result
            done.addButton(withTitle: "好")
            done.runModal()
            return
        }
        alert.runModal()
    }

    /// 启动时补齐缺失的插件。
    ///
    /// **不弹模态框**。之前这里是 runModal()，会阻塞主线程 ——
    /// 自动化流程（或任何后台操作）碰上它就停住了。
    ///
    /// 0.2.1 起只在「压根没有」时动手：市场装过就一律跳过，
    /// 免得把用户刚升上去的版本又盖回包里这份。
    @discardableResult
    static func installMissingQuietly() -> String? {
        let missing = self.missing()
        guard !missing.isEmpty else { return nil }
        let result = install(missing)
        NSLog("WhaleFloat: 兜底安装插件 → \(result)")
        return result
    }
}
