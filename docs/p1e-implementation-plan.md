# P1-E Implementation Plan: 客户交付增强 (Customer Delivery Enhancement)

> 分支: `feat/p1e-delivery-enhancement`  
> 基线: `fd9225b`  
> 状态: 进行中 (P1-E)

---

## 1. 目标与验收标准 (Goals & Acceptance Criteria)

### 1.1 核心目标
1. **多主题与精美交付页模板 (`DeliveryTheme` & Cover Photo)**:
   - 增加 3 款高质感离线配色主题：`darkGold` (黑金沉浸)、`classicSilver` (经典冷灰)、`warmLight` (温暖暖白/米白)。
   - 支持副标题 (`subtitle`) 与摄影师/机构署名 (`photographer`)。
   - 支持指定精选封面大图 (`coverPhotoIndex`) 顶部 Hero 展陈。
   - 响应式自适应网格（桌面/平板/手机）。
2. **轻量本机 HTTP 局域网预览 (`DeliveryServer`)**:
   - 基于系统原生 `Network.framework` (`NWListener`) 实现零外部依赖的极简本地 HTTP 服务器。
   - 纯离线静态服务，支持电脑本地 (`http://127.0.0.1:port`) 与同 WiFi 手机/平板 (`http://192.168.x.x:port`) 直连浏览。
   - 严禁任何公网上传、零云端账号、退出或切换时安全销毁，坚决恪守离线隐私底线。
   - 防路径穿越（Path Traversal）安全保护。
3. **元数据隐私审计报告 (`DeliveryPrivacyAuditor`)**:
   - 在交付文件夹内自动输出 `privacy-audit.json`，清晰记录已剔除的 GPS、机身序列号、个人隐私 EXIF 等字段，交付客户更有安全背书。
4. **统一导出与操作入口**:
   - 在「导出」面板集成交付模板配置（主题、署名、封面图）与一键本地预览控制。

### 1.2 验收项清单
- [ ] `DeliveryTheme` 支持 3 种主题，HTML 样式、字体及配色正确渲染。
- [ ] 封面大图 Hero 区域在设置了 `coverPhotoIndex` 时正常生成，未设置时不占位。
- [ ] `privacy-audit.json` 自动写入，记录剥离元数据分类。
- [ ] `DeliveryServer` 能正常启动/停止，HTTP GET 静态资源正确返回对应 MIME 类型。
- [ ] 路径穿越请求（包含 `..`）被安全拒绝或拦截。
- [ ] 全量 `make check` 测试套件全绿，单元测试新增覆盖全部新功能。
- [ ] `bash Scripts/build_app.sh` 独立 Release 包签名与验证通过。

---

## 2. 架构设计与实现路径

```
┌─────────────────────────────────────────────────────────────────┐
│                          PhotoCore                              │
│                                                                 │
│  DeliveryGallery.swift:                                         │
│  ├── DeliveryTheme (darkGold / classicSilver / warmLight)       │
│  ├── DeliverySettings (+subtitle, +photographer, +theme, etc.)  │
│  ├── DeliveryPrivacyAuditor (privacy-audit.json)                │
│  └── HTML / PDF generator updates                               │
│                                                                 │
│  DeliveryServer.swift:                                          │
│  ├── NWListener (Network.framework, local/LAN HTTP server)      │
│  ├── MIME mapping (.html, .jpg, .pdf, .json, .css)              │
│  └── Path safety guard                                          │
└─────────────────────────────────────────────────────────────────┘
                                ▲
                                │
┌─────────────────────────────────────────────────────────────────┐
│                        PhotoAtelier                             │
│                                                                 │
│  AppModel.swift:                                                │
│  ├── deliverySettings: DeliverySettings                         │
│  ├── deliveryServer: DeliveryServer                             │
│  └── exportDeliveryPage() / toggleDeliveryServer()              │
│                                                                 │
│  ContentView.swift (exportInspector):                           │
│  └── 交付模板选项 (主题/副标题/封面) + 本地局域网预览控制卡片  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 回滚方案
若出现阻塞性问题，可通过 `git checkout feat/p1c-culling-makeup-perf` 回滚至 baseline `fd9225b`。
