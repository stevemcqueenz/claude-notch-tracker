# 多 Provider 架构

当前应用同时支持 Claude 与 Codex。界面只依赖统一的 `ProviderUsageSnapshot`，各 Provider 负责把自己的数据映射为限额、统计、会话和状态信息。

## Claude

Claude Provider 保留原有行为：

- 从 Claude Desktop、浏览器或 Claude Code 登录态读取账户限额；
- 从本地 Claude 日志计算当天与历史 token、成本和会话；
- 支持 5 小时、7 天、Fable 限额与成本预测。

## Codex

Codex Provider 只使用官方 `codex app-server` JSON-RPC 接口：

- `account/read`：读取登录类型和套餐；
- `account/rateLimits/read`：读取动态限额窗口、重置时间和 credits；
- `account/usage/read`：读取当天与历史 token；
- `thread/list`：读取最近任务。

应用不会解析 `~/.codex/sessions` 私有 JSONL，也不会根据 token 估算 Codex 美元成本。ChatGPT 登录可以提供账户 token 统计；仅 API key 登录时，官方接口不会返回账户级用量，界面会明确提示这一限制。

默认从以下位置寻找 Codex 可执行文件：

1. `CODEX_NOTCH_BINARY` 指定的路径；
2. ChatGPT 或 Codex 应用内置的可执行文件；
3. Homebrew 常见路径；
4. 当前 `PATH`。

## 刷新与切换

左侧图标可在 Claude 与 Codex 之间切换，右键菜单也提供显式 Provider 选择。选择会持久化。应用只轮询当前 Provider，切换后立即刷新，避免后台持续启动不需要的服务。

## 验证

运行完整测试：

```bash
swift test
```

在已经登录 Codex 的机器上运行真实 app-server 集成测试：

```bash
CODEX_NOTCH_RUN_INTEGRATION_TEST=1 swift test --filter liveAppServerExchangeWhenRequested
```
