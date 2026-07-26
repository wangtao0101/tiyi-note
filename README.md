# Tiyi Note

一个使用 SwiftUI、PDFKit、PencilKit 构建的本地 PDF 笔记原型，目标平台为 iPadOS / iOS 17 及以上。

## 已实现

- Apple Pencil 钢笔和荧光笔
- 六种常用颜色和粗细调节
- 矢量橡皮擦
- 撤销、重做、清空画板
- Apple Pencil 优先，可切换手指书写
- 本地自动保存和启动恢复
- 可编辑笔记标题
- 默认打开 37 页《数论初步：同余》和 7 页《中考几何压轴》两个 PDF Tab
- 支持一次导入多个 PDF、切换/关闭/重新打开文档 Tab
- PDF 页面连续竖向滚动，每一页均可独立批注
- 工具栏页面按钮可打开缩略图侧栏并快速跳转

每一页的批注独立保存于应用沙盒的 `Application Support/TiyiNote/Workspace/Drawings/`。

## 运行

用 Xcode 打开 `TiyiNote.xcodeproj`，选择 iPad 模拟器或真机后运行。命令行构建：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TiyiNote.xcodeproj \
  -scheme TiyiNote \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

模拟器会自动开启手指输入，可以直接按住鼠标在画板上书写；真机默认使用 Apple Pencil，工具栏中的手掌按钮可以切换手指书写。
