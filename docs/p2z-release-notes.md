# P2-Z: 智能全脸骨相立体光影重塑、面部折叠度与 T区/C区/下巴高光阴影精雕 (Release Notes)

## 1. 概述与交付物

在商业级人像精修、时尚杂志封面大片与高端肖像摄影中，“面部折叠度”（Facial Folding Angle）与“3D 骨相立体光影”（Facial Bone Contouring）是决定五官立体紧凑感、头包脸视觉感与肖像高级感的核心要素。
在常规平光拍摄或自然光下，肖像往往面临以下骨相光影痛点：
- **面部扁平大脸（低折叠度）**：正面与侧脸缺少明暗交界过渡，横向视觉拉伸严重，缺乏小巧纵深骨相；
- **T 区平淡无光**：额头中央与鼻梁轴线平坦无光，缺乏中庭挺拔聚光感；
- **C 区暗沉凹陷**：眼眶外侧、太阳穴至颧弓上方缺乏明星红毯级的通透珍珠高光；
- **面颊侧部肉感过重**：颧骨下陷处（Sub-zygomatic hollow）无自然收敛阴影，缺乏超模面部骨骼架构；
- **下颌轮廓与颈部粘连**：下颌骨底缘受光扁平无层次，下颌线切割感不足，甚至伴随下颌松弛阴影；
- **人中唇峰缺少生动细节**：人中嵴平坦、丘比特弓暗淡，下庭比例缺乏幼态立体感；
- **修容发脏发灰**：普通修容容易产生面部脏斑或假白假黑。

**P2-Z** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能全脸骨相立体光影重塑系统**：

- **面部折叠度与骨相紧凑度 (`facialFolding`, 0...1.0)**：增强面部立体折叠度，侧脸光影柔和衰减收敛，正脸垂直中轴光影挺拔突出，使扁平大脸瞬间呈现出小巧紧凑的高折叠度骨相；
- **T 区 3D 立体高光 (`tZoneHighlight`, 0...1.0)**：在额头中央微弧面与鼻梁骨轴线施加物理级珍珠柔焦高光，立体拔高面部中段骨相；
- **双侧 C 区珍珠高光 (`cZoneHighlight`, 0...1.0)**：外眼眶经太阳穴向颧骨上方弯曲的高光弧带，打造影棚闪光灯下的通透水光感与饱满颞颧骨相；
- **面颊侧部微阴影修容 (`cheekContourShadow`, 0...1.0)**：颧下向口角延伸的自然渐变微阴影，收敛宽脸、雕琢超模级面部结构；
- **下颌线下阴影与双下巴视觉收缩 (`jawlineShadow`, 0...1.0)**：沿下颌骨底缘向颈部过渡的立体雕刻阴影，消除由于光线平淡导致的面部与颈部粘连，强化下颌线利落切割感；
- **人中与唇峰立体高光 (`philtrumHighlight`, 0...1.0)**：双侧人中嵴与丘比特唇弓的点缀高光，增强面部下庭精致生动感与幼态立体感；
- **修容光影色温倾向 (`contourToneWarmth`, -0.5...0.5)**：修容阴影与高光的色温倾向调节，正值偏暖金蜜桃更适合暖调肤色，负值偏中性冷茶调防止修容发脏发灰；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点与 Core Image GPU `CIColorKernel` 着色器，零外部模型权重依赖；
- **多人肖像分人独立覆盖**：支持 `PersonPortraitProfile.facialBoneContourOverride` 与 `FacialBoneContourEngine.applyPerPerson`；
- **配方版本门禁升级**：升级至配方版本 33（Recipe v33），旧版本严格守卫。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/FacialBoneContourEngine.swift` (新增) - 骨相几何特征提取（T区、C区、人中、颊凹、下颌缘、折叠区）、双着色器引导蒙版生成与 `facialBoneContourKernel` GPU 光影修容着色器；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `FacialBoneContourSettings`、`FacialBoneContourReport`、配方版本 33 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接（步骤 3k）、设置校验与版本需求推导（版本 33）；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与骨相光影修容面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 全脸骨相光影修容面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/FacialBoneContourTests.swift` (新增) - 14 项单元测试与边界用例；
9. 18 处现有测试文件 - 未来配方版本断言从 33 升级至 34；
10. `docs/p2z-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter FacialBoneContourTests`: **14/14 passed in 0.230s (0 failures)**
- `swift test --filter EyebrowReshapeTests`: **13/13 passed in 3.032s (0 failures)**
- `swift test --filter FacialContourTests`: **13/13 passed in 2.598s (0 failures)**
- 全量测试 `swift test -j 2`: **790/790 passed (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0**
- 静态与签名验证 `python3 Scripts/verify_app.py build/PhotoAtelier.app && codesign --verify --deep --strict build/PhotoAtelier.app`: **Exit code 0**
