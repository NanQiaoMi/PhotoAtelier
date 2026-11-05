# P1-E Release Notes: 客户交付增强 (Customer Delivery Enhancement)

> 版本: P1-E (feat/p1e-delivery-enhancement)  
> 日期: 2026-11-05  
> 状态: 已验证通过  

---

## 1. 概览 (Overview)

P1-E 是在 P1-B 交付页基础上的重要体验升级，围绕商业摄影师与顾客看样交付全流程，打造高质感视觉相册、离线隐私背书与轻量局域网即时投屏浏览能力：
1. **多主题与精选大图**：新增黑金沉浸（`darkGold`）、经典冷灰（`classicSilver`）与温暖米白（`warmLight`）3 款质感配色，支持副标题、摄影师署名与顶部 Hero 精选封面大图。
2. **离线隐私审计报告**：生成 `privacy-audit.json`，清晰证明相册完全剔除了 GPS 坐标、相机序列号、私有元数据及用户隐私。
3. **内置局域网静态 HTTP 服务 (`DeliveryServer`)**：基于 BSD POSIX Socket 与 GCD 读就绪源实现零外部依赖、零云端上传的本地/局域网 Web 服务器，支持手机、平板同 WiFi 扫码即看，具备防路径穿越安全机制。
4. **多选交付导出**：支持一次性将多张已选照片打包为精选客户交付文件夹。

---

## 2. 核心交付功能 (Delivered Capabilities)

### E1. 多视觉主题与精装排版 (`DeliveryTheme` & Hero Cover)
- **3 款精美主题**：
  - `darkGold` (黑金沉浸)：`#0f1216` 沉浸底色，搭配金黄高光 `#d4af37`，适合高端肖像与夜景人像。
  - `classicSilver` (经典冷灰)：`#141619` 深冷灰底色，搭配冰蓝强调 `#93b4d7`，适合胶片与现代纪实。
  - `warmLight` (温暖米白)：`#f8f6f0` 暖浅色底色，搭配大地暖咖 `#a05a2c`，适合婚礼、亲子与日系写真。
- **封面大图 (Hero Cover)**：可指定首张照片作为顶栏全宽精选大图，突出作品视觉焦点。
- **署名与副标题**：支持副标题（如活动主题或客照备注）与制作/摄影师机构署名，在 HTML 顶栏与页脚美观呈现，支持严格 HTML 转义防御 XSS。

### E2. 离线元数据隐私审计 (`DeliveryPrivacyAuditor`)
- **透明审计清单**：自动输出 `privacy-audit.json`，列出已安全剔除的 5 大类元数据：
  1. GPS 地理位置信息（经纬度、海拔、朝向）
  2. 相机硬件序列号（机身识别码、镜头识别码）
  3. 设备所有者 / 摄影师个人隐私元数据
  4. 原始文件路径与本地系统结构信息
  5. 相机厂商专有私有标记 (MakerNote / Private XMP)
- **安全交付凭证**：HTML 交付页顶栏直接附带审计报告链接，客户手机或电脑打开清晰明了，提供商业级隐私保护证明。

### E3. 零依赖轻量局域网 HTTP 预览服务 (`DeliveryServer`)
- **纯本地/内网直连**：基于系统底层 BSD POSIX Socket (`socket`, `bind`, `listen`) 与 `DispatchSourceRead`，无须安装第三方环境或云服务。
- **双端直连**：自动解析当前 Wi-Fi/以太网内网 IP（如 `http://192.168.x.x:8080/`）与本机 Loopback（`http://127.0.0.1:8080/`），摄影师在电脑上点选启动，客户或助理即可在同 WiFi 下用手机/iPad Safari 极速看片选片。
- **严格离线与安全防护**：
  - 坚决杜绝任何公网服务器、零云端数据传输，退出或切换相册时自动注销并释放端口。
  - 内置路径穿越防护（Path Traversal Guard），对请求包含 `..` 或试图跳出交付根目录的非法路径直接返回 `403 Forbidden`。

### E4. 多选照片交付支持
- 侧边栏多选（`⌘ + 点击`）多张照片后，交付按钮自适应切换为「导出客户交付页（已选 N 张照片）…」，自动逐张应用当前调色配方并在独立子文件夹内批量生成整套纯净相册与接触表 PDF。

---

## 3. 测试与验证 (Verification Summary)

- **DeliveryGalleryTests 新增用例**：
  - `testDeliveryThemesRenderCustomCSSVariables`: 校验三种主题对应的 CSS 变量注入。
  - `testDeliveryHeroCoverSection`: 校验 Hero 封面大图区生成与禁用逻辑。
  - `testDeliverySubtitleAndPhotographer`: 校验副标题与摄影师署名的 HTML 渲染与转义。
  - `testDeliveryPrivacyAuditReportGeneration`: 校验 `privacy-audit.json` 生成、结构解析与禁用模式。
  - `testDeliveryServerLifecycleAndPathTraversal`: 校验 `DeliveryServer` 启动、HTTP GET 200 静态服务、404 未找到、403 路径穿越防御以及安全停止。
- **全量回归测试**：`swift test -j 2` 全量 535 项单元测试 100% 通过（0 失败，耗时 114 秒）。
- **打包验收**：`bash Scripts/build_app.sh` 编译 Release 构建、自签名与 Lensfun 依赖加载全部成功。
