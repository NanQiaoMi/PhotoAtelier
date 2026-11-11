# P3-E 总结报告：真实照片处理质量优化（13 张真实样片）

**日期**：2026-11-11
**计划**：[docs/p3e-real-photo-optimization-plan.md](p3e-real-photo-optimization-plan.md)
**执行**：P3-E1 → E2 → E3 → E4 全部完成；全量测试 **801/801 通过**（真·干净重建后）。

---

## 交付一览

| 批次 | 内容 | 状态 | 验证 |
|---|---|---|---|
| **P3-E1** | 修 `needsFaceMasks` 漏 9 个人脸模块触发 | ✅ | 谓词单测 + 管线注入测试 + 真机探针（3 张人像微雕模块全 applied=true） |
| **P3-E2** | 天空掩码像素证据门禁 | ✅ | 13 张样片标定 10/13 判定正确；14/14 SkyEnhancementTests |
| **P3-E3** | 景深场修复（均匀深度 → 光栅化梯度）+ report 诚实化 | ✅ | 像素级梯度回归测试 + report 近/远半径断言；10/10 BokehBlurTests |
| **P3-E4** | 10 管线 × 13 样片全量审美回归 | ✅ | 260 张对比图 + 画廊 + manifest；零修改审计 PASSED |

## 各批次要点

### P3-E1：人脸门禁修复
- `PhotoEngine.requiresFaceDetection(_:)` 静态谓词为唯一事实来源（补入 P2 微雕 7 模块 + 发色 + 胡青）；
- 新增 [Tests/PhotoCoreTests/FaceDetectionGatingTests.swift](../Tests/PhotoCoreTests/FaceDetectionGatingTests.swift)：触发矩阵（9 修复模块 + 既有触发 + 不应触发用例）+ `preparedMakeupFaces` 注入管线测试；
- 真机探针确认 sample-10/11/12 上 9 个模块从「未检测到可用人脸」变为实际生效。

### P3-E2：天空假阳性治理
- `makeSkyMask` 增加像素证据统计（`measureSkyFraction`，<15% 显式拒绝）；
- 阈值在 13 张真实样片上标定：花田特写/夜景/合成图/逆光人像正确拒绝，风光样片正常接受；错误方向从「无条件增强」转为「亮蓝区域才增强」；
- 修正过关键坑：`CIContext.render` 位图第 0 行是图像**顶部**。

### P3-E3：景深场真实性
- **根因**：内核 `samplerCoord` 产出空间均匀深度图（≈0.75），地面透视从未生效，`depthFalloffRate` 无效；
- **修复**：删除内核，光栅化 64B 对齐线性梯度（行 0 = 图像顶部远景 1.0 → 底部近景 0.35）+ CIColorMatrix（falloff/offset）+ CIBlendWithMask（主体压 0，取掩码 **alpha** 防预乘失真）；
- **report 诚实化**：`BokehBlurReport` 新增 `nearRadius`/`farRadius`（深度场实测采样），note 从常数「最大散焦半径 16.8px」改为「近景 X px，远景 Y px」；
- 验证：合成条纹底部保留度 0.78 → 顶部 0.14；真实样片 08 边缘能量比 0.63/0.38/0.11。

### P3-E4：全量审美回归
- 重编译 `evaluate_aesthetic` 对准新二进制，13 样片 × 10 管线（555s）；
- 产出：[artifacts/p3e-verify/index.html](../artifacts/p3e-verify/index.html)（画廊）+ `aesthetic-manifest.json` + 260 张对比图；
- **零修改审计 PASSED**：源文件处理前后 SHA-256 全部一致；
- 3 张人像样片 10 管线全渲染（含修复后的 P2 微雕页签）。

## 过程中发现并解决的构建环境问题

全量测试期间出现三次随机 SIGSEGV/SIGBUS（崩溃点漂移：AdaptiveDetail/SkyEnhancement/LensTests，均在 `ProcessingReport` 的 retain/copy 处）。**根因是陈旧增量构建产物**：P3-E 修改 `ProcessingReport` 内存布局后，`.build/x86_64-apple-macosx/debug` 中残留 79 个旧代 .o 与 10 个新代 .o 混合链接成损坏二进制。注意 `rm -rf .build/debug` 删的只是符号链接，**必须删 `.build/x86_64-apple-macosx/debug` 真实目录**。真·干净重建后 801/801 全绿，无崩溃复现。

## 遗留与后续

1. **人工评审**：画廊 `artifacts/p3e-verify/index.html` 待人工翻页评审（重点：sample-10/11/12 的 08 微雕、09 景深页签——本次修复的直接受益者）；
2. **参数调优**：若微雕在半身人像上强度不适，按计划 §3 调整回归管线参数并记录到 P1-H 样片矩阵；
3. **天空门禁边界**：湖面高亮偏蓝（sample-10）与白底合成图（13）仍是已知假阳性，启发式固有，如需进一步收敛可引入色相直方图约束；
4. **待提交**：全部 P3-E 改动在工作树（7 个修改文件 + 3 个新文件），等用户确认后提交。
