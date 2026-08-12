# BeeCount Accessibility Rules

这是 BeeCount Android 无障碍记账的独立适配规则仓库。BeeCount 从本仓库下载并严格解析 `rules.json`，因此在既有 Schema 能力内新增 App 或页面适配时，用户只需要在 BeeCount 的自动记账设置中点击“更新适配规则”，不需要重新安装 APK。

规则只能描述包名、Activity 范围、页面节点匹配、交易容器和金额/文本字段提取。它不能执行代码、点击或输入界面、申请权限，也不能上传账单数据。下载、解析或版本校验失败时，BeeCount 保留当前有效规则；没有有效远程规则时使用 APK 内置规则。

## 仓库结构

```text
rules.json                         BeeCount 实际下载的唯一发布文件
schema/rules-v2.schema.json        Android 运行时 Schema v2 的静态结构约束
schema/ai-analysis.schema.json     AI 快照分析结果格式
prompts/analyze-gkd-snapshot.md    固定的 AI 分析提示词
tool/import_snapshot.dart          导入并脱敏 GKD ZIP
tool/sanitize_snapshot.dart        单独脱敏 JSON 的辅助工具
snapshots-local/                   本地分析工作区，已被 Git 忽略
```

`rules.json` 是发布源，不要手工维护另一份可产生分歧的规则副本。

## 完整适配流程

### 1. 用 GKD 获取正确页面

在目标 App 中打开真实页面后用 GKD 导出快照 ZIP。正向快照应该是单笔、状态已完成、金额明确的支付结果页或账单详情页。

同时采集容易误判的负向页面，例如：

- 订单/账单列表和包含多笔交易的页面；
- 待付款、支付中、输密码、失败、取消或交易关闭页面；
- 退款中、退款成功等不应自动记为新支出的页面；
- 同一页面在不同 App 版本或不同支付场景下的变化。

只有一个正向快照通常不足以安全发布规则。至少用一个正向页面和相关负向页面检查误判风险。

### 2. 导入到本地工作区

在本仓库根目录运行：

```powershell
dart pub get
dart run tool/import_snapshot.dart "C:\path\目标页面.zip"
```

也可以指定本地输出根目录：

```powershell
dart run tool/import_snapshot.dart "C:\path\目标页面.zip" --output "D:\private\beecount-snapshots"
```

默认输出到 `snapshots-local/<snapshotId>/`：

- `summary.json`：包名、Activity、App 版本、屏幕尺寸和节点数量；
- `nodes.json`：脱敏后的节点树，使用 `id`/`pid` 保留父子关系；
- `privacy-report.json`：脱敏发现和人工隐私复核提示；
- `screenshot.png` 或 `screenshot.jpg`：原快照截图，仅供本机人工对照。

导入器会检查重复节点 ID 和不存在的父节点。它会脱敏常见手机号、邮箱、身份证、银行卡/订单/账号长数字以及带标签的姓名和地址，但自动处理不能证明文件已经适合公开。

### 3. 人工初查节点

先打开 `summary.json`，确认以下内容确实属于采集时的 App 和页面：

- `packageName` 是目标 App 包名；
- `activity` 与页面相符；
- App `versionName`/`versionCode` 已记录；
- `nodeCount` 非零。

再打开 `nodes.json`，结合本机截图检查：

- 页面完成状态由哪些静态节点证明；
- 屏幕上总共有多少金额，每个金额是什么含义；
- 目标金额能否唯一归属于单笔交易；
- 商户、备注、支付方式、时间分别在哪个节点；
- 是否存在能唯一定位交易区域的父容器；
- 哪些文字属于动态数据，不能写进页面锚点。

GKD 节点与 BeeCount 选择器大致对应如下：

| GKD `nodes.json` | BeeCount v2 选择器 |
| --- | --- |
| `attr.text` | `textEquals` / `textContains` / `textRegexes` |
| `attr.desc` | `descriptionEquals` / `descriptionContains` / `descriptionRegexes` |
| `attr.id`（必要时结合 `attr.vid` 人工确认） | `viewIdEquals` / `viewIdContains` / `viewIdRegexes` |
| `attr.name` | `classNameEquals` |
| `id` / `pid` | `scope.ancestorLevels` 和字段 `node.relation` 的结构依据 |

GKD 与 Android 无障碍运行时的节点暴露可能因系统、WebView 和 App 版本不同而变化，因此这个对应关系必须在真机上复测，不能只看快照推断。

### 4. 用固定提示词让 AI 分析

把以下三项交给 AI：

1. `prompts/analyze-gkd-snapshot.md` 的完整正文；
2. 当前快照的 `summary.json`；
3. 当前快照的 `nodes.json`。

不要把原始 ZIP、原始 GKD JSON 或截图交给不受信任的外部 AI。AI 必须输出符合 `schema/ai-analysis.schema.json` 的纯 JSON，并给出以下三种决定之一：

- `ready_for_human_review`：证据支持单笔完成交易，并附 `ruleDraft`；
- `needs_more_snapshots`：页面可能可适配，但证据不足；
- `reject`：列表、多笔交易或其他不应识别的页面，`ruleDraft` 必须为 `null`。

AI 输出是候选材料，不是已验证规则。AI 不能替代真机验证，也不能自行决定发布。

### 5. 人工审核 AI 结果

逐项核对 AI 引用的节点 ID 和实际节点内容，至少确认：

- 页面确实是一笔已完成交易，不是仅凭“支付”或“订单”文字猜测；
- `transactionType` 的收入/支出方向正确；
- 所有金额均已列出，目标金额唯一且不是商品单价、优惠、退款或历史订单金额；
- `pageMatch.all/any/none` 能区分正向页和负向页；
- `scope` 最终只得到一个交易容器；
- 金额与字段的相对节点规则最终只得到一个候选；
- 动态商户、商品名、金额、时间、订单号没有被当作静态页面特征；
- 正则不包含敏感值，也不会宽泛到匹配任意数字。

任何关键项目为 `unknown` 或 `fail` 时都不要发布。应补采快照、修改候选并重新审核。

### 6. 添加 App 和页面规则

打开根目录的 `rules.json`：

- 已存在 App：把审核后的页面规则加入对应 App 的 `rules` 数组；
- 新 App：新增完整 App 对象，并将 `defaultEnabled` 明确设为 `false`，让用户更新后自行开启；
- `packageName` 必须唯一，App `id` 必须唯一，同一 App 内页面规则 `id` 必须唯一；
- `activityIncludes` 为空表示不限制 Activity；设置后使用的是大小写不敏感的“包含”判断，应避免写过短的片段；
- 每个 App 最多 20 条页面规则，整个文件最多 50 个 App。

新 App 元数据片段如下。发布对象还必须包含至少一条已经审核的 `rules` 页面规则：

```json
{
  "id": "example_pay",
  "packageName": "com.example.pay",
  "displayName": "示例支付",
  "defaultEnabled": false,
  "activityIncludes": ["PaymentResultActivity"]
}
```

页面规则的核心能力：

- `requiredAnchors`：每一项都必须在交易容器文本中出现；
- `anyAnchors`：至少一项必须出现；
- `excludedAnchors`：任一项出现即拒绝；
- `pageMatch.all/any/none`：用文本、描述、view ID 和 class 精确判断页面；
- `scope.selector`：直接定位唯一交易容器；
- `scope.anchor` + `ancestorLevels`：从唯一锚点向上找到容器；
- 字段 `node.selector` + `relativeTo` + `relation`：按节点关系提取值；
- `requireUnique`：默认为 `true`，候选不唯一时拒绝识别。

无 `node` 的旧式字段规则仍可使用标签、正则和金额前后节点范围，但新规则应优先选择唯一容器和相对节点，降低列表页误判。

### 7. 校验和测试

先运行规则仓库的静态分析与测试：

```powershell
dart analyze
dart test
```

然后运行仓库提供的规则校验命令：

```powershell
dart run tool/validate_rules.dart rules.json
```

`schema/rules-v2.schema.json` 描述静态格式；最终权威仍是 BeeCount Android 的 `RecognitionRuleCodec` 和 `PaymentRecognitionEngine`。JSON Schema 无法独立保证重复 App/规则 ID、正则安全限制、容器实际唯一和页面行为正确，因此发布前还必须在 BeeCount 仓库运行 Android 规则解析/识别测试，并在真机对正向与负向页面回归。

### 8. 递增规则版本

所有发布内容验证完成后，把根级 `rulesVersion` 增加到一个比线上版本更大的正整数。不要复用或降低版本号。

BeeCount 只接受比设备当前活动规则更新的版本；同版本但内容不同不会作为更新安装。`schemaVersion` 当前固定为 `2`。新增 v2 范围内的 App/页面不需要新 APK；只有引入运行时不支持的新字段或新行为时，才需要先升级 BeeCount APK 和 Schema。

### 9. 发布

发布前最后确认：

- `rules.json` 是有效 UTF-8 JSON，大小不超过 512 KiB；
- `schemaVersion` 为 `2`，`rulesVersion` 已递增；
- 新 App 的 `defaultEnabled` 为 `false`；
- 正向、相似页和负向页测试都通过；
- 提交内容里没有 `snapshots-local/`、ZIP、截图或真实账单数据；
- Git diff 只包含预期的规则、Schema、文档、工具或已审核测试资料。

合并并推送到 `main` 后，BeeCount 从以下固定 HTTPS 地址下载：

```text
https://raw.githubusercontent.com/PredatorMan/BeeCount-Accessibility-Rules/main/rules.json
```

等待 GitHub Raw 内容可访问后，在 BeeCount 中进入自动记账设置，点击“更新适配规则”。确认界面显示新的活动版本，再打开已适配的单笔完成交易页面做真机验证。更新失败时 BeeCount 会继续使用上一次有效规则或内置规则，不应反复覆盖本地规则文件。

## 淘宝快照的当前结论

已导入的淘宝快照来自淘宝“全部订单”列表，而不是单笔订单详情。屏幕同时存在多个订单、商品价格和“实付款”等多个金额候选。

因此这份快照不能生成或发布淘宝正向识别规则。它只能在本地作为多订单歧义的负面分析材料，或在彻底人工脱敏后制作负向测试 fixture。要适配淘宝，必须重新采集单笔订单详情/支付完成页面，并同时保留这类订单列表用于验证规则不会弹窗。

## 隐私与提交政策

以下文件绝不提交到 Git，也不要上传到 Issue、PR、聊天或公开网盘：

- GKD 原始 ZIP；
- 原始 GKD JSON；
- 自动导入保留的截图；
- `snapshots-local/` 和其他本地分析工作区；
- 包含真实姓名、地址、电话、账号、卡号、订单号、商品或交易信息的文件。

`privacy-report.json` 中的 `safeToCommit` 固定为 `false`，因为工具不能可靠地自动遮盖截图，也不能穷尽所有业务敏感信息。发现数为 0 不等于安全。

只有为了自动测试确有必要时，才可以从脱敏节点数据制作最小 fixture。它必须经过人工逐字段复核，删除截图和无关节点，把所有个人与交易值替换成明显虚构的数据，并由代码审核者再次确认后提交。规则本身也不得包含从真实账单复制的姓名、地址、账号、订单号或金额。
