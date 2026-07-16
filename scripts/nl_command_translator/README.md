# Chekinana natural-language command translator

独立的 Python 3 标准库原型：把一条中文需求转换成一条已经实现的 Chekinana 命令。它不依赖 iOS、SwiftData 或 App 运行时，不执行生成的命令，也不写用户数据。

## Commands in the registry

- `help`：显示帮助。
- `confirm`：确认待处理操作。
- `cancel`：取消待确认操作。
- `clear`：清空可见命令记录。
- `addidol`：搜索并准备添加 Idol。
- `listidol`：列出用户已添加的 Idol。
- `showidol`：查看 Idol。
- `editidol`：准备修改 Idol。
- `deleteidol`：准备删除 Idol。
- `scancheki`：把已选择图片创建为仅含图片的临时 Cheki。
- `discardcheki`：丢弃临时 Cheki。
- `addcheki`：从相册选图并为 Idol 准备添加 Cheki。
- `addscancheki`：把扫描临时 Cheki 准备添加给 Idol。
- `listcheki`：列出或筛选 Cheki。
- `downloadcheki`：准备把 Cheki 图片写入系统相册。
- `deletecheki`：准备删除 Cheki。

直接输入八位十六进制确认码会规范化为 `confirm <code>`，不作为第 17 个命令。

## API

```python
from nl_command_translator import translate

result = translate("我想要添加一个名为XX的idol", allow_llm=False)
assert result.command == "addidol XX"
```

结果至少包含：

```text
command, intent, source, confidence, needs_clarification, message
```

`source` 为 `passthrough`、`rule`、`llm` 或 `none`。`allow_llm=False` 是默认值，适合零网络成本和确定性行为。

## CLI

从仓库根目录运行：

```sh
PYTHONPATH=scripts python3 -m nl_command_translator.cli '我想要添加一个名为XX的idol'
PYTHONPATH=scripts python3 -m nl_command_translator.cli --json '把Eriko的颜色改成蓝色'
PYTHONPATH=scripts python3 -m nl_command_translator.cli --allow-llm --json '一条规则无法确定的口语需求'
```

CLI 只打印候选命令或澄清信息，不执行命令。

## Cost-first pipeline

1. 已是合法命令：严格校验并规范化，不调用模型。
2. 中文 normalize：统一空白和常用全角符号。
3. 本地 intent 规则与 slot 提取：模板、同义词、字段别名和保守正则。
4. Registry validator：用 Python 镜像 Swift tokenizer/target/key 行为；拒绝未注册命令、缺失必填参数、未知字段、重复字段、换行、控制字符以及无法由 App parser 无损表示的双引号/反斜杠 slot。
5. 可选 DeepSeek fallback：只有前三层不能确定时调用一次；先在本地裁剪到 top 1–3 个 schema，无候选时才发送全部精简 schema。
6. LRU 结果缓存：同一进程内相同输入不重复计算或付费。

模型固定为 `deepseek-v4-pro`，请求 `https://api.deepseek.com/chat/completions`，无历史对话、thinking disabled、`max_tokens=192`、JSON 输出。API key 优先读取 `DEEPSEEK_API_KEY`；否则只在调用模型时读取仓库根目录的 `apikey.txt`，兼容 raw、`KEY=value` 和简单 JSON。代码和报告不会输出或复制 key。

模型输出必须再次通过相同 registry validator；有本地候选时只能选择最高分 intent，且模型输出的每个 ID、名称和字段值都必须可在原始输入中找到（少量明确枚举映射除外）。敏感或可能写入的命令还要求最高分 intent 达到安全阈值；无本地候选不能生成敏感命令，LLM 生成的无参 `confirm` 永远被拒绝。Usage 三项必须是非负、有限、合理范围内且总数一致的原生整数，否则整个模型建议作废。因此已注册但语义错位的低排名命令、凭空增加的 ID、把“蓝色”翻译成 `blue` 等输出也会被拒绝。模型失败、网络失败、参数不足、多意图、类型错误或输出不安全时统一使用本地固定澄清文案，模型 message 不会展示。

## Tests

```sh
python3 -m py_compile scripts/nl_command_translator/*.py
PYTHONPATH=scripts python3 -m unittest discover -s scripts/nl_command_translator/tests -v
PYTHONPATH=scripts python3 -m nl_command_translator.benchmark
```

离线 benchmark 是确定性 fixture 加参数化生成，共 470 条，覆盖 16 个命令、中文 paraphrase、字段和值、带空格参数、Swift parser round-trip、合法命令透传、缺参、带或不带对象类型的多动作、扫描临时 Cheki 复合动作及多值列表、未知意图和注入样式。报告写入 `outputs/nl-command-translator-20260711/`。

真实模型探索严格限制为 18 个唯一输入、每个输入最多一次请求。首轮困难口语 calibration 为 6/12，短 prompt 调整后的六个新输入为 3/6；合计 3,670 tokens。这个结果说明模型不应成为默认路径。测试暴露的常见表达已提升为本地回归规则，因此当前 18 条均不再需要模型；错误命令也促成了“只能选最高分 intent”和“slot 必须来自原文”两道最终安全门。为了遵守 18 次成本上限，没有为最终安全门重复调用相同输入。完整统计和失败明细在输出目录；任何生成的 Chekinana 命令都没有被执行。

## Current boundary

这是独立实验，不与 App 集成。它只翻译“用户想做什么”，不改变现有 confirm 边界；写入操作仍必须由 App 在后续流程中展示预览并确认。
