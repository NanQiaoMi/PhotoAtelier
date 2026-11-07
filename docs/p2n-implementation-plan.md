# P2-N 实施计划：智能眼神光、眼镜去反光、眼白去红血丝与牙齿美学精修

## 1. 目标与背景

在商业修图（婚纱摄影、肖像写真、商务形象照、家庭合影）中，眼部与牙齿是决定人物神采与亲和力的核心关注点。目前系统已有基础牙齿美白与眼白提亮（v10）以及基础眼影/眼线妆容（v13/v14），但仍存在以下突出痛点：
1. **眼镜反光干扰**：佩戴眼镜的被摄者极易在镜片表面产生白色反光斑块或泛白雾化，遮挡瞳孔与眼神；
2. **眼白充血与浊黄**：疲劳导致的红血丝、微血管和眼白偏黄无法自动消除，影响纯净神采；
3. **眼神空洞缺乏生机**：平光或背光拍摄时缺乏立体眼神光，虹膜平淡无层次；
4. **牙齿假白与瑕疵**：传统全局牙齿美白容易导致牙齿死板假白、缺乏天然半透明珐琅质光泽，且牙面烟茶渍、食物微残渣或边缘口红印无法自动净化；同时可能过度漂白牙龈，破坏健康的粉红牙龈对比。

本里程碑交付 **P2-N 智能眼神光、眼镜去反光、眼白去红血丝与牙齿美学精修系统 (Smart Eye Clarity, Eyeglass Anti-Glare, Sclera Bloodshot Removal & Aesthetic Teeth Restoration)**。

---

## 2. 交付物与功能清单

1. **数据模型 (`Models.swift`)**:
   - `EyeCatchlightPattern` 枚举：`.off`、`.naturalPoint`（自然单点光）、`.ringLight`（环形柔光）、`.softboxSquare`（方形柔光箱）、`.dualStrip`（双侧条形光）、`.butterfly`（蝶形顶光）、`.starburst`（璀璨星芒光）。
   - `EyeTeethRefinementSettings` 结构体：
     - `enabled: Bool`
     - 眼部调节：
       - `eyeglassGlareReduction: Double` (0...1)
       - `scleraBloodshotRemoval: Double` (0...1)
       - `irisClarity: Double` (0...1)
       - `catchlightPattern: EyeCatchlightPattern`
       - `catchlightStrength: Double` (0...1)
       - `catchlightScale: Double` (0.5...2.0，默认 1.0)
     - 牙齿美学调节：
       - `teethStainRemoval: Double` (0...1)
       - `enamelSheen: Double` (0...1)
       - `gingivaProtection: Double` (0...1，默认 0.8)
   - `AdjustmentSettings` 增加 `eyeTeeth: EyeTeethRefinementSettings?`。
   - `PersonPortraitProfile` 扩充 `eyeTeeth: EyeTeethRefinementSettings?` 支持多人分组独立精修。
   - 升级配方版本门禁至 21（`Recipe.validateVersion()` 支持 v21）。

2. **核心算法引擎 (`EyeTeethRefinement.swift`)**:
   - 基于 Vision 地标（眼眶、虹膜/瞳孔中心、眼白外轮廓、嘴唇轮廓与牙齿区域）计算：
     - **眼镜去反光 (Eyeglass Glare Reduction)**：在镜片推断区域检测高明度反光斑，结合周围虹膜与肤色平滑重建中和，消除镜片白雾；
     - **眼白去红血丝 (Sclera Bloodshot Removal)**：精准定位眼白区域，识别红色微血管与黄色浊斑，利用保边滤波净化眼白底色；
     - **虹膜明眸与眼神光雕刻 (Iris Clarity & Catchlight Rendering)**：瞳孔中心自适应定位，程序化矢量光栅化 6 款摄影级眼神光斑，支持平滑混合与高光光泽叠加；
     - **牙齿污斑净化与珐琅质微光 (Teeth Stain Removal & Enamel Sheen)**：牙面孤立色斑/唇红印记平抚，牙龈粉红区域边界保护，迎光面重注入天然珐琅质半透明光泽。

3. **渲染管线集成 (`PhotoEngine.swift`)**:
   - 在主渲染管线中执行眼部与牙齿美学精修；
   - 完整支持多人独立精修（`multiPerson`），允许对不同人物设置不同眼神光与牙齿清洁强度。

4. **参数选择性同步与批量管理 (`AdjustmentSync.swift` & `SelectiveSyncSheet.swift`)**:
   - 增加 `eyeTeeth: Bool = true` 勾选项。

5. **UI 交互 (`PortraitRetouchPanel.swift` & `AppModel.swift`)**:
   - 「人像」面板新增「明眸、反光与牙齿精修」模块；
   - 包含眼神光图案选择器、各项微调滑杆；
   - 选中具体人物时自动切换至该人物的独立配置。

6. **测试与质量保证**:
   - 单元测试：`Tests/PhotoCoreTests/EyeTeethRefinementTests.swift`；
   - 历史测试前向兼容断言更新（未来版本从 21 递增至 22）；
   - 全量 638+ 测试回归与 Universal 原生应用打包校验。

---

## 3. 验收标准（可勾选）

- [ ] `EyeTeethRefinementSettings` 正确序列化与反序列化，中性设置不改变像素；
- [ ] 6 款眼神光图案准确居中于左右眼瞳孔并支持缩放与旋转适应；
- [ ] 眼镜高光反光在测试图片上显著被抑制且瞳孔细节得到恢复；
- [ ] 眼白红血丝有效消退，同时眼皮交界与瞳孔边缘不受侵蚀；
- [ ] 牙齿局部茶渍/唇膏印净化，且牙龈粉色区域得到严格保护；
- [ ] 珐琅质自然光泽有效恢复，避免死白假牙感；
- [ ] 非中性 `eyeTeeth` 设置受 Recipe Version 21 门禁保护；
- [ ] `swift test -j 2` 全量测试通过；
- [ ] Universal 双架构 App 构建并通过 `verify_app.py` 签名校验；
- [ ] Git 流程遵循 Rule 3（`--no-ff` 合并、验证命令与结果、删除分支）。
