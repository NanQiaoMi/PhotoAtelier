# P2-I 智能宠物精修与写真美化 (Smart Pet Enhancement / Pet Portrait Retouching) 发布说明

## 1. 概述 (Overview)

在商业摄影影楼与独立摄影工作室中，宠物写真（猫咪、狗狗肖像）以及人宠合影（婚纱人宠照、家庭写真、宠物生日写真）已成为高增长的核心摄影品类。商业修图软件（如像素蛋糕「宠物美化」）将宠物专属美化列为核心功能。传统的人像精修仅识别人类五官与皮肤，遇到宠物时无法定位五官，传统的磨皮与调色常导致宠物毛发糊成一片、细节丢失或双眼发黑无神。

**P2-I** 引入了**智能宠物精修与写真美化引擎 (`PetEnhancementEngine`)**：
- **纯原生、离线、零外部 AI 模型依赖**：基于 Apple Vision 框架内建的 `VNRecognizeAnimalsRequest`（macOS 10.15+ 原生支持，支持 Cat / Dog 目标识别与边界定位），配合 Core Image GPU 着色器 (`CIColorKernel`)；
- **五大宠物写真专项精修维度**：
  1. **毛发蓬松与质感增强 (`furFluffiness`)**：微观毛流频段对比度提升，使被闪光灯压扁或镜头柔化的毛发呈现根根分明、丰盈蓬松的质感；
  2. **明眸提亮与眼神光聚焦 (`eyeBrightening`)**：精准定位宠物眼眶区域，提亮晶状体暗部并凸显眼神光高光，令宠物双眸清澈灵动；
  3. **鼻吻润泽与立体反差 (`muzzleMoisture`)**：加深猫狗鼻头及吻部暗部层次，凸显湿润水光质感，消除干瘪与反光灰蒙感；
  4. **毛发去灰与纯正色泽提升 (`coatDehaze`)**：消除环境光散射及逆光产生的灰蒙蒙雾感，还原毛发深黑、金黄、银灰的原生纯度与饱和度；
  5. **浅色/白毛去黄提纯 (`coatWhiten`)**：针对白猫、白狗（萨摩耶、比熊、贵宾等）嘴边及四肢微黄氧化暗沉进行色调中和，还原纯净白亮；
  6. **微观毛流细节保真 (`texturePreservation`)**：默认 70% 高频毛发真实肌理保留，彻底杜绝塑料橡皮擦糊感。
- **配方版本门禁升级**：Recipe Version 18，完全向下兼容 v1~v17 配方。中性参数零开销（100% 像素直通）。

---

## 2. 核心架构与技术实现 (Architecture & Implementation)

### 2.1 动物检测与动态解剖蒙版 (Animal Detection & Anatomical Masks)

| 区域 | 几何构造逻辑 | 蒙版生成方式 |
| :--- | :--- | :--- |
| **宠物身躯毛发 (Coat / Torso)** | 基于 `VNRecognizeAnimalsRequest` 边界框 | 覆盖身躯的主体椭圆羽化蒙版，作用于微观毛流与去灰/去黄 |
| **宠物眼眶 (Pet Eyes)** | 位于动物头部中心两侧约 $16\%$ 偏移处 | 左右对称的双眼羽化圆形蒙版，作用于暗部提亮与眼神光聚集 |
| **宠物鼻吻 (Muzzle & Snout)** | 位于头部下中区（中心下方约 $13\%$ 偏移） | 鼻头与吻部紧密椭圆羽化蒙版，作用于暗部深邃与水光高光强化 |

### 2.2 GPU 加速核心算法 (`CIColorKernel`)

- **频域微观毛流分离 (Frequency Separation)**：
  从原图分离出高频带通毛发信号 $\text{high} = C_{\text{orig}} - C_{\text{blur}}$；
- **毛发蓬松增强 (Fur Fluffiness)**：
  $$\text{fluffy} = C_{\text{orig}} + \text{high} \times \text{furFluffiness} \times 0.85 \times m_{\text{coat}}$$
- **明眸提亮与眼神光提升 (Eye Brightening)**：
  $$L_{\text{lift}} = L \times (1.0 - L) \times \text{eyeBrightening} \times 0.75 \times m_{\text{eyes}}$$
  针对 $L > 0.55$ 的眼神光反光点额外补充高光对比度；
- **鼻吻水光润泽 (Muzzle Moisture)**：
  加深暗部基底层次：$C_{\text{dark}} = C - (1.0 - L) \times \text{muzzleMoisture} \times 0.15 \times m_{\text{muzzle}}$；
  针对 $L > 0.50$ 的水光高光区域强化镜面反射；
- **去灰纯化与白毛去黄**：
  非线性压缩环境灰雾并适度补偿色彩饱和度；针对浅色发黄区域补充蓝通道（$B'' = B + (R - B) \times \text{coatWhiten} \times 0.50$）。

---

## 3. UI 交互设计 (UI & Workflow)

在“人像精修”面板新增【智能宠物写真美化】分组（`pawprint.fill`）：
- 启用/停用总开关
- **毛发蓬松 (Fur Fluffiness)**：`0.0 ~ 1.0`（默认 0.0）
- **明眸提亮 (Eye Brightening)**：`0.0 ~ 1.0`（默认 0.0）
- **鼻吻润泽 (Muzzle Moisture)**：`0.0 ~ 1.0`（默认 0.0）
- **毛发去灰 (Coat Dehaze)**：`0.0 ~ 1.0`（默认 0.0）
- **白毛去黄 (Coat Whiten)**：`0.0 ~ 1.0`（默认 0.0）
- **肌理保护 (Texture Preservation)**：`0.0 ~ 1.0`（默认 0.70）
- **重置为默认值按钮**

---

## 4. 兼容性与版本控制 (Compatibility & Versioning)

- **Recipe 规范**：升级至 Version 18。
- **向下兼容**：Version 1~17 配方在加载时自动解码 `petEnhancement = nil`，保持 100% 历史视觉输出一致性。
- **导出/验证**：当 `petEnhancement` 启用且任一增强强度非零时，配方版本自动升级至 18。未配置或处于中性默认值时，不强制升至 18。
