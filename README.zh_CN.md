# FileSync - KOReader 无线文件管理器

[English](README.md) | [Español](README.es.md) | [Português](README.pt_BR.md) | **中文** | [العربية](README.ar.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

一款 KOReader 插件，可在电子阅读器上启动本地 Web 服务器并在屏幕上显示 QR 码。用手机扫描即可打开精美的 Web 界面，无线管理书籍和文件——无需数据线，无需安装应用，只需浏览器即可。

支持运行 KOReader 的 **Kindle** 和 **Kobo** 设备。

<p align="center">
  <img src="screenshots/qr-screen.png" alt="电子阅读器上的 QR 码画面" width="500">
</p>
<p align="center">
  <img src="screenshots/web-home.png" alt="Web 界面 - 首页" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Web 界面 - 目录" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Web 界面 - 文件详情" width="250">
</p>

## 功能特性

- **QR 码访问** — 扫码即连，无需手动输入 URL
- **文件浏览器** — 通过面包屑导航浏览书库
- **上传文件** — 拖放或点击即可从手机上传书籍
- **下载文件** — 一键将文件保存到手机
- **创建文件夹** — 将书库整理为不同目录
- **重命名与删除** — 基本文件管理操作，带确认对话框
- **搜索与排序** — 按名称筛选，按名称/大小/日期/类型排序
- **深色与浅色主题** — 自动检测或手动切换
- **多种视图模式** — 列表、网格和大网格视图
- **多语言支持** — 提供 10 种语言（英语、西班牙语、葡萄牙语、中文、阿拉伯语、法语、德语、俄语、日语、韩语）
- **RTL 布局支持** — 完整的阿拉伯语从右到左布局
- **防休眠** — 服务器运行期间保持设备唤醒状态和 WiFi 连接
- **安全模式** — 仅显示书籍和图片，隐藏系统文件
- **响应式界面** — 专为智能手机设计，适配各种屏幕

## 使用流程

1. 将电子阅读器连接到 WiFi
2. 从 KOReader 的网络工具菜单中打开 FileSync 插件
3. 电子阅读器屏幕上会显示一个 QR 码
4. 用手机扫描（需连接同一 WiFi 网络）
5. 在手机浏览器中通过 Web 界面管理书籍

## 安装

### 前提条件

- 已安装 [KOReader](https://github.com/koreader/koreader) 的 Kindle 或 Kobo 电子阅读器
- 电子阅读器和手机需连接到同一 WiFi 网络

### 方式一：通过发布包安装（推荐）

1. 从[发布页面](../../releases)下载最新的 `.zip` 文件
2. 解压缩文件
3. 将 `filesync.koplugin` 文件夹复制到设备上的 KOReader 插件目录（参见上方路径说明）
4. 重启 KOReader

### 方式二：直接复制

1. 通过 USB 将电子阅读器连接到电脑

2. 找到 KOReader 插件目录：
   - **Kindle：** `/mnt/us/koreader/plugins/`
   - **Kobo：** `.adds/koreader/plugins/`（位于 SD 卡根目录）

3. 将整个 `filesync.koplugin` 文件夹复制到插件目录中：
   ```
   plugins/
   ├── filesync.koplugin/
   │   ├── _meta.lua
   │   ├── main.lua
   │   └── filesync/
   │       ├── filesyncmanager.lua
   │       ├── httpserver.lua
   │       ├── fileops.lua
   │       ├── filesync_i18n.lua
   │       ├── qrcode.lua
   │       ├── static/
   │       │   └── index.html
   │       └── i18n/
   │           ├── en.po
   │           ├── es.po
   │           ├── pt_BR.po
   │           ├── zh_CN.po
   │           ├── ar.po
   │           ├── fr.po
   │           └── ...
   ├── other.koplugin/
   └── ...
   ```

4. 安全弹出设备并重启 KOReader

### 验证安装

重启 KOReader 后，打开顶部菜单并导航到：

**网络 → FileSync**

如果能看到该菜单项，说明插件已正确安装。

## 使用方法

### 启动服务器

0. 确保设备已连接到 WiFi
1. 打开 KOReader 顶部菜单
2. 导航到 **网络 → FileSync**
3. 点击 **启动文件服务器**
4. 屏幕上将显示带有连接 URL 的 QR 码

<p align="center">
  <img src="screenshots/menu.png" alt="KOReader 中的 FileSync 菜单" width="350">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/qr-screen.png" alt="QR 码画面" width="350">
</p>

### 从手机连接

1. 确保手机与电子阅读器连接到**同一 WiFi 网络**
2. 打开手机相机扫描 QR 码
3. 点击链接在浏览器中打开 Web 界面
4. 也可以手动输入 QR 码下方显示的 URL

### 管理文件

连接成功后，Web 界面提供以下功能：

- **浏览** — 点击文件夹浏览书库。使用顶部的面包屑导航栏可快速返回任意上级目录。
- **上传** — 点击顶栏的 **上传** 按钮，然后选择文件或将文件拖到上传区域。支持同时上传多个文件。
- **文件详情** — 点击任意文件打开详情视图，可进行 **下载**、**重命名** 或 **删除** 操作。
- **创建文件夹** — 点击顶栏的 **文件夹** 按钮并输入名称。
- **搜索** — 使用搜索栏按文件名筛选当前目录中的文件。
- **排序** — 使用下拉菜单按名称、日期、大小或类型进行升序或降序排列。

<p align="center">
  <img src="screenshots/web-home.png" alt="文件浏览器 - 首页" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="文件浏览器 - 带上传功能的目录" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="文件详情视图" width="250">
</p>

### 防休眠

文件服务器运行期间，插件会自动阻止设备进入休眠或待机状态。这确保服务器始终可访问，WiFi 连接不会中断。具体来说：

- **待机** 和 **休眠** 被阻止，设备保持唤醒状态
- **自动休眠** 和 **自动待机** 定时器被临时禁用
- 启用 **WiFi 保活** 以维持网络连接

服务器停止时，所有设置都会恢复为之前的值。如果设备因某些原因进入休眠（例如电量极低），设备唤醒后服务器将自动重启。

### 停止服务器

- 在插件菜单中点击 **停止文件服务器**，或
- 退出 KOReader 时服务器会自动停止

### 更改端口

1. 打开插件菜单
2. 点击 **服务器端口**
3. 输入 1024 到 65535 之间的端口号（默认值：8080）
4. 重启服务器以使更改生效

### 安全模式

安全模式**默认开启**，会限制 Web 界面仅显示与阅读相关的文件。启用后：

- 仅显示 **电子书**（EPUB、PDF、MOBI、AZW3、FB2、DJVU、CBZ 等）、**文档**（TXT、DOC、RTF、HTML 等）和 **图片**（JPG、PNG、GIF、WebP）
- 系统文件、配置文件及其他非书籍类文件将被隐藏
- KOReader 元数据目录（`.sdr` 文件夹）将被隐藏，删除书籍时也会自动清理

要切换安全模式，请打开插件菜单并点击 **安全模式**。关闭后将显示设备上的所有文件。

## 故障排除

**插件未出现在菜单中**
- 确保文件夹名称为 `filesync.koplugin`（区分大小写）
- 检查 `_meta.lua` 和 `main.lua` 是否直接位于该文件夹内（非嵌套子目录）
- 完全重启 KOReader

**"WiFi 未启用" 错误**
- 在启动服务器之前，请先将电子阅读器连接到 WiFi 网络
- 部分设备需要在 KOReader 的网络设置中手动启用 WiFi

**手机无法连接**
- 确认两台设备在同一 WiFi 网络上
- 尝试手动输入 URL，而不是扫描 QR 码
- 检查路由器是否启用了客户端隔离功能（会阻止设备之间相互通信）
- Kindle 用户：插件会自动管理防火墙规则，但如果规则出现异常，重启设备可能有帮助

**上传失败**
- 检查设备的可用存储空间
- 过大的文件可能导致超时——请尝试分批上传较小的文件
- 确保目标目录具有写入权限

## 贡献

欢迎参与贡献！

1. Fork 本仓库
2. 创建功能分支
3. 进行修改
4. 尽可能在真实设备上测试
5. 提交 Pull Request

## 许可证

本项目基于 [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html) 许可证发布，与 KOReader 项目保持一致。
