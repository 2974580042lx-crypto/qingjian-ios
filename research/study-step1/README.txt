Sermo 学习通道最小验证

本目录仅用于第 1 步的隔离实验。正式 iOS 集成从后续步骤开始。

文件
probe_core.py 负责严格解析、项目范围、出处校验和事务提交。
run_probe.py 使用用户本地 Key 发送 DeepSeek SSE 请求，比较原生工具与普通文本 JSON。
test_probe.py 检查执行权限、重试、纠正冲突、失败回滚和分片解析。
evidence 保存无账号凭据的基线、真实测试返回与合成测试数据库。
第1步验收报告.txt 记录结论、边界和用户验收项。

运行本地检查
python -m unittest -v test_probe

运行真实短测试
python run_probe.py --key-file <仓库外的Key文件> --output <一个尚不存在的结果目录>

该命令会发送 12 次短请求，会消耗所用 DeepSeek 账号的 Token。测试采用 deepseek-flash，关闭思考。
结果目录必须不存在，避免覆盖旧证据。服务端返回失败时保留已完成步骤，输出失败类型。
测试材料为自编词义练习，实际项目、个人对话和真题不会被脚本读取。

原生工具路径使用 /chat/completions、tools 和 SSE。
普通文本 JSON 路径只要求模型输出 action 与 arguments，不发送 response_format。
两种方式均先完整接收、校验，再提交本地事务。每个操作提交后才发送实际执行结果，让模型继续作答。
本实验每轮意图是已知的，应用按测试场景绑定允许动作和出处。开放聊天中的意图判定仍需后续设计。

实现参考
https://api-docs.deepseek.com/guides/tool_calls/
https://api-docs.deepseek.com/guides/json_mode/
https://github.com/Britneycode/dsh-fish-soul
https://github.com/mem0ai/mem0
https://github.com/letta-ai/letta-code
