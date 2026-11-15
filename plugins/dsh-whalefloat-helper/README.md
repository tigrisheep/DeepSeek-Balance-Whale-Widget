# dsh-whalefloat-helper

鲸鱼浮窗 **WhaleFloat** 的 DSH 侧中介。装在 DeepSeek Harness 上之后，浮窗才看得到「正在等你回答」「这一轮花了多少」「后台任务跑完了」这些只有 DSH 内部知道的事。

顺带负责一件事：**在插件详情页装 WhaleFloat.app**。

## 装

在 DSH 的插件市场里搜 `whalefloat`，装上，重启 DSH。

或者命令行：

```bash
dsh plugin add dsh-whalefloat-helper
```

装完打开这个插件的详情页，会看到一个「安装小鲸鱼」按钮 —— 点它，app 会自己装进「应用程序」并启动。不用下载 dmg，也不用拖拽。

## 它做什么

| 能力 | 触发 | 浮窗上的表现 |
|---|---|---|
| 等待提示 | DSH 弹选项 / 要授权 | 冒出提示泡 |
| 每轮消耗 | 每轮对话结束 | 显示本轮金额 |
| 系统通知 | 后台任务完成 | 发 macOS 通知，可点回对话 |
| 拖图解题 | 把截图拖到浮窗 | 新开一个会话，图附在同一条消息上 |

数据都落在 `~/.dsh/` 下，不联网、不上传：

- `.whalefloat-wait.json` —— DSH 在等什么
- `.whalefloat-usage.json` —— 每轮 token 与金额
- `.whalefloat-notify.json` / `.whalefloat-reply.json` —— 通知与回信通道

浮窗读这些文件，插件写。两边不直接通信，所以谁先启动都行。

## 安装按钮是怎么工作的

插件里内嵌了打好包的 app（`assets/WhaleFloat.app.tar.gz`，约 2.4 MB）。点按钮时：

1. 解到临时目录（不在「应用程序」里做半成品）
2. 旧版在跑就先让它退出
3. 拷进 `/Applications`，去掉隔离属性，验一遍签名
4. 打开

版本一样时直接返回「已安装」，不会白拷一遍。要重装就去点「重装小鲸鱼」。

接口就两条，挂在 `/whalefloat/` 下：`GET status`、`POST install`。同一时刻只允许一个安装在跑，连点两下不会拷出两份。

## 和 app 的分工

0.2.1 起方向反过来了：**插件由市场分发，app 由插件安装**。

之前是 app 自带插件、启动时往 `~/.dsh` 里塞。那样有个问题 —— 用户从市场升级插件后，一开浮窗就被 app 里那份旧插件盖回去，升级静默失效。现在 app 只在「压根没装、且包里正好带了一份」时才兜底。

## 许可

MIT。浮窗本身与角色素材的授权另见 [WhaleFloat 仓库](https://github.com/tigrisheep/DeepSeek-Balance-Whale-Widget)。
