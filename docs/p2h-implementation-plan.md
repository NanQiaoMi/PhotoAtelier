# P2-H: 智能面部五区专项祛皱与去油光 (Smart Facial Zonal Wrinkle Smoothing & Anti-Shine Matte) 架构设计

> 对应商业竞品「像素蛋糕」：面部五区精修（祛黑眼圈、祛眼袋/泪沟、祛法令纹、祛抬头纹/川字纹、去油光高光哑光化、双下巴收紧与下颌线修容）。

---

## 1. 核心目标与技术背景

商业人像摄影工作室（婚纱摄影、肖像写真、儿童人像、职业形象照）在人脸精修中，高频且决定出片品质的不是全脸模糊磨皮，而是**结构性局部阴影沟壑与局部反光的专项治理**：
1. **黑眼圈 (Dark Circles)**：眼周毛细血管充血或色素沉着引起的下眼睑蓝紫/暗褐色暗沉。
2. **眼袋与泪沟 (Under-Eye Bags & Tear Troughs)**：眼轮匝肌下缘或眶隔脂肪凸起形成的弧形凹陷阴影槽。
3. **法令纹 (Nasolabial Folds / Smile Lines)**：鼻翼基底到口角两侧的深部沟壑阴影。
4. **抬头纹与川字纹 (Forehead & Glabellar Frown Lines)**：额头水平走行动态/静态皱纹，以及眉间两道纵向垂直皱纹阴影。
5. **面部油光去反光 (Facial Anti-Shine / Specular Matte)**：T区（额头中央、鼻梁、鼻尖、下巴）及苹果肌因皮肤油脂反射闪光灯产生的白炽高光亮点，传统抹除会失真，需实现高级哑光收敛（Matte Specular Compression）。
6. **双下巴与下颌线重塑 (Double Chin & Jawline Sculpting)**：下颌下缘颈颌转折处的双层重叠阴影淡化，清晰勾勒下颌轮廓线。

本项目坚持 **100% 本地离线、零外部大模型依赖、GPU Core Image 高性能渲染** 路线，基于系统原生 Vision 人脸地标几何推导与局部频域分解技术，实现商业级精修效果。

---

## 2. 几何走廊与局部掩膜推导

基于 `FaceLandmarkSet` 提取 6 组局部精确掩膜：
- **下眼睑眼袋/泪沟走廊 (`makeUnderEyeBagsMask`)**：以左右眼下眼睑（`leftEye` / `rightEye` 下半部点）为上界，向下垂直延伸 $0.4\dots 0.8 \times \text{eyeHeight}$，两端覆盖内眦（泪腺）至外眦，以高斯平滑羽化生成柔软的泪沟走廊。
- **黑眼圈暗沉掩膜 (`makeDarkCirclesMask`)**：在下眼睑走廊内部，检测色相偏蓝灰/紫褐色（$B - R$ 异常升高或相对面部暖色基准明度不足）的充血暗沉像素。
- **法令纹走廊 (`makeNasolabialMask`)**：连接鼻翼外侧左右点（`nose` 外轮廓角点）与口角外侧（`outerLips` 角点），向外侧放射拓展 $0.15 \times \text{faceWidth}$，形成左右两道对称的弧形法令纹阴影带。
- **额头与眉间走廊 (`makeForeheadAndBrowMask`)**：
  - 额头区：位于左右眉毛（`leftEyebrow`、`rightEyebrow`）上方至人脸框顶部之间。
  - 眉间川字纹区：位于左右眉毛内眦之间的人中正上方区域。
- **油光高光检测掩膜 (`makeAntiShineMask`)**：在面部皮肤掩膜内，检测高亮度且低饱和度的泛白反光点（$L > 0.82$ 且 $\text{Saturation} < 0.25$），集中在 T 区与鼻梁。
- **双下巴下颌阴影掩膜 (`makeJawlineDoubleChinMask`)**：提取 `faceContour` 底部下巴段，向下延伸至颈部上界的阴影凹陷区。

---

## 3. 数学渲染模型与频域分解

对于每一个目标区域，输入图像划分为三频：
$$c_{\text{Base}} = \text{GaussianBlur}(c, \sigma_{\text{Drape}})$$
$$c_{\text{Mid}} = \text{GaussianBlur}(c, \sigma_{\text{Smooth}})$$
$$c_{\text{High}} = c - c_{\text{Mid}}$$

- **皱纹沟壑提亮与平整 (Crease Shadow Lifting)**：
  沟壑处表现为 $c_{\text{Mid}} < c_{\text{Base}}$ 的局部负残差：
  $$\Delta_{\text{Crease}} = \max(0, c_{\text{Base}} - c_{\text{Mid}})$$
  $$c_{\text{Lifted}} = c + \text{strength} \cdot \Delta_{\text{Crease}} \cdot \text{ZonalMask}$$
- **黑眼圈暗沉色差中和 (Chrominance Neutralization)**：
  将黑眼圈暗沉区域的色温向面部基准肤色锚点 $c_{\text{Anchor}}$ 逼近，消除疲惫青紫感。
- **油光反光高光哑光化 (Matte Specular Compression)**：
  将高光反光点平滑压缩至漫反射皮肤最大明度：
  $$L_{\text{Matte}} = \text{mix}(L, L_{\text{Base}}, \text{antiShine} \cdot M_{\text{Shine}})$$
- **毛孔微观肌理保真 (Texture Preservation)**：
  $$c_{\text{Final}} = c_{\text{Smooth}} + \text{texturePreservation} \cdot c_{\text{High}}$$
  确保所有提亮平整后的皮肤依然清晰可见细腻自然的毛孔微结构，绝不出现塑料蜡像假人感。

---

## 4. 配方与版本门禁规则

- **Recipe Version 17**：新增 `FacialZonalRefinementSettings`。
- 当 `facialZonal` 处于默认（全 0）或 `isNeutral == true` 时，配方向下兼容版本 1...16；仅当用户启用非中性参数时，强制要求版本 17，杜绝静默降级。
- 100% 保持无损中性旁路，确保旧工程和默认设置字节级一致。
