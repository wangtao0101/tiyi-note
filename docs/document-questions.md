# 文稿圈题

画板和 PDF 工具栏中橡皮擦后面的“圈题”按页面坐标圈取范围，松笔后可以拖动范围和四角。圈选边框、四角及“作答”浮动操作栏复用普通套索的视觉样式和避让定位；点击选区外取消圈选，不显示“取消”或“重新圈选”按钮。确认将 PDF/背景、页面对象和 PencilKit 笔迹合成为固定快照，打开文稿专属的作答编辑器。保存返回后，原范围中心的标记可继续打开同一作答。标记接入普通套索：点选或圈选后可拖动；操作栏仅提供“进入作答”和“删除”，不显示复制、拷贝、截图、对象菜单、缩放或旋转控件。多个标记一起选中时仅显示删除。点击空白取消选中；在书写工具下手指点击标记与普通图形一样选中并切换套索，再点“进入作答”；Pencil 经过标记继续书写。原题范围保存在 sourceBounds，移动只更新标记位置，不改变快照。旧标记首次加载会保存原题范围并解除旧版内置锁定；迁移后用户主动锁定的状态会保留。

作答复用 TiyiPracticeEditor，存储由 DocumentQuestionSession 接管。PageQuestionPayload 作为源页面对象携带题目快照、可编辑作答包、页面索引、最后一页和完成状态。普通文稿的圈题随文稿导出、导入、备份及 CloudKit 同步；两份并行作答保留为文稿冲突版本。

整卷 PDF 作答也提供圈题，标记与子作答保存在所属作答记录的页面对象中。子作答保存返回时保存整卷记录，之后由原有作答同步上传变更页，不上传原卷 PDF 或改动题库。普通逐题作答、讲义以及圈出来的子作答不开放这项工具。

圈题全屏展示保留源阅读器及其视口，退出前必须完成本机持久化。每次进入从当前页面附件恢复新的工作目录，避免旧缓存覆盖已同步的更新；正常退出清理工作副本。异常退出时工作副本暂留 Application Support/DocumentQuestionSessions。

## CloudKit 发布

CloudKit 记录类型 `TiyiOperation` 新增 `operationPayloadAsset`（Asset）。256 KB 以内继续使用原有 `operationPayload`（Bytes），更大的操作使用 CKAsset。上传临时文件保留到整个上传/冲突重试结束；下载解析失败不推进 zone token。未修改作答的周期性 checkpoint 不产生新版本。

2026-09-12 已通过 CloudKit Console 将 `iCloud.com.tiyi.app` 的 `TiyiOperation.operationPayloadAsset`（Asset）从 Development 部署到 Production，页面确认 “Changes Deployed / The schema is deployed to Production.”。部署差异仅包含这一新增字段，索引和 Security Roles 均为 0 项变更。同步同一文稿的客户端仍需更新到支持 question payload 的版本。自动化检查覆盖本机 CKRecord/CKAsset 编解码和文稿持久化，不能代替真实 iCloud 账号下的跨设备验证。

## 回归

`TiyiNoteQuestionUITests` 覆盖取消、画板/PDF 圈题、调整范围、作答笔迹、返回、完成标记、重启恢复，以及逐题作答隐藏圈题。整卷的圈题另外验证原页位置不变、重启后恢复标记和子作答笔迹；TiyiChat 的作答测试验证从账号同步恢复圈题，以及仅提交变更页。`Tests/DocumentQuestionChecks.swift` 的独立 debug 检查覆盖多页作答包恢复、最后页、原文稿其他对象保留、文稿导出导入、协作冲突、CloudKit 大附件、重复 checkpoint 和快照渲染。测试使用专属 workspace 和模拟器，不修改日常文稿库。

2026-09-12 本机验证：TiyiNoteQuestionUITests 三项通过（0 failures）；作答恢复前后 PencilKit 渲染图像一致；Note 独立目标与 TiyiChat 集成目标的 iOS Simulator 编译通过。测试结果位于 `/tmp/tiyi-note-question-tests-5.xcresult`，集成构建日志位于 `/tmp/tiyi-chat-question-build-final.log`。真实 iCloud 跨设备验证尚未执行；生产 schema 已按上文完成发布。

2026-09-12 套索接入验证：画板/PDF 圈题、点外取消、浮动栏位置、作答恢复、标记拖动/复制/删除/重启保存，以及普通图形点选和闭合套索回归通过（`/tmp/tiyi-question-lasso-tests.xcresult`，6 项通过）。最终图层顺序与截图调整后，标记完整交互、PDF 闭合套索圈中标记和附件数据检查再次通过（`/tmp/tiyi-question-lasso-final-tests.xcresult`，3 项通过）。TiyiChat 集成构建通过（`/tmp/tiyi-question-lasso-host-final.log`）。本次迁移标记属性封装在现有文稿附件中，无需新增 CloudKit 字段。

作答标记操作栏精简验证：仅显示“进入作答”和“删除”，不显示其他对象操作及缩放/旋转控件；进入作答、拖动保存、删除重启、PDF 闭合套索选中及普通图形操作回归均通过（`/tmp/tiyi-question-simple-actions-tests.xcresult`，3 项通过）。TiyiChat 集成构建通过（`/tmp/tiyi-question-simple-actions-host.log`）。
