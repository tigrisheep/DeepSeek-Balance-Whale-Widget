/**
 * HTTP 路由：界面上的按钮靠这几条接口干活。
 *
 * 为什么走 HTTP 而不是 Remote 调用：DSH 的 Remote 通道要 typert 代码生成器
 * 从类型定义里生成 host/remote 两份产物，那是官方包的构建流程；本插件是
 * 手写 ESM，没有生成器可用。插件市场（dshmarket）遇到同一个问题，
 * 用的也是 ctx.webServer.register + 客户端 fetch（见它的 lib/routes.js）。
 *
 * 路径统一挂在 /whalefloat/ 下，和别的插件不会撞。
 */

import { install, status } from "./installer.js";

const PREFIX = "/whalefloat/";

/** 一次只允许一个安装在进行：点两下不该并发出两份拷贝。 */
let inFlight = null;

function sendJson(response, code, body) {
	const text = JSON.stringify(body);
	response.writeHead(code, {
		"content-type": "application/json; charset=utf-8",
		"cache-control": "no-store",
	});
	response.end(text);
}

function sendError(response, code, err) {
	const message = err && err.message ? err.message : String(err);
	sendJson(response, code, { ok: false, error: message });
}

/** 读请求体。安装请求没有 body，但保留这份能力，后面要参数时不必改协议。 */
function readBody(request, limit) {
	return new Promise((resolve) => {
		let size = 0;
		const chunks = [];
		request.on("data", (chunk) => {
			size += chunk.length;
			if (size > limit) {
				request.destroy();
				resolve(null);
				return;
			}
			chunks.push(chunk);
		});
		request.on("end", () => {
			if (chunks.length === 0) return resolve({});
			try {
				resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
			} catch {
				resolve(null);
			}
		});
		request.on("error", () => resolve(null));
	});
}

/**
 * 注册路由。
 *
 * @param webServer ctx.webServer（由宿主注入）
 * @param here      插件目录，安装包在它的 assets/ 下
 * @returns 注销函数数组 —— 插件卸载时必须摘干净，否则重载会报路由重复
 */
export function registerRoutes(webServer, here, logger) {
	const disposers = [];

	// 状态：按钮靠它决定显示「安装」还是「已安装 / 升级」
	disposers.push(webServer.register({
		kind: "exact",
		path: PREFIX + "status",
		handler: async (request, response) => {
			if (request.method !== "GET") {
				response.writeHead(405, { allow: "GET" });
				response.end();
				return;
			}
			try {
				sendJson(response, 200, { ok: true, ...(await status(here)), installing: inFlight !== null });
			} catch (err) {
				logger?.warn?.(`whalefloat-helper: 状态查询失败 ${err}`);
				sendError(response, 500, err);
			}
		},
	}));

	// 安装：唯一会动 /Applications 的入口
	disposers.push(webServer.register({
		kind: "exact",
		path: PREFIX + "install",
		handler: async (request, response) => {
			if (request.method !== "POST") {
				response.writeHead(405, { allow: "POST" });
				response.end();
				return;
			}
			const body = await readBody(request, 64 * 1024);
			if (body === null) {
				sendError(response, 400, new Error("请求体不是合法 JSON"));
				return;
			}

			// 已经在装了就把这一份做完，第二下不重复拷
			if (inFlight) {
				try {
					const done = await inFlight;
					sendJson(response, 200, { ok: true, ...done, shared: true });
				} catch (err) {
					sendError(response, 500, err);
				}
				return;
			}

			const task = install(here, { force: body.force === true });
			inFlight = task;
			try {
				const done = await task;
				logger?.info?.(`whalefloat-helper: 安装完成 ${JSON.stringify(done)}`);
				sendJson(response, 200, { ok: true, ...done });
			} catch (err) {
				logger?.warn?.(`whalefloat-helper: 安装失败 ${err}`);
				sendError(response, 500, err);
			} finally {
				inFlight = null;
			}
		},
	}));

	return disposers;
}
