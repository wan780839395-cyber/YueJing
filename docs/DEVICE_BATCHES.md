# 设备诊断包：批次冻结与回放

`scripts/device_batches.json` 管理 028–030 和后续 **device-only** 批次；更早的专用发布和 native qualification 不在此合同内。`active: null` 表示当前没有批准的新设备包。工作树的四项开发计划不是 030 已冻结的两项计划，开发作业成功也不是打包凭据。

**下一批次（不改 workflow 或 Python 路由）：**

1. 先审核产品提交 P。其 `project.yml` 必须已有正确版本/构建号；其 `plan_path` 必须已包含本次精确的 `cases`、分支和开发超时预算。计划只写在这一份文件里。对该文件的 Git blob **原始字节**计算 SHA256（不重排 JSON、不转换换行）。
2. 冻结提交 F 以 P 为唯一父提交，只修改 `scripts/device_batches.json`。在 `batches` 追加新的永久批次键，填写 `version`、`build`（字符串）、`product`（P 的完整 SHA）、`plan_sha256`；按需覆盖 `defaults` 中的分支、计划路径、runner、作业和工具准备分钟数。`active` 指向新键，不设 `legacy_source`。修订已冻结的批次时追加新键，不改写旧合同。新批次的 receipt 使用该永久键，而非可移动的 `device-active`。
3. 审核 F 后才可从登记分支显式选择 `device-active`，同名确认，提供 F 的完整 SHA、冻结计划 SHA256，两个 IPA 开关均为 true，前次验证 run 留空。仅首次 attempt 可进入；Linux admission 先校验干净源码、父子关系、版本和计划，输出已审核的主机和时间预算，之后才调度设备作业。设备作业重验合同和实际主机架构；仍只构建 arm64 iPhoneOS 未签名诊断包，不宣称 UI 通过。
4. 使用独立取得的发布 SHA、run ID、IPA SHA256，针对解包后的 **task3-unsigned-ipa** 目录验证。新批次的离线 Git 库须含 F 和 P，才能复核冻结边界；此后切换 active 不影响按永久键回放。

```text
python -B scripts/bookmark_device_package.py verify-batch-download BATCH DIR SOURCE_SHA RUN_ID IPA_SHA256
python -B scripts/check_device_registry.py --artifact-030 EXTRACTED_030_DIR
```

旧的 `verify-download`、`verify-search-download`、`verify-search-return-download` 入口以及旧 receipt、IPA 文件名和证据路径不变。回放按独立摘要、同 run 的设备 gate、Release 全部文件、镜像、未签名状态和许可证校验，不从当前开发计划重新构造历史产物。第二条命令还需本地 Git 历史中的 030 产品及发布对象；负例只篡改临时副本，不修改原包。
