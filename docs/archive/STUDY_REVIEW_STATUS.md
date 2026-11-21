# 1.36.0 学习功能审阅入口

状态（2026-11-12）：按用户要求同步到主分支，供源码审阅。已有升级后旧记录不可见的问题报告，原因与恢复方案尚未确认。本版不能被视为已完成真实升级安全验收。

## 目标

在现有 Sermo 上新增聊天学习功能，必须保留原有聊天、项目、设置、书架和其他功能。三个内置学习项目是新增项，绝不代表用户只需要三个项目。

## 源码位置

- [完整工程 QingJian/](QingJian/)
- [AppStore 启动和持久化](QingJian/DeepSeekPocket/AppStore.swift)
- [原有聊天文件读写](QingJian/DeepSeekPocket/Services/AppPersistence.swift)
- [快照编解码与校验](QingJian/DeepSeekPocket/Core/Models.swift)
- [学习项目初始化](QingJian/DeepSeekPocket/Core/StudyMemory.swift)
- [学习备份的范围选择与恢复](QingJian/DeepSeekPocket/Core/StudyBackup.swift)
- [自动聊天备份](QingJian/DeepSeekPocket/Services/BackupFolder.swift)
- [按需操作手册设计草案](QingJian/AI_OPERATION_MANUAL_PLAN.md)

`QingJian/` 与 `source-manifest.json` 逐文件核对一致，与现有原始ZIP加overlay重建的版本一致。CI可以直接核验展开源码；若只有压缩包，重建脚本仍可工作。源码改变后须同步更新overlay和manifest，不允许脚本静默覆盖工作区修改。

## 已完成的开发范围

聊天背词、逐段阅读、历史政治现场与练习、按项目隔离的学习数据、纠正历史、周报版本、可复制的今日语音复习提示词、包含图片实体的学习备份与恢复；图片容量预警、压缩副本与明确缺图的保底备份。

项目人格和固定指令由用户编辑。按需操作手册仍为设计草案，未新增全局规则注入或运行时手册读取工具。同ID不同资料内容的自动版本迁移仍未实现。

## 升级异常调查边界

确认的代码风险：

1. `AppStore.init` 在读取原有 `conversations.json` 前准备学习数据库并检查恢复日志，两者处于同一个错误处理块。新模块准备失败可能阻止旧快照读取。该路径会设置 `canPersist=false`，不能据此直接断言发生了覆盖或删除。
2. `AppSnapshot.decode` 有50MiB读取上限，`encoded()`没有对应的输出总大小限制。需要检查实际旧文件大小，不能把这一可能性当作已经确认的事故原因。
3. `BackupFolder` 按日期写文件，同日重新备份会覆盖同名备份。调查时应先保护已有文件，不能把新初始化后的备份当作旧数据恢复依据。
4. 学习备份只包含学习项目范围，原有聊天备份是全量聊天快照。需分别检查，不能因为学习备份只有三个项目就断言全量数据已删除。

现有244项Swift核心测试与Release编译通过，但 `Package.swift` 排除了 `AppStore.swift` 和UI，未完成带真实旧数据的完整App覆盖升级验收。这是必须补齐的验证缺口。

调查和恢复时：先只读保存原文件及大小/哈希，区分“未读取”“被覆盖”“安装数据位置改变”；未经用户明确同意，不修改、移动、删除或覆盖手机原文件，不把真实聊天和凭据放入公开仓库或CI。不要在没有证据时承诺恢复成功。

## 编译证据与后续工作

该源码对应1.36.0（66）：[最终开发分支编译与核心测试](https://github.com/2974580042lx-crypto/qingjian-ios/actions/runs/43071527726)。这不代表手机升级故障已解决。

在旧数据问题查清前，停止新功能开发。后续优先处理旧数据保全、事故根因与升级兼容，不用新功能测试代替完整升级验证。
