# P2-Z 方案设计：智能全脸骨相立体光影重塑、面部折叠度与 T区/C区/下巴高光阴影精雕

## 1. 背景与商业价值

在高端商业摄影、时尚杂志大片、红毯写真与证件照精修中，“骨相美”（Bone-Structure Aesthetics）是决定照片高级感、立体感与视觉冲击力的核心。
常见平光、自然光或室内普通布光拍摄的照片往往存在以下痛点：
1. **面部折叠度低（扁平大脸）**：正面与侧脸光影过渡平缓，缺乏清晰的明暗交界线，使面部在视觉上显得宽大、扁平、缺乏纵深；
2. **中庭与 T 区缺乏焦点**：额头中央与鼻梁骨轴线平淡，缺乏高挺挺拔的聚光点；
3. **颧弓与太阳穴 C 区暗淡**：缺乏明星红毯级的立体 C 区珍珠光泽带，显得肤质黯淡、缺乏饱满精气神；
4. **面颊侧部缺少雕塑感**：颧下凹陷区无修容，面部缺乏超模级的骨骼轮廓线条；
5. **下颌线与颈部粘连**：下颌骨下缘受光散乱，下颌线条不够利落清晰，甚至在特定角度显现微弱双下巴阴影；
6. **下庭唇周平淡**：人中嵴与丘比特唇峰缺乏微光点缀，人中偏长、唇部缺乏生动微雕感。

**P2-Z** 落地全套**智能全脸骨相立体光影重塑系统**，无需复杂的手动高光阴影涂抹，纯靠 Vision 原生面部地标结合 Core Image GPU 骨相着色器，100% 离线、微秒级实时渲染，打造自然深邃的高折叠度骨相光影。

---

## 2. 核心参数与功能设计

### 2.1 参数模型 (`FacialBoneContourSettings`)

```swift
public struct FacialBoneContourSettings: Equatable, Codable, Sendable {
    public var enabled: Bool = false
    public var facialFolding: Double = 0.0          // 0.0...1.0: 面部折叠度增强（侧脸光影自然衰减收敛，中轴立体挺拔）
    public var tZoneHighlight: Double = 0.0         // 0.0...1.0: T 区立体高光（额头中央 + 印堂 + 鼻梁中轴线珍珠微光）
    public var cZoneHighlight: Double = 0.0         // 0.0...1.0: 双侧 C 区高光（外眼眶经太阳穴向颧骨上方弯曲的高光弧带）
    public var cheekContourShadow: Double = 0.0     // 0.0...1.0: 面颊侧部微阴影修容（颧下向口角延伸的收敛微阴影）
    public var jawlineShadow: Double = 0.0          // 0.0...1.0: 下颌线下阴影（下颌骨下缘向颈部过渡的立体雕刻阴影）
    public var philtrumHighlight: Double = 0.0      // 0.0...1.0: 人中与唇峰立体高光（双侧人中嵴 + 丘比特弓点缀微光）
    public var contourToneWarmth: Double = 0.0      // -0.5...0.5: 修容光影色温倾向（正值暖金蜜桃，负值冷茶中性）
}
```

### 2.2 视觉与解剖学着色器架构

1. **几何蒙版提取**：
   - 基于 `VNFaceObservation`：
     - `medianLine`：定位额中、印堂、鼻梁、人中、下巴中轴；
     - `faceContour`：提取双侧脸颊边缘与下颌底缘曲线；
     - `leftEyebrow` / `rightEyebrow` 与 `leftEye` / `rightEye`：定位双侧 C 区眼眶骨弓与颞部；
     - `nose` 与 `outerLips`：定位鼻中隔下缘、人中嵴与唇峰。
2. **GPU 骨相着色器 (`facialBoneContourKernel`)**：
   - 提取局部中高频细节（毛孔、细绒毛），确保阴影与高光叠加后原生皮肤微质感 100% 留存，绝不出现假白、发脏、结块或塑料感；
   - 柔和高光混合采用类似半透明珍珠高光粉（Pearlescent Specular Sheen）的物理加权模型；
   - 修容阴影采用基于 OKLab / 保持色度比例的亮度衰减，绝不改变原生皮肤的色相。

---

## 3. 管线位置与版本控制

- **渲染管线顺序**：在面部外轮廓微雕（P2-X，步骤 3i）、眉形微雕（P2-Y，步骤 3j）之后，作为步骤 3k 运行。
- **配方版本**：配方版本升级至 33（Recipe v33）。若存在 `facialBoneContour` 非中性设置或分人覆盖，要求配方版本至少为 33。
- **选择性同步**：`AdjustmentSyncOptions.facialBoneContour`，全人像预设默认启用。
- **UI 集成**：位于右侧检查器「人像精修」面板中，独立卡片组件。

---

## 4. 验收标准

1. `swift test --filter FacialBoneContourTests`：单元与边界测试 100% 通过；
2. `swift test --filter EyebrowReshapeTests`：相邻模块回归测试 100% 通过；
3. `swift test -j 2`：全量测试套件（789+ 用例）全绿；
4. `bash Scripts/build_app.sh`：生产包构建 Exit code 0；
5. `python3 Scripts/verify_app.py build/PhotoAtelier.app && codesign --verify --deep --strict build/PhotoAtelier.app`：Exit code 0；
6. 100% 离线，纯 Vision 原生地标 + Core Image 原生 CIColorKernel，零外部权重。
