# Tiyi Note

一个使用 SwiftUI、PDFKit、PencilKit 构建的本地 PDF 笔记原型，目标平台为 iPadOS / iOS 17 及以上。

## 已实现

- Apple Pencil 等宽钢笔和荧光笔，纯黑钢笔最细支持 0.1
- 六种常用颜色和粗细调节
- 三档固定宽度橡皮擦及范围指示
- GoodNotes 蓝色自由套索，支持选区缩放、移动、删除、偏移复制、拷贝和跨页粘贴
- 撤销、重做、清空画板
- iPad 真机仅 Apple Pencil 可以书写，手指用于滚动与双指缩放
- 本地自动保存和启动恢复
- 可编辑笔记标题
- 默认打开 37 页《数论初步：同余》和 7 页《中考几何压轴》两个 PDF Tab
- 支持一次导入多个 PDF、切换/关闭/重新打开文档 Tab
- PDF 页面连续竖向滚动，每一页均可独立批注
- PDF 支持双指缩放，放大后可横向和纵向移动
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

模拟器可以直接按住鼠标在画板上书写；iPad 真机强制使用 Apple Pencil，手指不会产生笔迹。
