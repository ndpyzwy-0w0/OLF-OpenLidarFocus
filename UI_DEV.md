# FM03 App 界面开发

`ios/FollowFocusCore/` 负责协议、UDP、镜头LUT和会话；`ios/Runner/` 只搬运 `ff.core` 通道并采集LiDAR；`lib/` 只渲染状态和发送用户意图。位置闭环在ESP32固件里，不能在Flutter再写一份控制器。

新行为先改Swift功能层和测试，再接原生插件、Dart通道和界面。新版界面使用 FM03 坐标、归一化行程比例、拨轮最大值、容差、减速系数；不要用旧步距角/细分计算角度或速度。

## 本地预览

```sh
tool/ui_preview.sh
```

构建 release web，127.0.0.1:8123 提供静态文件。重新构建并刷新即可；`SKIP_BUILD=1` 只起服务，`PORT=9000` 换端口。预览使用演示核心假数据，不能检验UDP、CAN或LiDAR。

新建镜头后点“自动识别行程”可预览 FM03 内部校准确认和方向确认；CAN面板显示阶段、坐标、反馈年龄、发送失败/接收丢帧，以及最大拨轮速度、到位容差、接近减速系数。取消观察必须说明不能取消电机内部校准。界面不再显示电流、细分、SGTHRS、StealthChop和待机断电。

## 验证

```sh
flutter analyze
flutter test
cd ios/FollowFocusCore && swift test
```

UI测试只使用 `FakeCore.invoke` 验证命令意图；Swift测试使用loopback假板子验证真实UDP路径。改完界面用预览点一遍；真机机械检查按 HANDOFF.md 执行。
