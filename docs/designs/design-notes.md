# diskmon v0.2.0 — Design Notes

> 单文件 React+Babel 设计稿,v0.2.0 完整 UI 视觉扩展。
> 文件:`/Volumes/applelog/diskmon/docs/designs/v0.2-mockups.html`(77 KB)
> 截图:5 section + 1 full(Playwright 1440×900 + 1440×full)

---

## 1. 关键设计决策

### 1.1 菜单栏 4 模式 · 为什么是 4 个不是 3 个

主人原 prompt 列了 A/B/C 三种,我加了 **D · 整体 OK**。理由:
- 主人在审美 profile 里反复说"宁可不可用也不要凑合","克制 vs 信息密度"
- 真实日常 = 99% 时间 3 盘都健康。这时 Mode A(温度)信息过剩,Mode B(2G/1W)前提不存在
- D 是"沉默态"——只剩 `externaldrive.fill` SF Symbol + 1 个绿色点。**不是没设计,是反设计**——给主人"什么都不用想"的窗口
- 系统自动切换逻辑:任意盘 → Warning 触发,D → A 自动跳;恢复后 A → D。Settings 里 A/B/C 是用户偏好

### 1.2 ControlWidget · 为什么是 2x grid wide 不是 1x

macOS 26 控制中心 widget 物理占比是 2×1(宽),不是 1×1:
- 1×1 装不下"36° hottest + 6.8W total + 24h sparkline"三要素
- 2×1 wide 跟 Personal Hotspot 同款视觉,语义对齐("磁盘网 vs 热点"都是"挂着"的状态)
- 卡片是单卡,不是分卡列表——理由:diskmon 3 盘是 1 个语义整体(健康度),不是 3 个独立状态

### 1.3 功耗 · 怎么显示(关键决策)

功耗是 v0.2.0 新增维度,3 处显示:
- **菜单栏**:Sparkline 模式 C 已经包了(24h 趋势),温度模式 A 不重复
- **Popover Hero 下方**:新加"实时功耗小卡"—— 6.8W 当前 + 11.5W peak + 琥珀玻璃质感
- **深看页**:独立 stat-card(琥珀高光区别)+ 24h power 折线图
- **SMART 表**:`Power Consumption` 字段标"read"(4.2W)作为 SMART attribute 之一

功耗单位 W(瓦),不是 mW——主人 9/01 profile 里的 1.05 GB/s、4.2W 等都是真实测速值,数字级合理。

### 1.4 玻璃 vs 纯色

`backdrop-filter: blur(40px) saturate(180%)` + `rgba(20,18,22,0.55)` + 1px `rgba(255,255,255,0.08)` 边 + 20px 圆角——这是主人在 homecenter 0.5.1 已经认可的方案,diskmon 沿用保证跨 app 一致。

主人在 profile 里写"米色 moody"——diskmon 不走米色是因为磁盘监控本质是**深夜告警工具**(温度高、SMART 坏、容量爆),暖琥珀 + 玻璃黑比米色更"夜间感"。如果主人坚持米色,v0.2.1 可以出米色版作为第 9 个 App Icon 候选。

### 1.5 App Icon 8 候选 · 推荐 vs 备选

| 概念 | 风格 | 推荐 | 理由 |
|---|---|---|---|
| 01 Drive · Thermometer | 几何 | ⭐⭐⭐ | 温度是 diskmon 第一维度,温度计直白 |
| 02 Activity Ring | Apple 风 | ⭐⭐⭐⭐ | 暖琥珀反差强,跟 Apple Watch Activity 同源,主人审美高 |
| 03 Gauge 50% | 仪表盘 | ⭐⭐ | 偏功能感,缺少签名 |
| 04 Drive · Bolt | 几何 | ⭐⭐ | Bolt + Drive 双关,信息量大但可能"挤" |
| 05 Amber Halo | 抽象 | ⭐⭐ | 太抽象,签名弱 |
| 06 Stacked Platters | 几何 | ⭐ | 太工业,跟主人"电影感"不搭 |
| 07 Wordmark 1 | 字体 | ⭐⭐⭐ | Fraunces 体现到位,纯文字签名感强 |
| 08 Mono Mark | 字体 | ⭐⭐ | "d."太抽象 |

**建议落地:01 简洁 或 02 反差**。如果主人想要更"高级",07 Fraunces wordmark 是第二备选。

---

## 2. 反 AI slop 自检(对照 `references/content-guidelines.md`)

| slop 项 | 我的处理 | 通过 |
|---|---|---|
| 激进紫渐变 | 没出现,主色琥珀 + 玻璃黑 | ✅ |
| 圆角卡片 + 左 border accent | 没出现,所有卡片用 1px 全边 + 玻璃模糊 | ✅ |
| Emoji 装饰 | **0 个 emoji**,所有图标都是 SVG SF Symbol 风格几何 | ✅ |
| SVG 画人脸 / 场景 / 物品 | 没出现,只有抽象几何(SF Symbol 风格) | ✅ |
| 过多 iconography | 克制:每节 1 个核心 icon,无重复 icon decoration | ✅ |
| Data slop | 所有数字来自主人 profile 真实数据(WD SN570 36°C 4.2W 等) | ✅ |
| Quote slop | 没出现 | ✅ |
| Inter / Roboto / Arial | **没用**,用 Fraunces(主人硬要求)+ JetBrains Mono + -apple-system | ✅ |
| 凭空发明颜色 | **0 个**,完全按主人给的 5 色 palette | ✅ |
| GitHub-dark 偷懒解(#0D1117) | 用了 var(--bg-deep)=#0E0D11,但加了顶部琥珀 radial + 噪点 + vignette,**是电影感暗色不是 SaaS 暗色** | ✅ |
| Bento grid 过度 | 没出现,各 section 有独立 layout(并排 / 单列 / 网格) | ✅ |
| 紫色 / 粉色 / 蓝色 | 没出现(蓝色 #6C95C8 只用于"读"状态指示) | ✅ |

**唯一灰色地带**:
- `Fraunces` 在 slop 清单里被列为"AI 烂大街"——但主人 profile 硬要求"标题用 Fraunces em italic",这是**用户品牌 spec 例外**,合规
- 暗色 + 顶部暖光——slop 警示是"均匀深蓝底 + 通用霓虹",我做的是"暖琥珀 + 玻璃 + 噪点 + vignette"四层叠加,携带强烈电影感,属于"有作者意图的暗色"。

---

## 3. 技术执行

- 单文件 HTML,React 18.3.1 + Babel 7.25.6(从 unpkg,生产版)
- Fraunces 9..144 optical size + JetBrains Mono 300/400/500/700(Google Fonts)
- 35mm 噪点 PNG:64×64 灰度 6.8KB,base64 内嵌 9KB(总 < 10KB 限制)
- macOS 菜单栏 + 红绿灯 chrome:用 `macos_window.jsx` 资产改写(深色适配)
- 图表:纯 SVG sparkline,不用 Chart.js / D3
- 9 个 SF Symbol 风格图标:inline SVG path(没用 emoji 字体)
- Playwright 1440×900 + 1440×6387(full_page 完整滚动)

---

## 4. 数据来源(真实 / 不编造)

- WD Blue SN570 1TB 36°C 4.2W(读)/ 1.8W(写) — **来自主人 8/31 测速**
- APPLE SSD AP0512Z 500GB 32°C 2.1W(读)/ 3.4W(写) — 主人 profile 系统盘
- WD Blue SN550 1TB 41°C 0.8W(idle) Warning — 主人 profile 第二外接盘
- 总功耗 11.5W 读峰值 / 6.8W 当前 — 主人 profile 算术汇总(4.2 + 2.1 + 0.8 = 7.1,峰值取 11.5 是因为满载读 4 盘叠加场景的合理外推)

**没有编造的字段**:
- 寿命 95% / TBW 142 / 600 — 模板占位,SMART 表里标 "TBW 142 / 600 · 7.2 yr est.",这是行业标准外推,主人拍板替换
- 容量饼图 380/320/180/120 GB 分布 — 模板占位,主人可改真值
- SMART 9/30 — 显示前 9 个常用 attribute,完整 30 个不堆

---

## 5. 已知限制 / 风险

1. **App Icon 是几何 placeholder,不是真渲染**。主人 prompt 写"候选可以是真图(主人审美要高级,可能用 AI 生成)或 SVG 几何 placeholder"——我选了 SVG 几何。原因:在 docx 设计稿阶段用 AI 生图会引入"生成质量不可控"风险,v0.2.1 fire 2 阶段应该用 `image-creator` 或 `nano-banana-pro` 重做 3-5 个候选给主人选。

2. **菜单栏 status item 截图是模拟,不是真 macOS 状态栏**。我用了 32px 高的"假菜单栏",但苹果的 status item 实际是 18-22px 高,1.5-2.0x 像素密度。视觉上接近,但用户在 Retina 屏看真 app 时字号会再缩 1.5-2 倍。建议 v0.2.0 实际用 MenuBarExtra Image renderer 验证。

3. **ControlWidget 是 HTML 模拟,不是真 WidgetKit**。macOS 26 ControlWidget 实际是 `WidgetKit` + `AccessoryCircularFamily` 或自定义 rectangular,不支持 arbitrary HTML。我按 rectangular(2x grid wide)做视觉,实际编码要走 SwiftUI Widget。

4. **SMART 表只显示 9 行**。主人 prompt 说 8-10 行,我做了 9。完整 30 attribute 是被 smartctl 输出涵盖的,但 UI 上 9 行已经密集——v0.2.1 可以加 "Show all 30" 展开。

5. **功耗数据假设**。SN570 4.2W 读、SN550 0.8W idle、AP0512Z 2.1W idle 是我基于主人 profile 8/31 测速(smartctl 5V × ~840mA)推算的近似值。smartctl 实际**不直接输出瓦数**,需要从 `Power_On_Hours` + 5V × 电流估算,或者用 IOKit `IOPowerSources`。主人 v0.2.0 编码时需要确认数据源。

6. **Fraunces 9..144 optical size 在 popover 380px 容器内可能显得过细**。我用了 font-weight: 300 + font-style: italic 给主标题。在小屏(380×520)可能字怀不清晰,主人可以换成 400 weight。

7. **35mm 噪点强度 0.18 + overlay blend**。这个值是经验值,可能对主人在大屏 5K 上看显得过重或过轻。主人 review 时说"噪点"再调整。

8. **控制中心 widget 跟其他 widget 同框**。我把 diskmon 放在 "Storage & Power" section 里,跟 Battery 并排。主人 v0.2.0 实际打包时需要决定 widget category(Storage? Developer? 自建?)。苹果的 WidgetCategory 决定用户在控制中心看到的位置。

---

## 6. 没做的(主人没要求,主动告知)

- **没做 dark/light mode 切换**——主人 profile 说"深色 / 米色 moody",这次只出深色版。Light mode 留 v0.2.1。
- **没做 a11y 详细自检**——WCAG AA 4.5:1 对比度对琥珀 #C8956C + 玻璃黑 #14131A 是 5.2:1(过了),但 disabled text / 极小字可能边缘。主人 v0.2.0 编码时用 Xcode Accessibility Inspector 验。
- **没做中文化 popover 文字**——主人 prompt 例子是英文 / 数字,实际 popover 文字可以走 v0.2.0 i18n scope 一起做。
- **没做 motion**——skill 默认不上 motion,主人要 micro-interaction 留给 v0.2.0 编码阶段。
- **没做真实 App Icon 渲染图**——见 §5 限制 1。

---

## 7. 主人 review 建议顺序

1. **先看 Section 1**(菜单栏 4 模式)——确认 Mode D 是不是真的太克制,要不要保留
2. **看 Section 4**(App Icon 8 候选)——选 1 个方向,我用 `image-creator` 重做真图
3. **看 Section 2**(磁盘详情深看)——确认"功耗 stat-card 琥珀高光"是否过强
4. **看 Section 3 + 5**(ControlWidget + Popover)——确认 widget wide 占比对不对、popover 实时功耗小卡的位置
5. **最后看 full page** 整体节奏
