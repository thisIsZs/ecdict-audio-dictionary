# ECDICT 英汉发音词典（macOS）

[![Release](https://img.shields.io/github/v/release/thisIsZs/ecdict-audio-dictionary?label=release)](https://github.com/thisIsZs/ecdict-audio-dictionary/releases/latest)
[![License](https://img.shields.io/github/license/thisIsZs/ecdict-audio-dictionary)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-black)](#已知限制)

把 [skywind3000/ECDICT](https://github.com/skywind3000/ECDICT) 1.0.28 的英汉数据转换成
macOS「词典」App 可用的 `.dictionary` 包，并为**核心/考试词**及部分 **`[计]`** 词条叠加
**真人发音**。

本仓库是 [343534-code/ecdict-macos-dictionary](https://github.com/343534-code/ecdict-macos-dictionary)
的修改版：保留其 MDX→Apple Dictionary 转换与排版，新增了**发音覆盖层**（Wikimedia Commons
真人录音 + 本地播放 Helper）。

## 特性

- **约 340 万条** ECDICT 词条，完全离线，无账号、无广告、无常驻进程。
- **7,983 条真人录音**（7,739 个单词）：
  - core（Oxford / Collins / 中考 / 高考 / CET4 / CET6 / 考研）：7,680 条
  - `[计]` 技术词增量：303 条
- **一词多音**：`record`、`object`、`present`、`produce` 等名词/动词读音不同的词，
  同时提供**两个喇叭**并标注 `noun` / `verb`；读音相同的词只显示一个。
- **Dictionary.app**：点击喇叭直接播放（相对路径 `<audio>`，播放时图标变蓝）。
- **三指 Look Up 弹窗**：**点击喇叭立即播放**（无需长按；纯悬停不触发），通过本地 Helper 出声。
- 深浅色自适应；浮窗有专门排版。

## 数据规模

| 项 | 数值 |
|---|---:|
| 词条 | 3,402,564 |
| 录音文件 | 7,983（Helper 实际可播 7,880） |
| 覆盖单词 | 7,739 |
| 安装体积 | 约 580 MB |

> 说明：103 条录音的 id 含空格/撇号/点（如 `ad hoc`、`a.m.`），被 Helper 的安全白名单跳过。

## 下载

在 [Releases](https://github.com/thisIsZs/ecdict-audio-dictionary/releases/latest) 下载：

| 文件 | 用途 |
|---|---|
| `ECDICT-macOS-Dictionary-v1.0.0.zip` | 词典本体（318 MB，解压后约 580 MB） |
| `ECDICTAudioHelper-v1.0.0-macos.zip` | 弹窗发音 Helper（25 KB，`arm64 + x86_64` 通用） |
| `SHA256SUMS.txt` | 上面两个 ZIP 的 SHA-256 |
| `install.sh` | 一行命令安装词典 |

词典也可以用一行命令安装（自动校验 SHA-256），详见下一节。

## 一行命令安装（推荐）

打开“终端”，粘贴下面一整行并按回车：

```bash
curl -fsSL https://github.com/thisIsZs/ecdict-audio-dictionary/releases/latest/download/install.sh | /bin/bash
```

脚本会从 GitHub Releases 下载最新版、核对 SHA-256、备份同名旧版，并安装到当前用户的
`~/Library/Dictionaries/`；同时**自动勾选该词典并置于词典列表第一位**，不需要管理员密码。
脚本内容可在运行前先打开 [`scripts/install.sh`](scripts/install.sh) 审查。

## 三步安装

1. 从 [Releases](https://github.com/thisIsZs/ecdict-audio-dictionary/releases/latest)
   下载 `ECDICT-macOS-Dictionary-v1.0.0.zip` 并解压。
2. 把整个 `ECDICT 英汉发音词典.dictionary` 复制到 `~/Library/Dictionaries/`。
3. 打开 Mac“词典”→“设置…”（`Command-,`），勾选 **ECDICT 英汉发音词典**，
   并同时勾选至少一个系统自带词典。

> 一行命令安装会自动完成第 3 步的勾选与置顶；手动安装需要自己勾选。

### 安装后检查

- 一行命令安装会自动勾选并置顶；手动安装请按第 3 步勾选。
- 安装脚本会退出正在运行的「词典」，重新打开后勾选与顺序才会生效。
- 旧版会备份到 `~/Library/Dictionaries/ECDICT Backups/`，可随时手动删除。
- 如果词条重复，请确认只勾选了**一本** ECDICT 词典。
- 弹窗没有声音时，检查 Helper 是否在运行（见下一节）。

## 弹窗发音 Helper（可选）

只有三指轻点/用力点按的「查询」弹窗需要它；Dictionary.app 主窗口的喇叭不需要。

下载 `ECDICTAudioHelper-v1.0.0-macos.zip` 并解压，然后：

**推荐：登录自启**

```bash
# 若之前手动运行过 Helper，先停掉（否则 17943 端口被占用）
kill $(lsof -nP -iTCP:17943 -sTCP:LISTEN -t) 2>/dev/null || true

./install-helper.sh
```

脚本会安装到 `~/Library/Application Support/ECDICT/`，并注册 LaunchAgent
`com.ecdict.audio-helper`（登录自启、退出后自动重启）。

**或前台运行**

```bash
./run-helper.sh
```

**验证**

```bash
curl --noproxy '*' http://127.0.0.1:17943/health   # ECDICT audio helper ready
tail -f ~/Library/Logs/ECDICTAudioHelper.log
```

**卸载**

```bash
./uninstall-helper.sh
```

> 从源码构建：`bash scripts/build_audio_helper.sh`（加 `UNIVERSAL=1` 生成通用二进制），
> 然后 `bash scripts/run_audio_helper.sh "<词典>/Contents/Resources"`。

## 工作原理

```
ECDICT MDX
  │ scripts/export_ecdict_styled.py（可选的 audio overlay 注入喇叭）
  ▼
Apple Dictionary XML ──► Dictionary Development Kit ──► .dictionary
                                                         ├── Resources/Audio/<id>.mp3
                                                         ├── Resources/audio-manifest.json
                                                         └── Resources/ATTRIBUTION.txt

播放：
  Dictionary.app  → 相对路径 <audio src="Audio/<id>.mp3"> + a.play()
  Look Up 弹窗     → onmouseover 写入本地 URL → 本地 Helper 用 AVAudioPlayer 播放
```

Helper（`scripts/ECDICTAudioHelper.m`）是自研的本地服务：仅监听 `127.0.0.1:17943`，
启动时校验每个 MP3 的 SHA-256，只播放清单内的文件。

## 从源码构建

依赖：

```bash
brew install lzo
python3 -m venv .venv-audio
.venv-audio/bin/python -m pip install -r requirements.txt -r requirements-audio.txt
```

音频采集（可选，需联网）：

```bash
# 1) 发现 + 许可审计（仅 CC0 / CC-BY-SA-3.0 / CC-BY-SA-4.0 / 公有领域）
.venv-audio/bin/python scripts/discover_pronunciations.py \
  data/audio/targets-core.txt data/audio/overlay-core/discovery.json

# 2) 下载 + 转码为 MP3（可断点续跑；429 自动退避）
.venv-audio/bin/python scripts/fetch_pronunciation_overlay.py \
  data/audio/overlay-core/discovery.json data/audio/overlay-core
```

导出与编译：

```bash
# 3) 合并 core + tech 的清单（overlay-all 是派生产物，不入库）
.venv-audio/bin/python scripts/merge_overlays.py data/audio/overlay-all \
  data/audio/overlay-core/manifest.json data/audio/overlay-tech/manifest.json

# 4) 导出全量 XML（约 1 GB）
.venv-audio/bin/python scripts/export_ecdict_styled.py \
  "/path/to/简明英汉字典增强版.mdx" build/full-src/Dictionary.xml \
  --audio-overlay data/audio/overlay-all/manifest.json

# 5) 用 Apple DDK 编译（需自行获取 Dictionary Development Kit）
.venv-audio/bin/python scripts/build_overlay_dictionary.py \
  --xml build/full-src/Dictionary.xml \
  --overlay data/audio/overlay-all/manifest.json \
  --output build/audio-full \
  --name "ECDICT 英汉发音词典" \
  --identifier "com.ecdict.dictionary.audio" \
  --ddk "/path/to/Dictionary Development Kit" --compile
```

## 发布（维护者）

```bash
VERSION=1.0.0

# 1) 词典 ZIP（顶层必须是 .dictionary 目录）
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$HOME/Library/Dictionaries/ECDICT 英汉发音词典.dictionary" \
  "dist/ECDICT-macOS-Dictionary-v$VERSION.zip"

# 2) Helper（通用二进制 + 脚本），并刷新 dist/SHA256SUMS.txt
VERSION=$VERSION bash scripts/build_helper_release.sh
```

把 `dist/` 下的 `ECDICT-macOS-Dictionary-*.zip`、`ECDICTAudioHelper-*.zip`、
`SHA256SUMS.txt`、`install.sh` 上传到 GitHub Release。
`install.sh` 必须作为附件，`/releases/latest/download/install.sh` 才能取到。

## 目录结构

```text
dictionary-source/        Apple DDK 工程：CSS / XSL / Info.plist / Makefile / 图标
scripts/                  MDX 导出、音频发现/下载、打包、Helper
packaging/helper/         Helper 的启动/安装/卸载脚本（随 Release 分发）
semantic_cleanup/         可选的语义覆盖层（数据契约与校验）
data/audio/               目标词表、overlay 清单与署名
docs/                     架构与 Helper 说明
tests/                    导出器与语义层测试
dist/                     本地生成的 ZIP / SHA256（不入库）
```

## 已知限制

- **仅支持 macOS**；Windows/Linux/iOS 无法使用 `.dictionary`。
- **三指弹窗播放依赖本地 Helper**；Dictionary.app 内播放不依赖。
- 构建依赖 Apple **Dictionary Development Kit**（未随仓库提供）。
- 词典包与 Helper **未签名/未公证**，首次运行可能触发 Gatekeeper 提示；
  `install-helper.sh` 会清除下载隔离标记，仍建议只从本仓库 Release 下载。
- 真人录音覆盖有限：核心词约 51%，`[计]` 技术词更低（Commons 上多数技术词没有录音）。

## 许可与致谢

- 词典数据：**ECDICT 1.0.28**，MIT License，`Copyright (c) 2017 Linwei`。
- 转换/排版/打包代码：源自
  [343534-code/ecdict-macos-dictionary](https://github.com/343534-code/ecdict-macos-dictionary)，MIT License。
- 录音：逐条保留各自许可（**CC0-1.0 / CC-BY-SA-3.0 / CC-BY-SA-4.0 / 公有领域**），
  署名见词典包内 `Resources/ATTRIBUTION.txt` 与 `data/audio/overlay-*/manifest.json`。
  CC-BY-SA 素材要求署名并以相同方式共享。
- 本项目为**非官方**转换版本，与 Apple Inc. 及 ECDICT 维护者无隶属或背书关系。

详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
