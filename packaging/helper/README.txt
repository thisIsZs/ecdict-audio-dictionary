ECDICT 英汉发音词典 — 发音 Helper（macOS）
==========================================

用途
  三指轻点/用力点按的「查询」弹窗只把 mouseover 事件传给词典内容，点击事件
  会被吞掉。这个本地 Helper 接收面板发来的播放请求，用 AVAudioPlayer 播放
  词典包里的 Resources/Audio/<id>.mp3。
  Dictionary.app 主窗口里的喇叭不依赖它。

系统要求
  macOS 12 或更高；且已安装词典：
    ~/Library/Dictionaries/ECDICT 英汉发音词典.dictionary
  或
    /Library/Dictionaries/ECDICT 英汉发音词典.dictionary

方式一：登录时自动运行（推荐）
  若之前手动运行过 Helper，先停掉它（否则 17943 端口被占用）：
    kill $(lsof -nP -iTCP:17943 -sTCP:LISTEN -t)

  chmod +x install-helper.sh
  ./install-helper.sh

  会做三件事：
    1. 复制 Helper 与启动脚本到 ~/Library/Application Support/ECDICT/
    2. 写入 LaunchAgent ~/Library/LaunchAgents/com.ecdict.audio-helper.plist
    3. 立即启动，并在每次登录时自动运行、退出后自动重启

  日志：~/Library/Logs/ECDICTAudioHelper.log

方式二：前台运行
  chmod +x run-helper.sh
  ./run-helper.sh
  Ctrl-C 结束；重启电脑后需重新运行。

验证
  curl http://127.0.0.1:17943/health

  正常时返回 JSON（包含已校验的录音数量）。

卸载
  chmod +x uninstall-helper.sh
  ./uninstall-helper.sh

安全
  Helper 只监听 127.0.0.1:17943，启动时校验每个 MP3 的 SHA-256，
  只播放 audio-manifest.json 中列出的文件；不会下载或上传任何内容。
