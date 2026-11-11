# 开发与验证

## 环境

- macOS；Xcode 16.2（Swift 6.0）或更新版本。
- App 最低 iOS 15.0；核心包也可在 macOS 14+ 测试。
- Swift Package Manager 依赖由 `Package.resolved` 锁定，初次解析需要网络。
- 运行脚本需 Python 3 和 `rg`（ripgrep）。

Xcode 工程将 Readium 的间接依赖 SQLite.swift 固定为 0.15.4，以兼容 Swift 6.0。升级依赖时需检查工具链要求。iOS 26 专用工具栏外观仅在 Xcode 26 及更新版本中启用；Xcode 16.2 构建使用兼容实现。

在独立仓库根目录打开 `Legado.xcodeproj`，选择 `Legado` Scheme。真机运行需要自行设置签名团队；请勿将证书或描述文件提交到仓库。

## iCloud 同步

1. 在 Xcode 为 `Legado` Target 选择有 iCloud 权限的开发者团队和可用的 Bundle ID。Personal Team 或无签名构建不能验证 CloudKit。
2. 在 Signing & Capabilities 中启用 iCloud / CloudKit，并关联 `iCloud.<Bundle ID>` 容器。工程的 entitlement 和客户端容器名均跟随 Bundle ID。
3. 先用开发签名运行一次，在「我的 → 同步」开启 iCloud 同步。CloudKit 开发环境使用 `ReadingState` 和 `ReaderFile` 两种记录：前者保存配置与进度，后者保存文件 `file`（Asset）。配置记录字段为 `payload`（Bytes）、`payloadAsset`（Asset）、`modifiedAt`（Int64）和 `device`（String）。
4. 发布前在 CloudKit Console 将开发环境 schema 部署到 Production，再用具有相同容器权限的正式签名验证。当前实现按 record ID 获取记录，不依赖自定义查询索引。

同步范围包括书架与分组、本地 TXT / EPUB、阅读进度、书签和记录、书源、RSS 源、替换和 TXT 目录规则、订阅、HTTP TTS、编辑辅助、服务器配置、阅读设置、字体和背景。配置中填写的密钥或密码属于配置内容，会进入个人 iCloud；运行时 Cookie、登录会话、缓存和日志不上传。亮度保留在本机，字体与本地书籍路径在目标设备重新映射。

应用在本机修改后及回到前台时同步，也提供「立即同步」。配置按条目修改时间合并，进度按书名与作者匹配并保留较新时间；首次加入设备的默认值不会覆盖云端设置。删除通过标记同步，远端移除书架条目时保留本地正文文件。文件按内容摘要校验，后台失败会保留本机待同步状态并重试。

无签名模拟器只能验证合并、Unicode 位置及正文导入逻辑。跨设备验收应使用同一 Apple 账号的两台已签名设备，检查离线修改、删除、重新联网和本地文件还原；不能以本地测试通过替代 CloudKit 实测。

## 双页与朗读

iPad 横屏支持覆盖、滑动、仿真、滚动和无动画。覆盖和滑动以整屏双页一起运动，仿真围绕中缝翻动；滚动按双栏连续排版，旋转后保留阅读位置。双页中间区域唤起菜单，两侧边缘按点击设置翻页。菜单底部拖动的是本章进度，拖动时正文实时跟随，顶部与目录保留全书进度。

TTS 参考 Android 阅读的[系统朗读](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/service/TTSReadAloudService.kt)和[HTTP 朗读](https://github.com/LegadoTeam/legado/blob/master/app/src/main/java/io/legado/app/service/HttpReadAloudService.kt)服务。长文本按标点和 Unicode 字素边界分段，在线朗读限制后续段落与下一章开头的预取，暂停保留播放器位置，切段时忽略旧播放器回调。音频和会话错误会显示在阅读菜单中，提供重试；HTTP 文本错误与鉴权失败不会盲目重复请求。

## 代码结构

| 路径 | 用途 |
| --- | --- |
| `App/` | SwiftUI 页面、UIKit 阅读器、应用入口与资源 |
| `Sources/LegadoCore/` | 书源、规则引擎、网络、持久化、搜索、阅读及 RSS 等核心逻辑 |
| `Tests/LegadoCoreTests/` | 核心行为与书源兼容测试 |
| `Tests/LegadoAppModelsTests/` | 页面模型回归 |
| `Tests/LegadoReaderTests/` | iOS 阅读器与网页桥接测试 |
| `Tests/LegadoReaderUITests/` | 模拟器 UI 与阅读链路测试 |
| `App/Resources/` | 默认 TXT 目录规则、HTTP TTS 配置和第三方许可证 |
| `scripts/` | 自检与源码导出 |

## 验证命令

```sh
swift test --disable-sandbox
xcodebuild -project Legado.xcodeproj -scheme Legado \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

完整本地自检：

```sh
sh scripts/self-check.sh
```

首次运行可先在 Xcode 解析包；自检的 App 构建阶段固定使用已解析依赖。可用 `LEGADO_DERIVED_DATA_PATH` 和 `LEGADO_SOURCE_PACKAGES_PATH` 指定已有缓存。

阅读器测试在 Xcode 选择 `LegadoReaderTests` / `LegadoReaderUITests` Scheme 和具体模拟器运行。联网书源测试需要显式配置对应环境变量，默认核心回归主要采用自造响应，不能将其通过解读为所有线上书源均可用。

书源和本地 TXT / EPUB 文件选择回归需要先在已启动的测试模拟器中准备文件共享应用（将下方 UUID 换成实际值）：

```sh
LEGADO_TEST_DEVICE="模拟器 UUID"
sh scripts/prepare-source-import-fixture.sh "$LEGADO_TEST_DEVICE"
xcodebuild -project Legado.xcodeproj -scheme LegadoReaderUITests \
  -destination "platform=iOS Simulator,id=$LEGADO_TEST_DEVICE" \
  -only-testing:LegadoReaderUITests/RuleEditorUITests/testJSONFilePickerOffersOpenAndImportsSelectedFiles \
  -only-testing:LegadoReaderUITests/RuleEditorUITests/testBookshelfFilePickerImportsTXTAndEPUBAndDisablesJSON \
  -only-testing:LegadoReaderUITests/RuleEditorUITests/testFileManagementFilePickerImportsTXTAndEPUBAndDisablesJSON \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

独立测试应用提供 JSON 书源和 `.txt`、`.TXT`、`.epub` 小说样本，不会被打包进正式 App。此回归检查取消后重新打开、书源 JSON 多选、本地 TXT / EPUB 可选且 JSON 不可选、导入确认、最终保存、EPUB 正文、插图与目录跳转。

测试夹具仅在内容变化时原位写入文件，保持文件标识稳定。iOS 26 模拟器的 Files 提供器可能在样本被原子替换后返回「文件不存在」，导致已勾选文件未回传；遇到旧夹具残留时，卸载模拟器中的「书源导入测试」后重新运行准备脚本。

RSS 的导入、源内搜索、分页、正文、收藏以及重启恢复可通过本地自造响应回归，避免依赖第三方网站。先在一个终端运行 `python3 scripts/fixtures/rss-flow-server.py`，再在 Xcode 选择 `LegadoRSSFlowUITests` Scheme 和模拟器运行；也可用 `xcodebuild -project Legado.xcodeproj -scheme LegadoRSSFlowUITests -destination 'platform=iOS Simulator,id=模拟器UUID' CODE_SIGNING_ALLOWED=NO test`。该服务仅监听本机 `127.0.0.1:18763`，测试结束后按 Ctrl-C 停止。普通 UI Scheme 默认跳过此用例。

RSS 界面回归还验证正文的手动刷新确实重新请求网络。核心与页面模型回归覆盖查询隔离、刷新失败后的分页重试、重定向链接、文章变量、并发开关、书签与阅读记录保存顺序，以及自动更新过程中删除规则订阅；这些用例均使用临时数据库和自造响应，不访问个人书架。

## 兼容性验证

最低部署版本为 iOS 15.0。`App/Compatibility.swift` 为导航、分享、照片选择和弹窗提供兼容实现；新增系统 API 时需保留最低版本路径。调试构建可用 `-uiLegacyCompatibility` 启动参数在新系统上执行旧版界面分支，对应回归位于 `Tests/LegadoReaderUITests/`。这些测试不能替代 iOS 15 真机或模拟器实测。

搜索调度与缓存回归见 `Tests/LegadoCoreTests/SearchPerformanceTests.swift`，包括复杂书源限流和普通书源的及时执行；这些测试验证行为，不提供真实网络速度排名。

## 演示与公开截图

模拟器启动参数 `-uiDemo` 使用演示书架；`-uiDemoReader` 打开演示阅读页，`-uiDemoTab settings` 打开「我的」，`-uiDemoAbout` 打开关于页。部分演示入口仍保留 `settings` 参数名以兼容测试脚本。

提交截图前确认没有真实账号、个人书架或第三方付费正文。公开截图放在 `docs/images/`；`artifacts/`、构建缓存和原始测试日志仅供本地验证，已加入忽略清单。

## 导出源码

在多项目父仓库中开发时，可以运行以下命令导出本项目当前源码，排除父仓库历史、构建产物及签名文件：

```sh
python3 scripts/export-open-source.py /tmp/legado-ios-open-source
```

目标目录必须尚不存在。导出后检查内容，再用独立仓库管理；`.gitignore` 不会自动清理已经跟踪的文件。

## 维护应用源

`docs/altstore.json` 是 AltStore Classic、SideStore 和 LiveContainer 共用的应用源，固定地址为：

```text
https://raw.githubusercontent.com/Aminark/legado-ios/main/docs/altstore.json
```

源仅列出最新正式版，同时提供 `versions` 和旧客户端使用的顶层版本字段。版本号、构建号、最低 iOS 版本和隐私权限从实际 IPA 的 `Info.plist` 读取，下载地址、发布日期和更新说明来自 GitHub Release。目前由维护者在发布正式版后手动运行生成脚本并提交源文件。

1. 新版发布时，先在 Release 草稿中上传唯一的未签名 `.ipa`，再发布正式版。
2. 下载 GitHub 标记的 latest 正式版元数据及 IPA，运行下方生成与测试命令，检查 `docs/altstore.json` 差异后提交到 `main`。
3. 源文件发布后，客户端刷新源即可获取该版本的下载与更新入口。只提交源码或上传未发布的草稿不会更新应用源。

本地生成（需要 Python 3.9+；获取 Release 元数据时使用已登录的 GitHub CLI）：

```sh
source_update_dir=$(mktemp -d)
gh api repos/Aminark/legado-ios/releases/latest > "$source_update_dir/release.json"
source_release_tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$source_update_dir/release.json")
gh release download "$source_release_tag" --repo Aminark/legado-ios \
  --pattern '*.ipa' --dir "$source_update_dir"
python3 scripts/update-altstore-source.py \
  --ipa "$source_update_dir/legado-ios-v0.1.14-build20-unsigned.ipa" \
  --release "$source_update_dir/release.json"
python3 -m unittest discover -s scripts/tests -v
```

请将示例 IPA 文件名换成实际下载的附件名。脚本会核对包标识、Release 标签与 IPA 版本、文件大小，以及 Release 提供的 SHA-256（如有），避免源指向与本地检查不一致的包。当前生成器针对本项目无扩展、无额外 entitlement 的未签名 IPA；改用签名包、增加扩展或 entitlement 时，需要同步完善权限提取，生成器会拒绝带签名资源、描述文件或扩展的 IPA。

发布后检查固定地址可匿名访问、图标和截图能正常加载，并下载源中 IPA 再核对大小、摘要和版本。客户端的添加源、安装、更新与签名流程需分别实测；源文件校验通过不代表已完成真机安装验证。

格式说明：[AltStore 源规范](https://faq.altstore.io/developers/make-a-source)、[SideStore 源字段](https://sidestore.io/sidestore-source-types/interfaces/Source.html)、[LiveContainer 源用法](https://livecontainer.github.io/docs/guides/sources)。

## EPUB 回归

`swift test --disable-sandbox --filter EPUB` 覆盖 EPUB 2/3 元数据、中文资源路径、同页锚点、无目录降级、书脊顺序、插图、损坏与加密文件、重命名导出、导入失败回滚和阅读进度恢复。样本均由测试自行生成，不依赖网络或第三方书籍。

核心解析器按需读取 ZIP 资源，不解压到磁盘；单资源上限为 32 MiB。它用于导入、书架元数据和文字朗读。EPUB 原排版阅读由 Readium 3.8.0 的 Streamer / Navigator 处理，保留 XHTML、CSS、SVG 和内嵌插图；不接入 DRM 解密服务。原排版位置和书签使用 EPUB locator 保存，旧的文字进度仍兼容。

`LegadoReaderTests/EPUBReaderIntegrationTests` 在 iOS 中实际渲染自造 EPUB，检查 SVG 封面、相对路径图片、外部 CSS、表格、目录跳转和字号变化后的续读。可通过 `xcodebuild -project Legado.xcodeproj -scheme LegadoReaderTests -destination 'platform=iOS Simulator,id=模拟器UUID' -only-testing:LegadoReaderTests/EPUBReaderIntegrationTests CODE_SIGNING_ALLOWED=NO test` 运行。真实书籍样例仅用于本机验证，不放进仓库。
