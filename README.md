# LyricOverlay

Apple Music（macOS）实时歌词翻译叠加层：只要 Music 窗口在屏幕上露出来并显示着歌词，就在每行歌词上方叠加译文，跟随滚动动画，并像 Music 一样对非当前行做景深模糊。

A real-time translation overlay for Apple Music lyrics on macOS. Whenever the Music window is visible and showing time-synced lyrics, a translation is drawn above every lyric line, following Music's scroll animation and depth-of-field blur.

## 工作原理

- **歌词文字、排版、当前行**：从 Music 的无障碍树读取整首歌词（分组 › 按钮，`AXSelected` 标记当前行），不用 OCR。歌词一出现就整首预翻译。
- **滚动动画**：无障碍树只给终点位置。Music 的滚动是逐行带延迟的弹簧动画（从上往下的波浪），所以用 ScreenCaptureKit 以屏幕最高刷新率只抓 Music 窗口，每行歌词单独做行亮度曲线匹配来跟随；跟踪不到的边缘行按排版挂靠在相邻行上。
- **换基准**：某行在无障碍树里的新位置与画面跟踪结果对上时，无缝切到新位置。
- **模糊**：照 [AMLL](https://github.com/amll-dev/applemusic-like-lyrics) 的分档思路——当前行清晰，其它行按与当前行的距离逐档高斯模糊、压暗，0.4s 渐变。
- **叠加层**：透明、鼠标穿透的面板，紧贴在 Music 窗口上方一层，被别的窗口挡住的部分不会显示译文。
- 不带时间轴的静态歌词行距太紧，不显示译文。

## 构建与安装

需要 macOS 26+、Xcode 命令行工具。

```sh
./make-app.sh    # 编译、签名、安装到 /Applications/LyricOverlay.app
```

有 Apple Development 证书时会用它签名（重新编译后系统权限不会失效），没有则用临时签名。

首次运行需在 系统设置 › 隐私与安全性 中给「LyricOverlay」打开：
- **屏幕与系统录音**：跟踪滚动动画
- **辅助功能**：读取歌词

应用没有 Dock 图标，从菜单栏的 💬 图标退出。

## 翻译

- **Apple 本地翻译（默认）**：系统设置 › 通用 › 语言与地区 › 翻译语言，下载源语言。
- **OpenRouter（可选）**：整首一次请求，模型能看到上下文。
  ```sh
  defaults write com.gao.LyricOverlay OPENROUTER_API_KEY <key>
  defaults write com.gao.LyricOverlay OPENROUTER_MODEL google/gemini-2.5-flash   # 可选
  ```
- 目标语言默认简体中文，可用 `--to <语言代码>` 修改。

## 调试

```sh
open /Applications/LyricOverlay.app --stdout /tmp/lyric.log --args --debug --fake-translate
open /Applications/LyricOverlay.app --env LYRIC_TRACE=1 --stdout /tmp/lyric.log   # 逐行跟踪日志
open /Applications/LyricOverlay.app --args --dump-ax /tmp/lyric-ax.txt            # 导出 Music 无障碍树
```

`--fake-translate` 不调翻译，直接显示「译·原文」，用来检查排版和跟随。

## License

MIT
