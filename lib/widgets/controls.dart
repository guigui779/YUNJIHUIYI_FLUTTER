import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:livekit_client/livekit_client.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../exts.dart';

class ControlsWidget extends StatefulWidget {
  final Room room;
  final LocalParticipant participant;
  final VoidCallback? onChatOpen;

  const ControlsWidget(
    this.room,
    this.participant, {
    this.onChatOpen,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _ControlsWidgetState();
}

class _ControlsWidgetState extends State<ControlsWidget> {
  bool _speakerphoneOn = Hardware.instance.speakerOn ?? false;
  bool _screenShareStarting = false;
  final Set<String> _pendingActions = <String>{};

  @override
  void initState() {
    super.initState();
    participant.addListener(_onChange);
  }

  @override
  void dispose() {
    participant.removeListener(_onChange);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ControlsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      oldWidget.participant.removeListener(_onChange);
      widget.participant.addListener(_onChange);
    }
  }

  LocalParticipant get participant => widget.participant;

  Widget _buildLabeledButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
    bool enabled = true,
  }) {
    final resolvedColor = enabled ? (color ?? Colors.white) : Colors.white38;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onPressed : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: resolvedColor, size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? (color ?? Colors.white70) : Colors.white38,
                  fontSize: 10,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runAction(String key, Future<void> Function() action) async {
    if (_pendingActions.contains(key)) {
      return;
    }
    setState(() {
      _pendingActions.add(key);
    });
    try {
      await action();
    } catch (error) {
      print('control action failed [$key]: $error');
      if (mounted) {
        await context.showErrorDialog(error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _pendingActions.remove(key);
        });
      }
    }
  }

  void _onChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _disableAudio() async => _runAction('audio', () async {
        await participant.setMicrophoneEnabled(false);
      });

  Future<void> _enableAudio() async {
    await _runAction('audio', () async {
      // 只在首次需要时请求权限，已经发布过音频则跳过
      if (lkPlatformIsMobile() && participant.audioTrackPublications.isEmpty) {
        final status = await Permission.microphone.request();
        if (!status.isGranted && !status.isLimited) {
          print('Microphone permission not granted: $status');
          if (mounted) {
            if (status.isPermanentlyDenied) {
              await context.showErrorDialog('麦克风权限已被拒绝，请到系统设置中开启');
              unawaited(openAppSettings());
            } else {
              await context.showErrorDialog('需要麦克风权限才能开启音频');
            }
          }
          return;
        }
      }
      await participant.setMicrophoneEnabled(true);
    });
  }

  Future<void> _disableVideo() async => _runAction('video', () async {
        await participant.setCameraEnabled(false);
      });

  Future<void> _enableVideo() async {
    await _runAction('video', () async {
      // 只在首次需要时请求权限，已经在房间内发布过视频则跳过权限检查
      if (lkPlatformIsMobile() && participant.videoTrackPublications.isEmpty) {
        final status = await Permission.camera.request();
        if (!status.isGranted && !status.isLimited) {
          print('Camera permission not granted: $status');
          if (mounted) {
            if (status.isPermanentlyDenied) {
              await context.showErrorDialog('摄像头权限已被拒绝，请到系统设置中开启');
              unawaited(openAppSettings());
            } else {
              await context.showErrorDialog('需要摄像头权限才能开启视频');
            }
          }
          return;
        }
      }
      await participant.setCameraEnabled(true);
    });
  }

  Future<void> _setSpeakerphoneOn() async => _runAction('speaker', () async {
        final nextValue = !_speakerphoneOn;
        await widget.room.setSpeakerOn(nextValue, forceSpeakerOutput: false);
        if (mounted) {
          setState(() {
            _speakerphoneOn = nextValue;
          });
        }
      });

  Future<void> _enableScreenShare() async {
    if (_screenShareStarting) {
      return;
    }
    _screenShareStarting = true;

    if (lkPlatformIsDesktop()) {
      try {
        final source = await showDialog<DesktopCapturerSource>(
          context: context,
          builder: (context) => ScreenSelectDialog(),
        );
        if (source == null) {
          print('cancelled screenshare');
          return;
        }
        print('DesktopCapturerSource: ${source.id}');
        final track = await LocalVideoTrack.createScreenShareTrack(
          ScreenShareCaptureOptions(
            sourceId: source.id,
            maxFrameRate: 15.0,
          ),
        );
        await participant.publishVideoTrack(track);
      } catch (e) {
        print('could not publish video: $e');
      } finally {
        _screenShareStarting = false;
      }
      return;
    }
    try {
      if (lkPlatformIs(PlatformType.android)) {
        final prepared = await _prepareAndroidScreenShare();
        if (!prepared) {
          return;
        }
      }

      if (lkPlatformIsWebMobile()) {
        if (!mounted) return;
        await context.showErrorDialog('Screen share is not supported on mobile web');
        return;
      }

      if (lkPlatformIs(PlatformType.iOS)) {
        // iOS: 提示用户操作
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('开启屏幕共享'),
            content: const Text(
              '点击下方"开始"后，系统会弹出广播选择器。\n\n'
              '请点击"开始直播"来共享您的屏幕。\n\n'
              '如果没有弹出，请从控制中心长按录屏按钮，选择"云际会议"。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  unawaited(participant.setScreenShareEnabled(true, captureScreenAudio: true));
                },
                child: const Text('开始'),
              ),
            ],
          ),
        );
        return;
      }

      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          await participant.setScreenShareEnabled(true, captureScreenAudio: true);
          return;
        } catch (e) {
          print('could not enable screen share (attempt $attempt): $e');
          if (!lkPlatformIs(PlatformType.android) || attempt == 2) {
            return;
          }
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
    } finally {
      _screenShareStarting = false;
    }
  }

  Future<void> _disableScreenShare() async => _runAction('screenShare', () async {
        await participant.setScreenShareEnabled(false);
        if (lkPlatformIs(PlatformType.android)) {
          try {
            await _disableAndroidBackgroundExecution();
          } catch (error) {
            print('error disabling screen share: $error');
          }
        }
      });

  Future<bool> _requestAndroidNotificationPermission() async {
    final notificationStatus = await Permission.notification.status;
    if (notificationStatus.isGranted || notificationStatus.isLimited) {
      return true;
    }
    final requestedStatus = await Permission.notification.request();
    if (requestedStatus.isGranted || requestedStatus.isLimited) {
      return true;
    }
    print('Notification permission not granted: $requestedStatus');
    if (requestedStatus.isPermanentlyDenied) {
      unawaited(openAppSettings());
    }
    return false;
  }

  Future<bool> _prepareAndroidScreenShare() async {
    final hasCapturePermission = await Helper.requestCapturePermission();
    if (!hasCapturePermission) {
      return false;
    }

    // 首次点击时，系统录屏授权返回后 MediaProjection/前台服务常常还没完全就绪。
    await Future.delayed(const Duration(milliseconds: 350));

    for (var attempt = 1; attempt <= 2; attempt++) {
      var backgroundOk = await _enableAndroidBackgroundExecution();
      if (!backgroundOk && attempt == 1) {
        final notificationGranted = await _requestAndroidNotificationPermission();
        if (!notificationGranted) {
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 350));
        backgroundOk = await _enableAndroidBackgroundExecution();
      }

      if (backgroundOk) {
        await Future.delayed(const Duration(milliseconds: 250));
        return true;
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }

    return false;
  }

  Future<bool> _enableAndroidBackgroundExecution() async {
    try {
      const androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: '屏幕共享',
        notificationText: '云际会议正在共享屏幕',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(name: 'livekit_ic_launcher', defType: 'mipmap'),
      );
      final hasPermissions = await FlutterBackground.initialize(androidConfig: androidConfig);
      if (!hasPermissions) {
        print('FlutterBackground permissions not granted');
        return false;
      }
      if (!FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.enableBackgroundExecution();
      }
      return FlutterBackground.isBackgroundExecutionEnabled;
    } catch (e) {
      print('could not enable background execution: $e');
      return false;
    }
  }

  Future<void> _disableAndroidBackgroundExecution() async {
    if (FlutterBackground.isBackgroundExecutionEnabled) {
      await FlutterBackground.disableBackgroundExecution();
    }
  }

  Future<void> _onTapDisconnect() async => _runAction('disconnect', () async {
        final result = await context.showDisconnectDialog();
        if (result == true) {
          await widget.room.disconnect();
        }
      });

  void _onTapSendData() {
    if (widget.onChatOpen != null) {
      widget.onChatOpen!();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 15,
        horizontal: 15,
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        spacing: 20,
        runSpacing: 12,
        children: [
          if (participant.isMicrophoneEnabled())
            _buildLabeledButton(
              icon: Icons.mic,
              label: '麦克风',
              onPressed: () => unawaited(_disableAudio()),
              enabled: !_pendingActions.contains('audio'),
            )
          else
            _buildLabeledButton(
              icon: Icons.mic_off,
              label: '麦克风',
              onPressed: () => unawaited(_enableAudio()),
              enabled: !_pendingActions.contains('audio'),
            ),
          if (!kIsWeb && lkPlatformIsMobile())
            _buildLabeledButton(
              icon: _speakerphoneOn ? Icons.volume_up : Icons.volume_off,
              label: '扬声器',
              onPressed: () => unawaited(_setSpeakerphoneOn()),
              enabled: !_pendingActions.contains('speaker'),
            ),
          if (participant.isCameraEnabled())
            _buildLabeledButton(
              icon: Icons.videocam,
              label: '摄像头',
              onPressed: () => unawaited(_disableVideo()),
              enabled: !_pendingActions.contains('video'),
            )
          else
            _buildLabeledButton(
              icon: Icons.videocam_off,
              label: '摄像头',
              onPressed: () => unawaited(_enableVideo()),
              enabled: !_pendingActions.contains('video'),
            ),
          if (participant.isScreenShareEnabled())
            _buildLabeledButton(
              icon: Icons.stop_screen_share,
              label: '共享',
              onPressed: () => unawaited(_disableScreenShare()),
              enabled: !_pendingActions.contains('screenShare') && !_screenShareStarting,
            )
          else
            _buildLabeledButton(
              icon: Icons.screen_share,
              label: '共享',
              onPressed: () => unawaited(_enableScreenShare()),
              enabled: !_pendingActions.contains('screenShare') && !_screenShareStarting,
            ),
          _buildLabeledButton(
            icon: Icons.chat,
            label: '消息',
            onPressed: _onTapSendData,
          ),
          _buildLabeledButton(
            icon: Icons.call_end,
            label: '挂断',
            onPressed: () => unawaited(_onTapDisconnect()),
            color: Colors.red,
            enabled: !_pendingActions.contains('disconnect'),
          ),
        ],
      ),
    );
  }
}
