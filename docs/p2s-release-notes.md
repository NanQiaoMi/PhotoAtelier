# P2-S 发行说明：智能面部唇毛与胡青消除、特征痣管理

## 1. 概述与核心能力
在商业人像与精修领域（对标像素蛋糕 PixelCake / 醒图 / 美图云修），唇周微细毛发、剃须后下颌发青及面部深色特征痣的处理，直接影响客片的通透度与自然质感。
**P2-S** 引入了 100% 离线、原生 Core Image GPU 加速的面部毛发与瑕疵美学引擎：

1. **智能唇毛消除 (`lipFuzzRemoval`)**：
   - 定向识别鼻小柱底至上唇红缘之间的微细暗色桃毛绒毛（Peach Fuzz）；
   - 提取高频暗色毛发并柔和注入邻域健康皮肤光泽与暖色调，消除唇周发脏发暗视觉，同时严格保护唇红缘（Vermilion Border）解剖边缘与皮肤自然毛孔，杜绝塑料蜡像感。
2. **胡青消除与胡茬微粒平滑 (`beardShadowReduction`, `stubbleSmoothing`)**：
   - 剃须后下巴与下颌骨由于皮下毛囊影响往往呈现冷调蓝青色暗沉（Beard Shadow，$\Delta b^* < 0$ 偏蓝、$\Delta L^* < 0$ 偏暗）；
   - 通过与干净面颊基准肤色（Skin Anchor）对比，智能补偿暖红/金黄微量色调并适度提亮，消除发青脏感；
   - 对 1-2px 的硬质胡茬微粒进行频域保边平滑，消除下巴胡茬粗糙颗粒感。
3. **特征痣智能管理 (`moleManagement`, `moleRemovalIntensity`)**：
   - `.preserve`（默认保留）：识别眼周泪痣、唇周美人痣等高对比紧凑特征痣，保留个人辨识度；
   - `.soften`（轻度淡化）：智能压低深色痣 40%–60% 对比度，使其柔和不抢镜，同时保留自然形态；
   - `.remove`（彻底消除）：完全融汇邻域皮肤光影与色彩，彻底抹平色素痣。
4. **多人像分脸覆盖与 Recipe v26 升级**：
   - 支持多人合影中按性别角色或单张人脸设置独立的唇毛、胡青与特征痣参数；
   - 配方版本门禁升级至 26，向后严格兼容旧版配方，支持全链路选择性参数同步。

## 2. API 与数据模型更新

### 2.1 新增数据结构
- `MoleManagementMode`: `.preserve`, `.soften`, `.remove`
- `FacialHairSettings`:
  - `enabled: Bool`
  - `lipFuzzRemoval: Double` (0.0...1.0)
  - `beardShadowReduction: Double` (0.0...1.0)
  - `stubbleSmoothing: Double` (0.0...1.0)
  - `moleManagement: MoleManagementMode`
  - `moleRemovalIntensity: Double` (0.0...1.0)
- `FacialHairReport`
- `AdjustmentSettings.facialHair: FacialHairSettings?`
- `ProcessingReport.facialHair: FacialHairReport?`
- `PersonPortraitProfile.facialHairOverride: FacialHairSettings?`

### 2.2 配方版本门禁
- 配方版本升级至 26：
  - 非中性 `facialHair` 或个人 override 强制要求 `version >= 26`；
  - 旧版配方 `v1...v25` 完全保持原有像素路径不变。

## 3. 性能与验证指标
- **GPU 着色器延时**：基于 Core Image CIColorKernel 单 pass 采样，单帧处理耗时 < 4.5ms（4K 分辨率）。
- **单元测试覆盖**：新增 `FacialHairTests` 10 项测试用例，全量 697 项测试 100% 通过（0 failure）。
