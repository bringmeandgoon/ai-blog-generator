# Dev Blog Platform - Claude Code 工作规范

## 语言偏好
- 回复用简洁中文，技术术语保留英文
- 不要过多解释性文字，直接给方案和代码

## 修改代码的工作流

### 1. 改之前：先全局搜依赖链
- 修改任何函数/变量/类型之前，先 `grep` 找出所有引用方
- 列出完整的改动文件清单，然后一次性全改
- 禁止"改一个发现一个"的逐步模式

### 2. 改完后：立即验证构建
- 每轮修改完成后，必须跑 `npm run build`
- 如果有错误，立即修复，循环直到 build 通过
- 不要等所有文件都改完才验证

### 3. 调试问题：并行排查，不要逐个试
- 遇到不确定的问题（如网络/SSL/兼容性），一次性并行测试多个变量
- 先系统性缩小范围（是哪一层的问题），再深入具体原因
- 避免每轮只改一个变量、来回多轮的低效模式

### 4. 删除代码要彻底
- 移除功能时，grep 清理所有引用（import、调用、配置、类型）
- 不要注释保留死代码，直接删除
- storage key、env var、配置项一并清理

## ⛔ 严禁改动的核心架构

### 4 步 Pipeline（绝对不能合并/删除任何一步）
```
Search → Architect → Write → Rewrite+QC
```
对应的 job phase 和 status：
1. `phase: (initial)` → `status: review` — 用户审核 sources
2. `phase: architect` → `status: outline_review` — 用户审核 outline
3. `phase: generate` → `status: write_review` — 用户审核草稿
4. `phase: rewrite` → `status: done` — 完成

**禁止任何理由合并步骤（如"architect merged into write"）。这是重大事故。**
修改任何 pipeline 相关代码（server.js confirm 端点、skillCaller.js pollJob、KeywordInput.jsx handleResult）之前，必须先确认 4 步流程完整保留。

## 项目架构
- 文章生成：前端 → Express backend → job queue → worker.sh → `claude -p` (Claude Code CLI)
- TUN 模式：所有出站请求不用 proxy flag，unset proxy env vars，ClashX Pro TUN 透明代理

## 构建命令
- `npm run build` - 构建验证
- `npm run dev` - 启动 Vite dev server
- `./start.sh` - 启动全部服务（worker + server + vite）
