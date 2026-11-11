# P2-G 实施方案：智能身体与手部美肤精修 (Smart Body & Hand Skin Retouching)

> 目标里程碑: P2-G (Milestone P2-G: Body & Hand Skin Retouching, Neck Smoothing, Vein Reduction & Tone Harmonization)  
> 基线提交: `9a36e77` (on `feat/p1c-culling-makeup-perf`)  
> 分支: `feat/p2g-body-hand-skin-refinement`  
> 规范版本: Recipe Version 16

---

## 1. 业务目标与需求背景

在影棚写真、婚纱人像、职业形象照与证件照场景中，人像面部精修（祛斑、磨皮、美白、妆容、美型）已达到高度完善。然而，当面部精修完毕后，露出的身体与手部区域往往暴露出明显反差：
1. **颈部横纹 (Neck Creases)**：低头与岁月导致的颈纹在侧光或前光下形成明显阴影槽；
2. **手部/手臂青筋与暗沉 (Hand & Arm Veins / Knuckle Dullness)**：手背表浅静脉呈青蓝绿色隆起，关节处色素沉淀发红或发黑，削弱整体美感；
3. **身体中性灰磨皮与粗糙质感 (Body Skin Roughness)**：锁骨、肩膀、手臂、双腿皮肤因干燥或光线产生局部粗糙与瑕疵，需高低频分解进行光影平整，同时保留真皮毛孔肌理；
4. **身体与面部色差 (Body-to-Face Skin Tone Mismatch)**：修图后由于粉底或面部提亮，面部白皙通透，但身体和手部往往偏黄或发红，呈现“脸白身黄”的脱节感。

商业竞品（如像素蛋糕 PixelCake）在 9.0~10.0 版本中重点推出了「手部中性灰、祛青筋、肩颈美化、祛颈纹、AI 全身美化与肤色统一」。

光屿（PhotoAtelier）在 P2-G 中秉持 **100% 本地原生、零外部大模型依赖、GPU 毫秒级着色器渲染、严格保护隐私与可追溯性** 的工程原则，实现完整的智能身体与手部美肤精修引擎。

---

## 2. 算法与渲染架构设计

### 2.1 选区定位与多层级保护

1. **人体与身体皮肤提取**：
   - 依赖 Vision 框架 `VNGeneratePersonSegmentationRequest` 获得高分辨率人体 Alpha Matte；
   - 提取 Vision 人脸轮廓与地标（`VNFaceObservation`）；
   - **面部/五官羽化遮罩 (`makeFaceExclusionMask`)**：以人脸 Bounding Box、下巴轮廓与五官地标构建椭圆扩展羽化遮罩，确保面部五官（眉、眼、唇、鼻、面颊妆容）100% 隔离，绝不受身体美肤滤波影响；
   - **身体裸露皮肤色度门禁 (`skinChrominanceGate`)**：在线性 sRGB / OKLab 色彩空间中检测健康肤色暖色调先验（$R > G > B$ 且饱和度适中），排除衣物与深色/冷色布料，仅作用于真实的裸露皮肤；
   - **颈部走廊提取 (`neckCorridor`)**：由下巴底端（地标 Chin 点）向下延伸至锁骨区域的梯形选区，专用于颈纹平整。

### 2.2 颈纹定向平整与阴影淡化 (`neckSmoothing`)

- 针对颈部走廊内的水平横纹，采用频域差分滤波：
  - 低频基底 $L_{\text{drape}}$：大核高斯模糊（$\sigma = 16 \dots 32$）保留颈部自然圆柱形体感与阴影过渡；
  - 中频折痕层 $M_{\text{crease}}$：中尺度滤波（$\sigma = 4 \dots 8$）提取横向凹槽阴影；
  - 高频毛孔层 $H_{\text{texture}}$：微观高斯残差保留皮肤纹理；
  - 抑制 $M_{\text{crease}}$ 中的凹槽衰减分量，将暗沟亮度提亮向两侧平展皮肤靠拢，结合 $H_{\text{texture}} \times \text{texturePreservation}$ 恢复毛孔，实现颈纹无痕淡化而不发假。

### 2.3 手部与手臂青筋/色沉淡化 (`veinReduction`)

- 静脉青筋在皮肤表层呈现青色/蓝绿色冷调色差与条状凸起阴影：
  - 色度检测：计算冷调色差权重 $W_{\text{vein}} = \max(0, \text{Green} - 0.5(\text{Red} + \text{Blue})) \times \text{LuminanceDip}$；
  - 中性灰提亮：提升静脉暗带亮度，补偿光影凹凸感；
  - 色度调和：将青蓝色向周围正常红润肤色色相渐进旋转插值，使静脉隐形融入健康肤色。

### 2.4 身体中性灰磨皮与肌理保留 (`bodySmoothing`)

- 针对肩、臂、手、腿等裸露皮肤区域：
  - 引导多频滤波：平滑粗糙感、毛孔粗大与轻微色斑；
  - 微观肌理注入：以参数 `texturePreservation` 控制高频微观细节回填，杜绝塑料平滑。

### 2.5 身体与面部肤色统一 (`bodyToneHarmonization`)

- 采样面部中心区域（额头、颧骨）的高可信平均肤色作为参考锚点 $(L_{\text{ref}}, A_{\text{ref}}, B_{\text{ref}})$；
- 在身体皮肤区域计算与面部锚点的色度与亮度差值；
- 按 `bodyToneHarmonization` 强度线性收敛，拉平颈部、手部与面部之间的明暗与色温差，消除脱节感。

---

## 3. 验收标准与测试矩阵

1. **中性无损**：当 `enabled == false` 或各项强度为 0 时，输出图像与原图 100% 比特级一致（$MSE = 0$）；
2. **面部保护**：面部五官（眼、眉、嘴唇、鼻梁）像素在身体美肤开启前后绝对不受影响（像素差为 0）；
3. **颈纹淡化**：带有颈部折痕的测试图在开启 `neckSmoothing` 后，颈部中频方差显著降低，折痕阴影有效减弱；
4. **青筋抑制**：带有青冷色条纹的皮肤区域在开启 `veinReduction` 后，冷色偏离显著降低，向正常肤色回归；
5. **配方版本门禁 (Version 16)**：非中性身体美肤配置保存为版本 16；历史版本 1~15 往返解码不受影响，保持原路径渲染；
6. **全量与 Universal 编译**：全量单元测试绿灯，双架构 universal build 与 `verify_app.py` 严格通过。
