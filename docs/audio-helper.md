# ECDICT 本地发音扩展

为词条叠加**真人录音**：数据来自 Wikimedia Commons，逐条做许可审计（仅 CC0 / CC-BY-SA-3.0 / Public Domain），音频存为 `Contents/Resources/Audio/<id>.mp3`（**不内嵌**，因此可容纳上万条），由本地 helper 播放。

## 覆盖范围

- **core（核心/考试）**：Oxford、Collins、中考/高考/CET4/CET6/考研，共 14,627 词；目标词表 `data/audio/targets-core.txt`。
- **tech（`[计]` 扩展）**：含 `[计]` 的技术词，共 70,105；`data/audio/targets-tech.txt`。
- 合并集 `data/audio/targets-all.txt`（83,358）。
- 只有**能拿到可审计录音**的词会插入喇叭；其余词条不受影响（安全回退）。

## 流水线

```
① 词表      data/audio/targets-{core,tech,all}.txt
② 发现+许可  scripts/discover_pronunciations.py   → discovery.json（Commons API + extmetadata）
③ 下载+转码  scripts/fetch_pronunciation_overlay.py → manifest.json + audio/<id>.mp3（校验 SHA-1，峰值归一化）
④ 注入词条  scripts/export_ecdict_styled.py --audio-overlay manifest.json → XML
⑤ 打包编译  scripts/build_overlay_dictionary.py → .dictionary（Audio/ + audio-manifest.json + DDK）
⑥ 播放      scripts/ECDICTAudioHelper.m（本地 helper，127.0.0.1:17943）
```

命令（`python` 指项目虚拟环境）：

```bash
# ② 发现 + 许可审计（只接受 CC0 / CC-BY-SA-3.0 / PD）
python3 scripts/discover_pronunciations.py data/audio/targets-core.txt data/audio/overlay-core/discovery.json

# ③ 下载 + 转码（串行 + HTTPS 长连接；429 自动退避重试；可断点续跑）
python3 scripts/fetch_pronunciation_overlay.py data/audio/overlay-core/discovery.json data/audio/overlay-core

# ④ 导出全量 XML（命中词条在 entry-header 末尾注入喇叭）
python3 scripts/export_ecdict_styled.py "简明英汉字典增强版.mdx" build/xml/ECDICT-styled.xml \
  --audio-overlay data/audio/overlay-core/manifest.json

# ⑤ 编译成 .dictionary
python3 scripts/build_overlay_dictionary.py \
  --xml build/xml/ECDICT-styled.xml \
  --overlay data/audio/overlay-core/manifest.json \
  --name "ECDICT 简明英汉字典（发音）" --identifier "com.ecdict.dictionary.audio" \
  --ddk "/path/to/Dictionary Development Kit" --compile

# ⑥ 启动 helper 后，把包放进 ~/Library/Dictionaries 并在“词典”设置里启用
bash scripts/build_audio_helper.sh
bash scripts/run_audio_helper.sh "$HOME/Library/Dictionaries/<包名>.dictionary/Contents/Resources"
```

## 播放机制

**Dictionary.app**：点击喇叭 → `onclick` 里 `new Image().src = .../audio/play/<id>?event=click…` → 请求打到 helper 播放。

**三指 Look Up 弹窗**：弹窗**只把 `mouseover` 送达内容**（`onmousedown`/`onmousemove`/`onclick` 都不到；自定义 scheme 链接也不会交给 Launch Services）。所以用**停留触发**：

1. `onmouseover` 启动 400ms 计时；
2. 到点把 `--ecdict-audio-request` 写成 `url("http://127.0.0.1:17943/audio/play/<id>?event=dwell&counter=…")`；
3. CSS `html.apple_client-panel a.audio-lookup:hover { background-image: var(--ecdict-audio-request) }` 让 WebKit 去加载这个 **1×1 透明图** → 发出请求 → helper 播放；
4. `onmouseout` 清计时器（快速划过不播）；指针移开再停一次即可重播。

URL 每次都带 `counter`，是因为 WebKit 对**相同 URL 复用图片缓存**，URL 不变就不会重新请求（这也是"必须移开再进入"的根因）。

喇叭图标是两张叠放的 `<img>`（灰/蓝），加 `opacity` 切换；图标 `pointer-events:none`，避免显隐改变命中目标而重复触发。

## Helper

- 只监听 `127.0.0.1:17943`；允许列表来自包内 `audio-manifest.json`；启动时**校验每个 MP3 的 SHA-256**。
- 没有任意文件/命令执行/外网接口；`/audio/play/<id>` 返回禁用缓存的 1×1 透明 GIF。
- 前台进程，无登录项；`Ctrl-C` 或 `pkill -f ECDICTAudioHelper` 停止。

## 日志与健康检查

Helper 日志由 `run_audio_helper.sh` 追加到 `$ECDICT_AUDIO_LOG`（默认 `build/audio-helper/requests.log`），只记录固定事件类型与 clip id：

- `REQUEST <id> event=click|dwell|hover` → 收到请求；
- `PLAY <id>` → AVAudioPlayer 启动成功；
- `FINISH … success=true` → 播放结束（不等于人耳确认）。

```bash
curl --noproxy '*' --max-time 2 http://127.0.0.1:17943/health
tail -n 40 build/audio-helper/requests.log
```

## 依赖

- 读 MDX：`requirements.txt`（`readmdict`、`python-lzo`，另需系统 LZO 库）。
- 音频处理：`requirements-audio.txt`（`imageio-ffmpeg` 提供 ffmpeg）。
- 环境：项目虚拟环境 `.venv-audio`。

## 已知限制

- 弹窗**不支持点击播放**（只转发 `mouseover`），故用停留触发；这与参考产品 dictionaries.io 的弹窗行为一致。
- 真人录音覆盖有限：core 小写词约 50%，`[计]` 更低；取不到的词不放喇叭。
