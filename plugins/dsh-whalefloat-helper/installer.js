/**
 * WhaleFloat 安装器 —— 插件里那份内嵌安装包的落地逻辑。
 *
 * 为什么内嵌而不是从 GitHub 下载：user 装完插件点一下就能得到 app，
 * 不需要网络，也不会因为仓库改名 / release 被删 / 代理阻断而失效。
 * 体积可控：app 打完 tar.gz 约 2.5 MB，发到 npm 完全承受得起。
 *
 * 为什么用 tar.gz 而不是 zip：macOS 自带 bsdtar，解 tar.gz 不碰第三方依赖，
 * 也不会在解开时丢掉可执行位（zip 需要额外 chmod，漏了就是「打开就闪退」）。
 *
 * 所有外部命令都用 execFile 直接调，不拼 shell 字符串 ——
 * 路径里可能有空格，拼字符串必然出事。
 */

import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

export const APP_NAME = "WhaleFloat";
export const BUNDLE_ID = "ai.dsh.whalefloat";

/**
 * 安装目标。
 *
 * 正常情况就是 /Applications —— 普通用户对它可写，不需要 sudo。
 * 环境变量只给自测用：把整条安装链路跑到临时目录里，验证完再清掉，
 * 不去动开发机上那份正在用的 app。
 */
export const APP_PATH = process.env.WHALEFLOAT_APP_PATH || "/Applications/" + APP_NAME + ".app";
const TARBALL = "WhaleFloat.app.tar.gz";

/** 一次安装最多跑多久：解包 3 MB 不该超过这个数。 */
const INSTALL_TIMEOUT_MS = 120000;

/** 安装包所在目录（随插件一起发布）。 */
function assetsDir(here) {
	return path.join(here, "assets");
}

function log(msg) {
	try {
		fs.appendFileSync("/tmp/whalefloat-helper.log",
			new Date().toISOString() + " [install] " + msg + "\n");
	} catch {
		/* 写日志失败不影响主流程 */
	}
}

/** 读 .app 的版本号。读不到返回空串。 */
export function installedVersion() {
	try {
		const plist = path.join(APP_PATH, "Contents", "Info.plist");
		const raw = fs.readFileSync(plist, "utf8");
		const m = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]*)<\/string>/.exec(raw);
		return m ? m[1].trim() : "";
	} catch {
		return "";
	}
}

/** 插件内嵌的版本号。安装包旁边放一份 version.txt，打包脚本负责写。 */
export function bundledVersion(here) {
	try {
		const v = fs.readFileSync(path.join(assetsDir(here), "version.txt"), "utf8");
		return v.trim();
	} catch {
		return "";
	}
}

/** 当前是否装着。 */
export function isInstalled() {
	return fs.existsSync(path.join(APP_PATH, "Contents", "Info.plist"));
}

/**
 * app 是否正在跑。
 *
 * 必须按**这份安装路径**去匹配，不能只看进程名：
 * 开发机上常常同时有好几份副本（/tmp 里试装的、
 * 旧版留下的），只看名字会把别处的进程当成自己的，
 * 然后去「退出」一个根本不存在的实例。
 *
 * pgrep 找不到时退出码是 1，这里就当「没在跑」。
 */
export async function isRunning() {
	try {
		const pattern = APP_PATH + "/Contents/MacOS/" + APP_NAME;
		const { stdout } = await run("/usr/bin/pgrep", ["-f", pattern]);
		const pids = String(stdout).trim();
		if (pids === "") return false;
		// pgrep -f 匹配的是完整命令行：用 -f 时参数是正则，
		// 路径里的 . 与 + 会被当元字符，实际上反而宽松了；
		// 如果要严格，拿到 pid 后还得比一次路径。先用它初筛。
		return true;
	} catch {
		return false;
	}
}

/** 当前状态，给界面用。 */
export async function status(here) {
	const installed = isInstalled();
	return {
		platform: process.platform,
		supported: process.platform === "darwin",
		installed,
		installedVersion: installed ? installedVersion() : "",
		bundledVersion: bundledVersion(here),
		running: installed ? await isRunning() : false,
		appPath: APP_PATH,
		hasBundle: fs.existsSync(path.join(assetsDir(here), TARBALL)),
	};
}
/**
 * 装一遍。
 *
 * 步骤和 install.sh / README 里那套手动流程一致，只是把「下载」换成
 * 「从包内解出来」：
 *   1. 解到临时目录（不在 /Applications 里做半成品）
 *   2. 干掉正在跑的实例
 *   3. 移除旧版本、拷进 /Applications
 *   4. 去隔离属性（否则 Gatekeeper 弹「无法验证开发者」）
 *   5. 起它
 *
 * 任何一步失败都把真实原因抛出去，调用方原样展示 —— 用户看到的应该是
 * 「磁盘满了」而不是一句「安装失败」。
 */
export async function install(here, options) {
	const force = options && options.force === true;
	// 自测时不该真的把 app 弹到屏幕上
	const launch = !(options && options.launch === false);

	if (process.platform !== "darwin") {
		throw new Error("WhaleFloat 是 macOS 应用，这个平台装不了。");
	}

	const tar = path.join(assetsDir(here), TARBALL);
	if (!fs.existsSync(tar)) {
		throw new Error("插件里没有内嵌安装包（assets/" + TARBALL + "），这份插件可能打包不完整。");
	}

	const already = isInstalled();
	const wantVersion = bundledVersion(here);
	const haveVersion = already ? installedVersion() : "";
	if (already && !force) {
		// 版本读不到时按「已经是同一份」处理：重装没有收益，
		// 而覆盖安装会打断正在运行的浮窗。
		if (!wantVersion || wantVersion === haveVersion) {
			return {
				changed: false,
				reason: "already-installed",
				version: haveVersion,
				running: await isRunning(),
			};
		}
	}

	const stage = fs.mkdtempSync(path.join(os.tmpdir(), "whalefloat-"));
	try {
		log("解包到 " + stage);
		await run("/usr/bin/tar", ["-xzf", tar, "-C", stage], { timeout: INSTALL_TIMEOUT_MS });

		const src = path.join(stage, APP_NAME + ".app");
		if (!fs.existsSync(path.join(src, "Contents", "Info.plist"))) {
			throw new Error("安装包里没找到 " + APP_NAME + ".app，包可能损坏。");
		}

		// 正在跑就先让它退出：直接覆盖正在运行的可执行文件，
		// macOS 会留下一个「进程还在但资源已经是新的」的怪状态。
		if (await isRunning()) {
			log("先退出正在运行的 WhaleFloat");
			try {
				await run(APP_PATH + "/Contents/MacOS/" + APP_NAME, ["--quit"], { timeout: 15000 });
				await new Promise((r) => setTimeout(r, 1200));
			} catch {
				/* 退不掉也继续，覆盖时按尽力而为处理 */
			}
		}

		if (fs.existsSync(APP_PATH)) {
			log("移除旧版本 " + APP_PATH);
			fs.rmSync(APP_PATH, { recursive: true, force: true });
		}

		log("拷到 " + APP_PATH);
		fs.cpSync(src, APP_PATH, { recursive: true, force: true });

		// 隔离属性来自「从网上下载的包」。内嵌的不带，但用户之前从 dmg 装过
		// 的话旧 bundle 上可能带着；覆盖后一般没了，这里再清一遍，
		// 免得残留让人第一次打开被拦。
		try {
			await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", APP_PATH]);
		} catch {
			/* 没有这个属性时 xattr 也返回非零，不算失败 */
		}

		// 签名校验：ad-hoc 签名的包拷动后 codesign 仍应能过。
		// 过不了说明拷贝出了问题，早点记下来，别等用户点了没反应。
		let signed = true;
		try {
			await run("/usr/bin/codesign", ["--verify", "--deep", APP_PATH], { timeout: 30000 });
		} catch {
			signed = false;
			log("签名校验没过，但不阻断安装（ad-hoc 签名在部分系统上会这样）");
		}

		if (launch) {
			log("启动 " + APP_PATH);
			await run("/usr/bin/open", ["-a", APP_PATH], { timeout: 30000 });
		}

		return {
			changed: true,
			version: installedVersion(),
			previousVersion: haveVersion,
			signed,
			launched: launch,
			running: launch ? await isRunning() : false,
			appPath: APP_PATH,
		};
	} finally {
		try {
			fs.rmSync(stage, { recursive: true, force: true });
		} catch {
			/* 临时目录清不掉不影响结果 */
		}
	}
}
