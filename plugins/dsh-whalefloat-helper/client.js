/**
 * 浏览器半：插件详情页上的「安装小鲸鱼」按钮。
 *
 * 放在 plugins.detail.actions 挂载点 —— 那一行本来就是放按钮的，
 * 和「更新」「卸载」并排，用户找得到，也不用多开一页。
 *
 * 只对本插件的详情页渲染：这个挂载点是 list 类型，任何插件的详情页都会
 * 调它，不加判据的话按钮会出现在所有插件上。
 */

window.__ModuleLoader__.load({
	id: "dsh-whalefloat-helper",
	factory(require) {
		const React = require("react");
		const h = React.createElement;
		const { useEffect, useState, useCallback } = React;

		const SELF = "dsh-whalefloat-helper";

		const zh = {
			install: "安装小鲸鱼",
			reinstall: "重装小鲸鱼",
			upgrade: "升级到 v{version}",
			installing: "安装中…",
			running: "小鲸鱼在跑",
			failed: "安装失败：{error}",
			unsupported: "仅支持 macOS",
			noBundle: "插件里没有内嵌安装包",
			unavailable: "读不到安装状态",
			done: "已装好 v{version}，小鲸鱼应该已经浮在屏幕上了。",
		};
		const en = {
			install: "Install WhaleFloat",
			reinstall: "Reinstall WhaleFloat",
			upgrade: "Upgrade to v{version}",
			installing: "Installing…",
			running: "WhaleFloat is running",
			failed: "Install failed: {error}",
			unsupported: "macOS only",
			noBundle: "This build carries no bundled app",
			unavailable: "Cannot read install status",
			done: "Installed v{version}. The whale should be on screen now.",
		};

		/** 相对页面基址解析，挂在反代子路径下也能用。 */
		function api(path) {
			const relative = path.replace(/^\/+/, "");
			if (typeof document === "undefined") return "/" + relative;
			return new URL(relative, document.baseURI).pathname;
		}

		async function getStatus(signal) {
			const res = await fetch(api("whalefloat/status"), { signal, headers: { accept: "application/json" } });
			if (!res.ok) throw new Error("HTTP " + res.status);
			return res.json();
		}

		async function postInstall(force) {
			const res = await fetch(api("whalefloat/install"), {
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({ force: force === true }),
			});
			const body = await res.json().catch(() => ({}));
			if (!res.ok || body.ok !== true) throw new Error(body.error || "HTTP " + res.status);
			return body;
		}
		function InstallButton(props) {
			const t = props.t;
			const [state, setState] = useState({ phase: "loading", status: null, error: null });

			useEffect(() => {
				const controller = new AbortController();
				getStatus(controller.signal)
					.then((s) => setState({ phase: "ready", status: s, error: null }))
					.catch((err) => {
						if (controller.signal.aborted) return;
						setState({ phase: "unavailable", status: null, error: String(err.message || err) });
					});
				return () => controller.abort();
			}, []);

			const run = useCallback(async (force) => {
				setState((prev) => ({ ...prev, phase: "installing", error: null }));
				try {
					const done = await postInstall(force);
					const s = await getStatus();
					setState({ phase: "ready", status: s, result: done, error: null });
				} catch (err) {
					setState((prev) => ({ ...prev, phase: "ready", error: String(err.message || err) }));
				}
			}, []);

			// 详情页刚打开、还没查到状态：不渲染，避免按钮闪一下再变样
			if (state.phase === "loading") return null;

			const status = state.status;
			if (state.phase === "unavailable" || !status) {
				return h("span", { style: { fontSize: 12, opacity: 0.6 } }, t("unavailable"));
			}
			if (!status.supported) {
				return h("span", { style: { fontSize: 12, opacity: 0.6 } }, t("unsupported"));
			}
			if (!status.hasBundle) {
				return h("span", { style: { fontSize: 12, opacity: 0.6 } }, t("noBundle"));
			}

			const busy = state.phase === "installing" || status.installing === true;
			const installed = status.installed === true;
			const newer = installed && status.bundledVersion && status.bundledVersion !== status.installedVersion;

			let label = t("install");
			if (busy) label = t("installing");
			else if (newer) label = t("upgrade", { version: status.bundledVersion });
			else if (installed) label = t("reinstall");

			const button = h("button", {
				type: "button",
				disabled: busy,
				onClick: () => void run(installed),
				style: {
					fontSize: 13,
					padding: "6px 14px",
					borderRadius: 8,
					border: "1px solid currentColor",
					background: "transparent",
					color: "inherit",
					cursor: busy ? "default" : "pointer",
					opacity: busy ? 0.6 : 1,
				},
			}, label);

			const notes = [];
			if (state.error) {
				notes.push(h("span", { key: "err", style: { fontSize: 12, color: "#d9534f" } }, t("failed", { error: state.error })));
			} else if (state.result && state.result.changed === true) {
				notes.push(h("span", { key: "ok", style: { fontSize: 12 } }, t("done", { version: state.result.version || "?" })));
			} else if (installed && status.running) {
				notes.push(h("span", { key: "run", style: { fontSize: 12, opacity: 0.7 } }, t("running")));
			}

			return h("span", { style: { display: "inline-flex", alignItems: "center", gap: 8 } },
				button,
				notes.length > 0 ? h("span", { style: { display: "inline-flex", gap: 6 } }, notes) : null);
		}
		return {
			inject: ["slots", "locale"],
			apply(ctx) {
				const t = ctx.locale.bind("whalefloatHelper");
				ctx.effect(() => ctx.locale.register("whalefloatHelper", { zh, en }), "whalefloat-helper: dictionary");

				ctx.slots.inject("plugins.detail.actions", () => {
					const off = ctx.slots.register({
						name: "plugins.detail.actions",
						id: "whalefloat-install",
						order: 40,
						inject: () => ({ t }),
					}, (props) => {
						// 只认本插件的详情页：这个挂载点对每个插件的详情页都会调用，
						// 不加判据的话按钮会出现在所有插件上。
						const subject = props && props.subject;
						const name = subject && subject.pkg ? subject.pkg.name : undefined;
						if (name !== SELF) return null;
						return h(InstallButton, { t });
					});
					return typeof off === "function" ? off : () => {};
				});
			},
		};
	},
});
