import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:yunjihuiyi_meeting/widgets/text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/remote_config.dart';
import 'room.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _sandboxIdCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _roomNameCtrl = TextEditingController();
  bool _busy = false;
  String? _errorMessage;
  String? _statusMessage;
  String? _apiStatusMessage;

  // 环境变量配置（编译时注入）
  static const _envSandboxId = String.fromEnvironment('SANDBOX_ID');
  static const _envRoomName = String.fromEnvironment('ROOM_NAME');
  static const _envNickname = String.fromEnvironment('NICKNAME');

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedData());
    unawaited(_refreshApiStatus());
  }

  Future<void> _refreshApiStatus() async {
    final config = RemoteConfig.instance;
    await config.refresh();
    if (!mounted) return;
    setState(() {
      _apiStatusMessage = '当前接口: ${config.apiUrl} (${config.sourceLabel})';
    });
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 优先使用环境变量，其次使用保存的值
      _sandboxIdCtrl.text = _envSandboxId.isNotEmpty ? _envSandboxId : (prefs.getString('sandboxId') ?? '');
      _nicknameCtrl.text = _envNickname.isNotEmpty ? _envNickname : (prefs.getString('nickname') ?? '');
      _roomNameCtrl.text = _envRoomName.isNotEmpty ? _envRoomName : (prefs.getString('roomName') ?? '');
    });
  }

  @override
  void dispose() {
    _sandboxIdCtrl.dispose();
    _nicknameCtrl.dispose();
    _roomNameCtrl.dispose();
    super.dispose();
  }

  Room _buildRoom() {
    return Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: AudioPublishOptions(name: 'audio'),
        defaultCameraCaptureOptions: CameraCaptureOptions(
          maxFrameRate: 24,
          params: VideoParameters(dimensions: VideoDimensions(640, 480)),
        ),
        defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
          useiOSBroadcastExtension: true,
          params: VideoParameters(
            dimensions: VideoDimensionsPresets.h720_169,
          ),
        ),
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: false,
          videoCodec: 'VP8',
          videoEncoding: VideoEncoding(
            maxBitrate: 1500 * 1000,
            maxFramerate: 24,
          ),
          screenShareEncoding: VideoEncoding(
            maxBitrate: 2000 * 1000,
            maxFramerate: 15,
          ),
        ),
      ),
    );
  }

  Future<void> _prepareLocalMedia(Room room) async {
    if (lkPlatformIsMobile()) {
      // 使用批量请求，避免并发触发 PermissionManager 冲突
      await [Permission.microphone, Permission.camera].request();
      return;
    }
  }

  Future<void> _join() async {
    final authCode = _sandboxIdCtrl.text.trim();
    final nickname = _nicknameCtrl.text.trim();
    final roomName = _roomNameCtrl.text.trim();

    // 验证授权码
    if (authCode.isEmpty) {
      setState(() {
        _errorMessage = '请输入授权码';
      });
      return;
    }

    if (roomName.isEmpty) {
      setState(() {
        _errorMessage = '请输入房间名称';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = '正在获取房间信息...';
    });

    try {
      // 保存输入内容
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sandboxId', authCode);
      await prefs.setString('nickname', nickname);
      await prefs.setString('roomName', roomName);

      final displayName = nickname.isNotEmpty ? nickname : '用户${DateTime.now().millisecondsSinceEpoch % 10000}';

      // 调用后端 API 验证邀请码并获取 LiveKit Token
      final config = RemoteConfig.instance;
      await config.refresh();
      if (mounted) {
        setState(() {
          _apiStatusMessage = '当前接口: ${config.apiUrl} (${config.sourceLabel})';
          _statusMessage = '正在获取房间信息... 当前线路: ${config.apiUrl}';
        });
      }
      Map<String, dynamic>? tokenData;
      Object? lastError;

      for (var attempt = 1; attempt <= 2; attempt++) {
        if (attempt > 1) {
          setState(() {
            _statusMessage = '首条线路较慢，正在切换后重试...';
          });
          await config.refresh();
          if (mounted) {
            setState(() {
              _apiStatusMessage = '当前接口: ${config.apiUrl} (${config.sourceLabel})';
            });
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }

        final joinUri = Uri.parse('${config.apiUrl}/api/connection-details').replace(
          queryParameters: {
            'authCode': authCode,
            'roomName': roomName,
            'participantName': displayName,
          },
        );

        try {
          final httpResponse = await http.get(joinUri).timeout(
                const Duration(seconds: 8),
                onTimeout: () => throw TimeoutException('房间接口响应超时'),
              );

          if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            String errorMsg = '邀请码验证失败';
            try {
              final errData = jsonDecode(httpResponse.body) as Map<String, dynamic>;
              errorMsg = (errData['error'] as String?) ?? errorMsg;
            } catch (_) {}
            throw Exception(errorMsg);
          }

          tokenData = jsonDecode(httpResponse.body) as Map<String, dynamic>;
          break;
        } catch (e) {
          lastError = e;
          if (attempt == 2) {
            rethrow;
          }
        }
      }

      if (tokenData == null) {
        throw lastError ?? Exception('未获取到房间连接信息');
      }

      final serverUrl = tokenData['serverUrl'] as String;
      final participantToken = tokenData['participantToken'] as String;

      if (!mounted) return;

      Room? connectedRoom;
      EventsListener<RoomEvent>? connectedListener;
      Object? connectError;

      const connectOptions = ConnectOptions(
        timeouts: Timeouts(
          connection: Duration(seconds: 25),
          debounce: Duration(milliseconds: 100),
          publish: Duration(seconds: 20),
          subscribe: Duration(seconds: 20),
          peerConnection: Duration(seconds: 20),
          iceRestart: Duration(seconds: 20),
        ),
      );

      for (var attempt = 1; attempt <= 2; attempt++) {
        final room = _buildRoom();
        final listener = room.createListener();

        try {
          setState(() {
            _statusMessage = attempt == 1 ? '正在连接会议...' : '连接较慢，正在重试...';
          });

          await room.prepareConnection(serverUrl, participantToken);
          await room.connect(
            serverUrl,
            participantToken,
            connectOptions: connectOptions,
          );

          connectedRoom = room;
          connectedListener = listener;
          break;
        } catch (e) {
          connectError = e;
          await listener.dispose();
          unawaited(room.dispose());
          if (attempt == 2) {
            rethrow;
          }
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }

      if (connectedRoom == null || connectedListener == null) {
        throw connectError ?? TimeoutException('连接会议超时');
      }

      final room = connectedRoom;
      final listener = connectedListener;

      setState(() {
        _statusMessage = '已进入会议';
      });

      // 先完成权限请求，再跳转，避免跳转后用户立即点按钮与系统弹窗并发冲突
      await _prepareLocalMedia(room).catchError((_) => <void>[]);

      if (!mounted) return;

      // 进入房间页面，传入 authCode 用于离开时释放
      unawaited(Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RoomPage(
            room,
            listener,
            authCode: authCode,
            displayRoomName: roomName,
          ),
        ),
      ));
    } on TimeoutException catch (e) {
      setState(() {
        _errorMessage = e.message.isNotEmpty
            ? '连接超时: ${e.message}\n当前接口: ${RemoteConfig.instance.apiUrl}'
            : '连接超时，请稍后重试\n当前接口: ${RemoteConfig.instance.apiUrl}';
      });
    } catch (e) {
      setState(() {
        final config = RemoteConfig.instance;
        _errorMessage = '连接失败: $e\n当前接口: ${config.apiUrl}\n配置来源: ${config.sourceLabel}';
      });
    } finally {
      setState(() {
        _busy = false;
        _statusMessage = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        alignment: Alignment.center,
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Image.asset(
                      'images/yunjihuiyi-logo.png',
                      width: 100,
                      height: 100,
                    ),
                    const SizedBox(width: 16),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          '云际会议',
                          style: TextStyle(fontSize: 42, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '安全稳定的音视频会议',
                          style: TextStyle(fontSize: 18, color: Colors.white70),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 40),

                // 授权码输入
                LKTextField(
                  label: '授权码',
                  ctrl: _sandboxIdCtrl,
                  hintText: '请输入授权码',
                ),
                const SizedBox(height: 20),

                // 房间名称输入
                LKTextField(
                  label: '房间名称',
                  ctrl: _roomNameCtrl,
                  hintText: '请输入房间名称',
                ),
                const SizedBox(height: 20),

                // 昵称输入
                LKTextField(
                  label: '昵称',
                  ctrl: _nicknameCtrl,
                  hintText: '显示在房间中的名字',
                ),
                const SizedBox(height: 10),

                // 错误提示
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_statusMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _statusMessage!,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),

                const SizedBox(height: 30),

                // 加入按钮
                ElevatedButton(
                  onPressed: _busy ? null : _join,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('加入房间', style: TextStyle(fontSize: 18)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
