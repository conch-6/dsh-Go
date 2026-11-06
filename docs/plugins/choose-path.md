# 选一条路

[English](en/choose-path.md)

插件接进 dsh-go 有三条路。先看你手上有什么，走成本最低、够用的那条，之后还能继续往上加。

| 你手上有 | 走 | 要写的 | App 里的效果 |
|---|---|---|---|
| 一个 DSH 插件：命令、技能、设置 | [不用改](#1-不用改) | 什么都不用写 | 斜杠菜单、原生设置表单 |
| 插件带工具，想让结果好看 | [工具卡](#2-工具卡) | 工具的 `presentationMeta` | 工具结果画成原生卡片，所有主机都有 |
| 想在聊天页放按钮、面板、状态 | [原生插件](#3-原生插件) | `package.json` 的 `dshGo` + `ctx.dshGo` | 胶囊、菜单、状态条、面板等位置 |
| 已有 DSH 网页界面 | [网页插件](#4-已有网页界面的插件) | 不用改，也可以逐项换成原生 | 网页岛或「在网页版打开」 |

## 1. 不用改

命令、技能、Config schema、`dsh-ui` 卡片都已经原生显示，见[不写 App 代码就原生显示的东西](native-for-free.md)。

## 2. 工具卡

工具的返回里带一份视图，App 画成卡片。5 分钟能做完，走对话记录，所以中转主机上也有。见[快速开始](quickstart.md)。

工具卡目前只读，按钮不会生效。

## 3. 原生插件

插件逻辑照常跑在引擎里，App 不执行插件代码：你声明位置，发 JSON 视图，App 用自己的组件画出来，点按再传回给你。

1. 跟着[从零到市场](from-zero.md)做一遍。
2. 在[插槽参考](slots.md)里挑位置：

| 想做的 | 位置 |
|---|---|
| 一键往输入框放内容、处理剪贴板 | `composer.actions` 胶囊 |
| 不常用但要顺手的工具：贴纸、模板、选择器 | `composer.tools` 加号面板 |
| 对某条回复做事 | `message.actions` 消息菜单 |
| 对整段对话做事：导出、归档 | `session.actions` 对话操作 |
| 一直看得见的一个数字 | `composer.strip` 状态条 |
| 每轮一眼看到的数字：花费、命中率 | `turn.note` 回合尾注 |
| 一页信息或表单 | `panels` 面板 |
| 插件自己的状态页 | 面板 `placement: "plugin"` |

3. 用 `check` 和[预览](preview.md)自查，发布前过一遍[自查清单](checklist.md)。
4. 想知道哪些能依赖、哪些会变，看[稳定性承诺](stability.md)。

## 4. 已有网页界面的插件

不改也能用。App 按这个顺序安排你注册的 slot：原生适配器 → 网页岛 → 「在网页版打开」。App 没有位置的 slot，会在插件详情里如实列出来，见[网页插件面板](web-panels.md)。

**逐项换成原生更好：** 网页岛首次打开要 1–3 秒，一个约占 200 MB，还有同屏数量限制；原生位置秒开，观感和 App 一致。

`dshGo` 清单和 `ctx.dshGo` 只对 App 生效，所以网页版继续用你的网页界面，两边互不影响。可以这样对照：

| 网页 slot | 换成 |
|---|---|
| `conversation.input.dock`、`conversation.composer.dock` | `composer.strip` 或面板 `placement: "chat.panel"` |
| `conversation.input.left`、`conversation.input.right` | `composer.tools` 或 `composer.actions` |
| `conversation.session.header.actions` | `session.actions` |
| `conversation.chat.turnTail` | `turn.note` |
| `conversation.chat.assistant-actions` | `message.actions` |
| `tool.call.toolview` | 工具卡 `presentationMeta` |
| `sidebar.right.pane.tab` | 面板 `placement: "session.tab"` |
| `main` + `sidebar.panellist` | 面板 `placement: "features"` |
| `plugins.detail.section` | 面板 `placement: "plugin"` |
| `settings.section` | Config schema（自动成为原生表单） |

只换你在意的那几项就行，其余继续走网页。

**做不到的：** 自定义绘制和动画、替换官方界面、在 App 里运行你的代码。这类需求继续走网页岛，原因见[设计规则](design-rules.md)。

## 哪些主机上有

| | 工具卡 | 原生位置 | 网页岛 |
|---|---|---|---|
| 手机本机引擎 | ✅ | ✅ | ✅ |
| SSH 主机 | ✅ | ❌ 桥接还不能装到 SSH 主机 | ✅ |
| 中转主机 | ✅ | ❌ | ❌ |

详见[主机覆盖、安装与降级](hosts.md)。
