# 聊天数据流解析修复候选

用户反馈：密钥和余额验证成功，但聊天一直失败，显示“收到的数据流无法解析，已保留收到的内容”。

该错误由聊天流解析阶段抛出，位于 HTTP 状态和 `text/event-stream` 内容类型检查之后。它与 Key 未保存或鉴权返回 401 的错误路径不同。

## 主要嫌疑

旧网络代码使用 `URLSession.AsyncBytes.lines`，而 `SSEDecoder` 必须收到空行才能提交一条事件。文本行适配器若省略空行，多条 `data:` JSON 会积累在同一事件里，最后被拼接成多个 JSON 的字符串，导致解码失败。用户症状与这个缺陷吻合；尚未直接测量用户 iOS 版本中的行适配器行为。

SSE 协议使用空行作为事件分隔，支持 LF、CRLF 和 CR，内容使用 UTF-8。参考：[WHATWG 事件流解析规范](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation)。

## 改动

- 保留原有 `SSEDecoder` 的事件解码逻辑。
- 增加 `SSEByteDecoder`：从原始字节划分行，保留空行；一整行收齐后才解码 UTF-8，处理中文字符跨字节到达的情况。
- `DeepSeekClient.stream()` 改为迭代原始字节，并即时把每个完整事件交给 AppStore。
- 保留停止生成、思考内容、用量统计和 `[DONE]` 完成检查。
- 新增原始字节流回归测试和 Darwin Foundation 适配器诊断。

## 接受标准

1. macOS 上 `swift test --jobs 2` 完整通过。观察 Foundation 诊断输出，确认原来的行适配器能否复现空行丢失和解析失败。
2. `bash scripts/build-ipa.sh` 成功，生成 1.0.2 / build 3 的未签名 IPA。
3. iPhone 上保存现有有效 Key，发送“只回复你好”；能够逐段收到最终回答。
4. 开启深度思考后再次发送，思考内容和正文都能正常显示。
5. 若仍出现解析错误，继续调查真实响应结构；本候选不能代替实际接口和手机验证。
