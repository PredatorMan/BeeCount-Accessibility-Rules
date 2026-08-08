# BeeCount Accessibility Rules

这是 BeeCount 无障碍记账的独立适配规则仓库。用户在 BeeCount 中点击“更新适配规则”后，应用会下载并验证 `rules.json`，不需要重新安装 APK。

规则只能描述以下内容：

- App 包名和可选 Activity 范围
- 账单页面必须、任一和排除文本锚点
- 金额、商户、备注、付款方式、时间和订单号提取规则

规则不能执行代码、点击界面、输入内容、申请权限或上传账单数据。BeeCount 内置规则始终作为离线兜底；下载、解析、版本校验失败时继续使用上一次有效规则。

## 发布规则

1. 根据 BeeCount 生成的脱敏诊断快照确认页面结构。
2. 修改 `rules.json`，递增整数 `rulesVersion`。
3. 确保新增 App 使用 `defaultEnabled: false`，由用户更新后主动开启。
4. 在 BeeCount 仓库运行 Android 规则解析和识别测试。
5. 提交并推送到 `main`。用户随后可在设置页手动更新。

规则地址：

```text
https://raw.githubusercontent.com/PredatorMan/BeeCount-Accessibility-Rules/main/rules.json
```

## 版本约束

- 当前 `schemaVersion`：`1`
- `rulesVersion` 必须是正整数，且不能低于设备当前使用的版本。
- 每个 App 最多 20 条页面规则，整个文件最大 512 KiB。
- 新的 schema 能力仍然需要发布新版 APK；同一 schema 内新增 App 和页面适配不需要。

## 隐私

提交测试资料前应移除姓名、完整卡号、订单号和其他个人信息。规则仓库不接受真实账单快照。
