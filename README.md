# 云际会议

这是一个已经从 LiveKit Flutter 示例工程中独立出来的会议客户端项目，保留的核心能力包括：

- 音频通话
- 视频通话
- 屏幕共享
- 文本消息
- 房间名称展示
- 参会人列表

## 快速开始

```bash
flutter pub get
flutter run
```

首次在不同平台运行时，Flutter 会自动重新生成各平台的插件注册文件和部分临时构建文件，这属于正常行为，这些文件已经通过 `.gitignore` 排除。

## 项目说明

- 项目包名：`yunjihuiyi_meeting`
- SDK 依赖：`livekit_client`
- 当前目录已经可以作为独立 Flutter 工程单独使用，不再依赖上级 `../` 本地路径包

## Railway 部署

这个项目已经包含 Railway 可用的 Docker 部署文件，可以直接作为 Docker 项目部署。

部署方式：

1. 把当前项目推到 Git 仓库
2. 在 Railway 创建新项目并选择该仓库
3. Railway 会自动识别 `Dockerfile`
4. 构建完成后会自动启动 Web 服务

说明：

- 容器会先执行 `flutter build web --release --no-wasm-dry-run`
- 然后用一个轻量 Node 静态服务托管 `build/web`
- 服务端口自动读取 Railway 的 `PORT` 环境变量

## 已清理内容

- 删除了原示例工程中的多余会议控制项与调试展示
- 清理了未使用资源和平台示例残留命名
- 清理了构建目录、ephemeral 目录和插件自动生成文件
