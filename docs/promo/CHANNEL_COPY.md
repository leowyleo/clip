# Clip 渠道推广文案

所有渠道统一使用以下事实：

- Clip 是免费开源的 macOS 截图工具，支持 macOS 13 及以上版本；
- 普通截图完成后直接进入剪贴板；
- 滚动截图由用户手动滚动，Clip 只在内存中连续取帧并拼接，不生成视频；
- 支持 Apple 芯片与 Intel Mac；
- 不需要账户、不上传截图、不依赖云端；
- v0.1.0 尚未经过 Apple 公证，首次打开需在“系统设置 → 隐私与安全性”中选择“仍要打开”。

项目地址：https://github.com/leowyleo/clip

下载地址：https://github.com/leowyleo/clip/releases/tag/v0.1.0

## 配图顺序

1. 封面：`docs/promo/wechat-cover.png`
2. 自由框选、编辑与粘贴动图：`docs/promo/screenshots/region-capture.gif`
3. 手动滚动、完成与粘贴动图：`docs/promo/screenshots/scrolling-capture.gif`
4. 设置页：`docs/promo/screenshots/settings.png`

V2EX、少数派和小众软件正文至少放第 2、3 张；小红书按 1、2、3、4 的顺序组成四图。第 3 张必须保留固定选区和“完成”按钮，让用户一眼看懂“自己滚动，Clip 负责记录”。

## V2EX

### 标题

[分享创造] Clip：一个“框住，就能粘贴”的免费开源 Mac 截图工具

### 正文

平时工作要截很多图，但我真正想要的动作一直很简单：框住，然后直接粘贴。

所以我做了 Clip，一个剪贴板优先的 macOS 截图工具。

它目前有两个核心功能：

1. 自由框选：松开鼠标后，图片立即进入剪贴板；
2. 滚动截图：框选后由用户正常滚动，Clip 连续记录变化，点击完成后拼成一张长图。

我刻意保留了几条边界：不要求账户、不上传截图、不生成视频、不针对某个 App 做专用适配。无法可靠证明画面连续时，宁可明确失败，也不输出一张看似正常但内容错误的长图。

当前版本支持 macOS 13+、Apple 芯片和 Intel Mac，免费并采用 MIT License 开源。因为尚未购买 Apple Developer Program，v0.1.0 还没有经过 Apple 公证，首次打开需要在“系统设置 → 隐私与安全性”中选择“仍要打开”。

GitHub：https://github.com/leowyleo/clip

Release：https://github.com/leowyleo/clip/releases/tag/v0.1.0

这是第一个公开版本。我尤其想知道：它在哪个 App 里不好用？滚动截图在哪类页面上容易失败？哪个动作仍然显得多余？这些反馈会直接决定下一版改什么，以及不应该加入什么。

## 少数派 Matrix

### 标题

我做了一个不打断工作的 Mac 截图工具：框住，就能粘贴

### 导语

真正顺手的工具，不是让你看到更多功能，而是让你更少意识到它的存在。为了少一次保存、命名和切换，我做了 Clip。

### 正文

每天工作时，我都会截很多图：发一个页面细节、记录一条报错，或者截取一段聊天。

真正需要的动作其实很简单：框住它，然后粘贴出去。但不少截图工具会在中间加入预览、保存、命名和各种按钮。功能越来越多，注意力也被一次次打断。

所以，我做了 Clip。

Clip 最核心的体验只有三个动作：框选、松开、粘贴。截图完成后，图片直接进入剪贴板；打开微信、飞书、邮件或文档，按下 ⌘V 就能使用。

滚动截图也保持相同的控制感。选区固定后，你照常使用鼠标或触控板滚动页面，想截到哪里就滚到哪里，最后点击对号完成。Clip 只负责连续记录画面变化，并把内容拼成一张长图。它不会替你滚动，也不会生成视频，边框、按钮和其他界面都不会进入结果。

Clip 默认使用极简模式，不主动展示多余工具。确实需要时，可以切换到高级模式，使用马赛克、文字、箭头、线条、本地 OCR 和下载功能。

它不需要账户，不上传截图，不依赖云端，也不为某个 App 编写专用适配器。无法可靠拼接时，Clip 会明确失败并保留原始分片，而不是输出一张可能错误的长图。

我选择把 Clip 免费开源，是因为不想继续闭门猜测“用户可能需要什么”。我更想知道，它是否真的能让截图少一个步骤，让工作少一次中断。

项目与下载：https://github.com/leowyleo/clip

当前 v0.1.0 尚未经过 Apple 公证。如果首次打开被 macOS 拦截，请前往“系统设置 → 隐私与安全性”，选择“仍要打开”。

如果你试用了 Clip，欢迎告诉我：它在哪个 App 里不好用？哪个动作仍显得多余？

## 小众软件推荐

### 标题

Clip – 框住就能粘贴，支持手动滚动截图的 macOS 开源工具

### 推荐摘要

Clip 是一款免费开源、剪贴板优先的 macOS 截图工具。普通截图只需框选并松开，图片便会直接进入剪贴板；滚动截图则由用户正常滚动，Clip 在内存中记录变化并拼接成长图，不生成视频。它支持 macOS 13+、Apple 芯片与 Intel Mac，不需要账户，不上传图片，也不依赖特定 App。项目采用 MIT License，当前 v0.1.0 尚未经过 Apple 公证，首次启动需要在 macOS“隐私与安全性”中选择“仍要打开”。

项目：https://github.com/leowyleo/clip

下载：https://github.com/leowyleo/clip/releases/tag/v0.1.0

## 小红书

### 标题

框住就能粘贴，我做了个 Mac 截图工具

### 正文

我每天都要截很多图，但真正想要的其实只有三个动作：

框选 → 松开 → 粘贴。

所以我做了 Clip：

• 普通截图直接进入剪贴板

• 滚动截图由你自己滚动，想截到哪里就停在哪里

• 不需要账户，不上传图片

• 支持 macOS 13+、Apple 芯片和 Intel Mac

• 免费开源

现在还是第一个公开版本。我想知道的不是还能塞进多少功能，而是哪个步骤仍然多余。

GitHub 搜索：jearthliu / clip

#Mac软件 #效率工具 #截图工具 #开源软件 #独立开发

## Bilibili

### 标题

我做了一个免费的 Mac 截图工具：框住，松手，直接粘贴

### 简介

Clip 是一个免费开源、完全在本机运行的 macOS 截图工具。普通截图完成后直接进入剪贴板；滚动截图由用户手动滚动，Clip 负责连续记录和像素拼接，不生成视频。

支持 macOS 13+、Apple 芯片和 Intel Mac。

项目与下载：https://github.com/leowyleo/clip

### 60 秒演示结构

1. 0–5 秒：展示“框住，就能粘贴”；
2. 5–20 秒：自由框选后直接粘贴到微信或备忘录；
3. 20–40 秒：框选网页区域、手动滚动、点击完成、粘贴长图；
4. 40–50 秒：展示极简与高级模式；
5. 50–60 秒：展示 GitHub 和下载方式，邀请反馈。

## Product Hunt

### Name

Clip

### Tagline

Select, release, paste — screenshots that stay out of your way

### Description

Clip is a free, open-source screenshot utility for macOS. Capture any region directly to the clipboard, or select a viewport and scroll naturally while Clip assembles the pixels into a long image. Everything stays local: no account, no cloud upload, no video file, and no app-specific adapters.

### First maker comment

I built Clip because taking a screenshot had slowly accumulated too many steps. Most of the time I only wanted to select something and paste it into a conversation or document.

Clip keeps that path to select → release → paste. Scrolling capture follows the same idea: you scroll, Clip observes in-memory frames, and a long image is assembled only when continuity can be verified. If the match is not reliable, Clip fails clearly instead of returning a plausible but incorrect image.

This is the first public release. It supports macOS 13+, Apple Silicon, and Intel Macs. I would especially value feedback about apps or pages where scrolling capture struggles, and any step that still feels unnecessary.

## Hacker News

### Title

Show HN: Clip – a local, clipboard-first screenshot tool for macOS

### Text

I built Clip because I wanted the common screenshot path to stay at select → release → paste.

It captures rectangular regions directly to the clipboard and also supports app-agnostic scrolling capture. For scrolling capture, the user scrolls normally while Clip consumes in-memory ScreenCaptureKit frames, discards unchanged frames, and stitches only verifiable overlapping pixels. It does not create a video file or use per-app adapters. If continuity cannot be proven, it fails instead of returning a plausible but incorrect image.

Clip is MIT licensed, runs locally, requires no account, and supports macOS 13+ on Apple Silicon and Intel Macs.

Source and release: https://github.com/leowyleo/clip

## Reddit r/macapps

### Title

I made Clip, a free open-source screenshot tool that copies regions directly to the clipboard

### Text

I wanted a screenshot tool that disappears as soon as the job is done: select a region, release the mouse, and paste.

Clip also supports scrolling capture without taking over the scroll interaction. You select a viewport and scroll normally; Clip keeps only frames with reliable overlap and assembles the uncovered pixel rows into a long image. It stays local, creates no video file, and uses no app-specific adapters.

The first release supports macOS 13+, Apple Silicon, and Intel Macs. It is free and MIT licensed. The current build is not Apple-notarized yet, so the release notes include the explicit first-launch steps.

GitHub: https://github.com/leowyleo/clip

I would love feedback on apps or pages where scrolling capture struggles, and on anything that still feels like an unnecessary step.
