# 中文延迟增强版如何跟进官方更新

本仓库是 [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune) 的公开 Fork。**公开 Fork 可以合并官方更新**；公开或私有本身并不决定能否合并，关键是保留 Git 历史，并将官方仓库作为上游。

## 更新的实际范围

- 已保留：各设备 0–2000 ms 独立延迟、±10/±50 ms 按钮、数字左右键及 Shift/Option 微调、优化后的设备卡片。
- 已加入[同步测试音与麦克风自动校准](CALIBRATION.zh-CN.md)；新增音频校准源码、测试及中文资源会随本仓库一起保留。
- 汉化使用标准 String Catalog，随 macOS 语言选择简体中文或英文。设备 UID、应用标识、用户预设名称和存储字段保持原样。
- 官方更新跟进的是**源码**。需要合并、测试并重新构建定制版，才能同时获得官方新功能和本仓库的改动。
- 直接安装官方发布包会替换定制程序。因此本版本停用了官方 Sparkle 自动安装，更新页链接到本 Fork 的 Releases。

## 已配置的 GitHub Actions

1. **Prepare official upstream update**：每周一北京时间 10:19 检查官方 `main`，也可以在 Actions 中手动点击 Run workflow。
2. 已包含官方提交时保持安静；已有待审更新 PR 时等待该 PR 处理，不重复创建。
3. 能正常合并时，将结果推到 `automation/upstream` 并创建更新 PR；**不会直接改写 main，也不自动合并 PR**。
4. 工作流会对这个合并提交运行独立测试、本地化覆盖检查和定制版构建，并在 PR 中报告结果。即使用 GitHub 自带令牌创建的 PR 不触发普通 PR 工作流，显式验证任务也会执行。
5. 合并有冲突时停止，在 Actions 摘要中列出冲突文件。main 保持原样，需要手动处理后再继续。
6. 审核合并 PR 后，main 的 CI 会再次构建，生成 `FineTune-CN-macOS` 下载工件。该工件保留 30 天。
7. 推送 `cn-v*` 标签，或手动运行 **Release Chinese delay edition** 并指定已有标签，会先验证该版本，再发布到本仓库 Releases。

例子：

```sh
git switch main
git pull --ff-only origin main
git tag cn-v1.9.0-r2
git push origin cn-v1.9.0-r2
```

GitHub Actions 会被 GitHub 在长期无活动时停用；Fork 的工作流也可能需要在 Actions 页启用。本次配置不能保证 GitHub 服务永远持续运行。出现 Actions 报错时，可查看该次运行摘要和日志。

## 能否完全自动升级

源码检查、准备更新 PR、测试和构建已自动化。**合并冲突、新增界面文案的翻译、真实音频设备的兼容性仍需要审核**；没有配置无人审核地合并或自动安装。新版本的可用性还取决于官方改动、Xcode 和设备表现。

当前发布使用本地签名，没有 Apple 开发者证书和公证，也没有设置自有 Sparkle 签名密钥与自动安装源。请从本仓库 Releases 下载定制版，退出旧版本后替换应用；独立配置目录会保留设置。未来如需应用内自动安装，需要另行配置正式签名、公证和自己的更新源。

## 手工合并

```sh
git switch main
git pull --ff-only origin main
git remote add upstream https://github.com/ronitsingh10/FineTune.git  # 已存在则跳过
git fetch upstream main
git switch -c update/official
git merge --no-ff upstream/main
# 如有冲突，保留定制逻辑并解决后提交；不要用官方分支重置 main。
./scripts/build-delay-edition.sh
# 完整测试与翻译检查命令见 .github/workflows/ci.yml。
```

汉化资源位于 `FineTune/Resources/Localizable.xcstrings` 和 `InfoPlist.xcstrings`。新增界面文案需要补充 `zh-Hans` 翻译，使用 `scripts/check-localization.py` 检查占位符与覆盖范围。用户预设、设备名称和第三方耳机型号无需翻译。

保留上游 GPL-3.0 许可证、作者署名及捐赠链接。
