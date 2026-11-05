# P1-F Release Notes: 妆容与人像精修增强 (Makeup & Retouch Enhancement)

> 版本: P1-F (feat/p1f-makeup-retouch-enhancement)  
> 日期: 2026-11-05  
> 状态: 已验证通过  

---

## 1. 概览 (Overview)

P1-F 是对 PhotoAtelier 人像修图管线的重要精修能力升级。在 P1-C 基础人像妆容（唇色、眉毛、腮红、眼影）的基础上，针对眼部细节精修与面部三维立体塑颜需求，引入了六大高精阶段与配方版本 14 门禁机制：
1. **眼部精修扩展 (Eye Makeup & Iris Refinement)**：
   - 上眼线 (`eyelinerIntensity`, `eyelinerColor`)：沿上眼睑轮廓精确描绘，欧几里得折线距离场光栅化与双边羽化，自然加深睫毛根部与眼睑线条。
   - 浓密睫毛 (`eyelashIntensity`)：沿上眼睑向外适度扩展自然暗化浓密。
   - 美瞳与虹膜润色 (`irisIntensity`, `irisColor`)：精确锁定瞳孔坐标与虹膜半径，支持彩色隐形眼镜/虹膜色泽润色，严格限制在眼部多边形内，杜绝外溢至眼白与眼皮。
   - 眼神光提亮 (`catchlightIntensity`)：瞳孔上方高光点微聚光提亮，唤醒肖像眼神神采。
2. **立体高光与面部修容 (Highlight & Contour)**：
   - 面部高光 (`highlightIntensity`)：T区（鼻梁、额骨中段）及苹果肌受光面微光柔焦提亮，与皮肤底色自然融合。
   - 暗部修容 (`contourIntensity`)：下颌骨边缘及侧颊轮廓适度加深，塑造紧致立体轮廓。
3. **严格静默降级门禁与版本 14 配方体系 (Recipe v14 Gating)**：
   - 配方系统升级至版本 14，`Recipe.validateVersion` 增加 v14 门禁。
   - 当使用眼线/睫毛/美瞳/眼神光/高光/修容任意增强参数时，要求配方版本 14；全中性状态保持完全像素透明（100% byte & pixel transparent）。
   - 向后兼容解码：旧版本导出的 JSON 配方在反序列化时自动填补安全默认值。
4. **UI 精细化集成**：
   - 重新架构 SwiftUI 妆容控制面板，按「唇色与腮红」、「眉毛与眼部精修」、「瞳孔眼神与面部立体塑颜」三大逻辑分组组织，消除 ViewBuilder 10 视图上限，无人脸时安全禁用。

---

## 2. 核心交付功能 (Delivered Capabilities)

### F1. 上眼线与睫毛浓密 (Eyeliner & Eyelash)
- **欧几里得距离场算法**：利用 Vision 面部地标的眼部闭合环 (`leftEye`, `rightEye`) 提取上眼睑控制点，按 X 轴拓扑排序构建折线段，通过二维点线段最短欧氏距离算法（`distanceToSegment`）光栅化平滑自然的眼线遮罩。
- **参数控制**：`eyelinerIntensity` 控制眼线显色浓度，`eyelinerColor` 支持黑、棕、灰等定制化眼线色调；`eyelashIntensity` 控制睫毛区域自然深邃浓密。

### F2. 美瞳与眼神光润色 (Iris Tinting & Catchlight)
- **虹膜双层保真遮罩**：基于 `leftPupil` 与 `rightPupil` 位置，计算自适应眼球大小的圆形虹膜区域，并与整个眼部轮廓多边形执行相乘裁剪（`multiplyMasks(irisMask, eyeMatte)`），确保无论眼睑开合多小，美瞳色相绝对不会溢出到眼皮。
- **眼神光反射提亮**：在瞳孔稍偏上方模拟自然漫反射微高光，使暗淡无神的眼神瞬间充满神韵。

### F3. 面部立体高光与修容 (Highlight & Contour)
- **T区与苹果肌高光**：根据鼻梁中心线、额骨中央及双侧颧骨中高点绘制多椭圆高斯羽化高光层，提升面部纵深感。
- **下颌线与侧颊暗影修容**：沿下巴底部及左右侧面部轮廓绘制深色柔化遮罩，自然收缩下颌视觉线条。

### F4. 配方体系与兼容性保全
- **静默降级门禁**：若配方中包含非中性的增强妆容参数，但配方版本低于 14，则显式抛出 `AtelierError.invalidConfiguration`，杜绝任何静默丢弃效果或参数的不可逆降级。
- **绝对中性保真**：当参数全中性（强度为 0）时，`isNeutral == true`，妆容阶段完全旁路（no-op），输出像素与输入保持 100% 逐位一致。

---

## 3. 测试与验证 (Verification Summary)

- **MakeupEngineTests 新增专项测试**：
  - `testEyelinerAndEyelashLocalization`: 验证眼线与睫毛沿上眼睑的定位与局部渲染像素变化。
  - `testIrisAndCatchlightEnhancement`: 验证美瞳色调与眼神光在瞳孔区域的显色，以及眼部外围像素保持不变的防溢出特性。
  - `testFaceHighlightAndContourLocalization`: 验证 T 区高光提亮与下颌轮廓阴影加深的局部精确性。
  - `testRecipeVersion14GateAndSilentDowngradeBan`: 验证配方 v14 版本门禁与防静默降级。
  - `testBackwardCompatibilityOfDecodedJSON`: 验证旧版本 v13 JSON 配方能安全反序列化并自动补全中性默认值。
- **全项目测试套件**：全量 540 项单元测试全部通过（0 失败）。
- **打包验证**：`bash Scripts/build_app.sh` 编译 Release 构建、自签名及依赖打包全部通过。
