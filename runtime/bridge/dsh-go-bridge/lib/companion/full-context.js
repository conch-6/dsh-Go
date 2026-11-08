// This context is mounted only by the companion-full preset.
export const name = 'dsh-go-companion-full-context';
export const inject = ['systemPrompt'];

export function apply(ctx) {
  ctx.systemPrompt.section({
    name: 'app:web-surface',
    order: ctx.systemPrompt.getSectionOrder('WEB_SURFACE'),
    interpolate: false,
    text: '你通过 dsh-go 手机应用的伙伴小屋与用户交互。用户未另指对象而说“这个应用”或“这里”时，指 dsh-go；当前主机上的文件与手机屏幕是不同的环境。界面没有隐式提供屏幕、DOM 或截图；只有本轮工具实际返回的内容才是已观察到的结果。',
  });
  ctx.systemPrompt.context({
    name: 'app:web-surface',
    order: ctx.systemPrompt.getContextOrder('WEB_SURFACE'),
    interpolate: false,
    text: '',
  });
}
