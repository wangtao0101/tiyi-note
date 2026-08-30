# Tiyi Note

Tiyi Note 是一个使用 SwiftUI、PDFKit、PencilKit 和 CloudKit 构建的三端 PDF 笔记应用。项目使用同一套 Swift 代码运行在 iPad、iPhone 和 Mac Catalyst。

## 平台能力

| 能力 | iPad | iPhone | Mac Catalyst |
| --- | --- | --- | --- |
| PDF 阅读与多 Tab | 支持 | 支持 | 支持 |
| PencilKit 批注 | 编辑 | 只读 | 只读 |
| 资料库与嵌套文件夹 | 管理 | 只读 | 管理 |
| 列表/网格、搜索、排序、收藏、回收站 | 支持 | 只读 | 支持 |
| 文件夹/文稿重命名、批量移动 | 支持 | 只读 | 支持 |
| 文件夹颜色与图标 | 支持 | 只读 | 支持 |
| 新建空白/横线/方格/点阵画板 | 支持 | 只读 | 支持 |
| 导入多个 PDF | 支持 | 不支持 | 支持 |
| Finder 拖放 PDF | — | — | 支持 |
| 页面插入/复制/排序/旋转/书签/回收站 | 支持 | 只读查看 | 只读查看 |
| 文本、图片、图形与混合套索 | 编辑 | 只读 | 只读 |
| 相机扫描文稿 | 支持 | 不支持 | 不支持 |
| 扁平 PDF、逐页 PNG、可编辑包、打印 | 支持 | 支持 | 支持 |
| iCloud 私有资料库同步 | 支持 | 支持 | 支持 |
| CKShare 文稿多人协作/权限 | 支持 | 只读参与 | 支持 |

## 已实现

- Goodnotes 风格资料库，支持列表/网格、全局搜索、多种排序和 PDF/画板筛选。
- 任意层级文件夹、面包屑导航、同级名称冲突校验，以及名称、颜色和图标定制。
- 文件夹和文稿收藏、软删除、递归回收站、恢复、永久删除、清空回收站和批量移动。
- PDF 批量导入、重命名、移动和多文档 Tab。
- 创建 4:3 单页画板，包含空白、横线、方格和点阵背景，以及 6 种背景颜色。
- Mac Catalyst 可从 Finder 将一个或多个 PDF 拖入当前文件夹。
- iPad 支持圆珠笔、钢笔、铅笔、荧光笔、精细/整笔橡皮擦、撤销/重做、缩略图和逐页自动保存。
- 页面管理支持模板插入、复制、分数位置排序、旋转、书签、页面回收站和因果恢复。
- 混合套索可同时选中笔迹和对象，支持移动、缩放、旋转、复制、拷贝/粘贴、截图；对象支持
  锁定、前后层级、组合/取消组合。
- 文本对象支持系统/圆体/衬线/等宽字体、字号、颜色、粗体、斜体、下划线和对齐；图片支持
  裁剪和透明度；图形支持直线、箭头、矩形、椭圆、三角形、菱形、填充、线宽和虚线。
- iPad 相机扫描可把多张竖向/横向图片生成为 PDF；文稿可导出扁平 PDF、逐页 PNG、保留
  完整对象和协作历史的 `.tiyinote`，并交给系统打印面板。
- iPhone 与 Mac 可查看 PDF 和已同步批注，但不会改写批注数据。
- CloudKit 私有/共享数据库、自定义 Zone、增量 change token、离线重试和 CKShare 邀请。
- 共享文稿采用双层模型：CKShare Zone 只保存标题、页面、资产和 operation；每个用户自己
  private Zone 的 `TiyiDocumentReference` 保存文件夹位置、收藏和个人回收站状态。共享内容
  不会再把 owner 的文稿移到根目录，不同参与者也可以采用不同的资料库整理方式。
- PDF、逐页 PencilKit 笔迹和图片批注作为独立 CloudKit 资产同步。
- 多人协作使用不可变 operation、版本向量、Lamport 时钟、笔迹 OR-Set、对象字段补丁、
  因果 register、删除墓碑和 Logoot 页面位置；乱序、重复投递和离线并发会确定性收敛。
- 页面、笔迹和对象的并发删除保留因果反链；恢复必须观察到全部并发删除才会生效。基于
  旧画布 frontier 的延迟保存会进入独立编辑分支，避免伪造同一 actor 的因果先后关系。
- 个人文稿引用的父文件夹、收藏、回收站分别使用因果 register；不同字段的离线修改会
  合并，同一字段并发才按 Lamport/actor/operationID 确定性裁决，设备时间不参与裁决。
- 对象的边界、旋转、层级、锁定、分组和 payload 是独立 register：例如一端移动图片、
  另一端改透明度会自动合并。只有同一字段并发写入才确定性选择显示版本，另一版本进入
  “冲突版本”并可恢复为副本；只读 CKShare 参与者在 UI、Store 和上传层三层禁止写入。
- 每个可写 CKShare 参与者在共享 Zone 写入 `TiyiAcknowledgement` frontier；同一用户多台
  设备按版本向量并集合并 ACK。当前不会自动删除 operation：只读参与者无法写 ACK，且
  在真实第二账号验收 membership epoch/新设备重建前，保留日志比冒险回收更安全。
- replica actor ID 使用 `ThisDeviceOnly` Keychain 防止整机恢复克隆 dot；身份轮换会继承
  已知版本向量。多个 CloudKit Zone 的完整同步 pass 经过同一事务闸门，避免旧快照交叉
  落盘导致个人文件夹或共享画布回滚。
- CloudKit 推送负责降低延迟，zone change token 负责正确性；前台共享文稿每 4 秒轮询，
  即使漏推或 Debug profile 没有推送能力也会继续收敛。
- 文稿永久删除使用持久化因果墓碑，删除优先于离线改名/编辑；文件夹墓碑会继承到离线
  并发创建的子树。旧快照、重启和新设备全量下载都不能复活已经删除的稳定 ID。
- 旧版导入记录和旧版批注目录自动迁移。

目前明确不包含 OCR、手写识别、公式识别和 AI 搜索；PDF 搜索只搜索 PDF 自带文本层。

本地数据保存在应用沙盒的 `Application Support/TiyiNote/Workspace/`。

## 多人协作与冲突语义

CloudKit 只负责可靠传输和持久化，协作 operation 才是编辑状态的因果真相。页面 CKRecord
和 CKAsset 是快速启动快照；即使快照晚于 operation 到达，落盘后也会重新物化 operation，
因此不会靠文件时间决定笔迹、对象、旋转或删除结果。

| 数据 | 数据结构 | 并发规则 |
| --- | --- | --- |
| 新增笔迹 | 稳定 stroke ID 的 OR-Set | 不同笔迹取并集，顺序按 `zIndex + ID` 确定 |
| 对象编辑 | 完整恢复值 + changed-fields 补丁 | 不同字段合并；同字段用因果关系，真正并发才确定性裁决并保留副本 |
| 页面顺序 | Logoot 风格分数位置 | 并发插页不重编号，以 actor/counter 稳定打破相同路径 |
| 标题、页面属性 | 每字段因果 register | `after` 覆盖 `before`；并发才用 Lamport/actor/operationID，全程不使用设备时间裁决 |
| 页面/笔迹/对象删除 | remove-wins 因果墓碑反链 | 正常的因果删除不产生冲突；删除与未观察到它的编辑并发时删除胜出，并保留编辑副本 |
| 永久删除 | 按实体 ID 持久化的因果墓碑 | 离线旧快照、新设备和并发创建的文件夹子树都不能复活旧 ID |
| CloudKit 写冲突 | operation 使用唯一 record ID；可变记录带 change tag | operation 不互相覆盖；文件夹/个人引用/ACK/墓碑读取 server copy 后按因果规则合并并重试 |

每个 operation 包含 `(actorID, counter)` dot、它实际观察到的版本向量 context、Lamport 值和
唯一 operationID。设备时间只用于界面展示和旧版本迁移，不用于协作语义。脏画布若基于旧
frontier 保存，会创建独立 actor 分支，避免错误宣称它已经看过刚下载的远端编辑。文件夹
编辑器、移动选择器以及文本/图片/图形编辑器都会固定保存打开时的 frontier；弹窗未改动的
字段不回写，远端在弹窗背后删除对象时仍由 remove-wins 收敛，同时保留本地编辑冲突副本。

冲突版本支持“恢复副本”和“忽略”：恢复不会覆盖当前胜出内容，而是生成新对象/笔迹 ID；
处理动作本身也写入 operation，其他参与者会看到相同结果。日志回收只有在 CKShare 当前
所有参与者 ACK 对应 frontier 后才安全；现阶段仅计算安全集合，不执行破坏性 GC。

## iCloud 同步

CloudKit 是资料库唯一的云同步通道：文稿变化、应用进入前台以及远端推送都会触发自动同步。
资料库工具栏的 iCloud 状态面板显示当前状态和上次成功时间，并提供“现在同步”操作。产品界面
不再提供 Files/iCloud Drive 目录、版本保留或独立自动备份设置。一个设备上的永久删除仍会同步
到其他设备。

## 运行要求

- Xcode 26 或兼容版本
- iOS / iPadOS 26 及以上
- macOS 26 及以上（Mac Catalyst）

用 Xcode 打开 `TiyiNote.xcodeproj`，选择 iPad、iPhone 模拟器或 `My Mac (Mac Catalyst)` 后运行。

命令行构建 iOS 模拟器：

```sh
xcodebuild -project TiyiNote.xcodeproj \
  -scheme TiyiNote \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  build
```

没有 Apple Developer provisioning profile 时，可直接运行本地 Catalyst 版本：

```sh
./Scripts/run-catalyst-local.sh
```

该脚本使用临时本地签名，因此资料库、PDF 和多 Tab 可用，但 iCloud 会显示为未登录。
需要验证 iCloud 时，请在 Xcode 中选择有容器权限的 Team，并运行 `My Mac (Mac Catalyst)`。

## iCloud 配置

项目使用统一的 CloudKit 容器 `iCloud.com.tiyi.app`。要进行真实跨设备同步，需要：

1. 在 Apple Developer 后台为开发团队启用该容器。
2. 在 Xcode Signing & Capabilities 中选择有权使用该容器的 Team。
3. 私有资料库三台设备登录同一个 iCloud 账户；多人协作验收另准备第二个 iCloud 账户。
4. 发布版本要为 App ID 打开 Push Notifications；Release entitlement 已配置
   `aps-environment`，Debug 保留兼容现有 CloudKit 开发描述文件的配置。
5. 将 Development 中的 `TiyiDocumentReference`、`TiyiAcknowledgement`、
   `deletionPayload` 等最新 Record Type/字段部署到 Production，再提交 Release 构建。

未登录 iCloud、离线或模拟器没有可用账户时，应用仍可使用本地资料库，并在界面左下角显示同步状态。

Mac 登录测试 iCloud 账户、Xcode 完成开发签名后，可运行真实往返验收：

```sh
./Scripts/run-cloudkit-smoke.sh
```

脚本会使用三个互相隔离的本地资料库，自动验证嵌套文件夹、PDF、PencilKit
笔迹、图片对象、离线并发笔迹、对象“移动 + 透明度”的字段级合并、CKShare owner 区域、
个人引用先于共享内容到达、文件夹“移动 + 收藏”的分字段合并、离线改名与永久删除冲突、
第三个全新副本防复活、新设备重建以及 owner ACK，并删除本次专用的测试 Zone。输出
`TIYI_CLOUD_SMOKE_PASS` 才表示真实 CloudKit 往返通过。

资料库、画板和旧数据迁移的本地自动验收：

```sh
./Scripts/run-library-smoke.sh
```

输出 `TIYI_LIBRARY_SMOKE_PASS` 才表示收藏、批量移动、回收站、永久删除、
4 种画板背景、颜色、重启落盘，以及协作交换律/幂等性、乱序重复投递、离线末页恢复、
脏画布因果分支、页面/笔迹/对象并发删除反链、迟到页面快照重物化、个人引用因果合并和
引用早到持久化、旧文件夹编辑器与旧移动选择器的并发分支均通过。测试还覆盖专业笔刷/
橡皮擦配置、套索命中/复制/变换/粘贴、对象
字体/颜色/透明度/图形/锁定/层级/分组落盘、字段补丁、旧模型解码、扫描图片转多页 PDF、
扁平 PDF、逐页 PNG、系统打印可接受性和 `.tiyinote` 保真。

自动 smoke 只能覆盖同一测试账号的多设备与 CKShare owner 侧。发布前仍需用第二个真实
iCloud 账号验收：接受邀请、shared database 自动挂载、两端离线编辑后收敛、冲突副本
恢复、读写降级为只读、撤销参与者、停止共享，以及 Release 推送的后台延迟。

Mac、iPhone 模拟器和 iPad 模拟器的 iCloud 登录互不继承；要做三端 UI 验收，必须分别在每台模拟器的“设置”中登录同一个测试账户。Apple Developer 账号只负责签名和 CloudKit Console，不能代替设备上的测试 iCloud 账户。
