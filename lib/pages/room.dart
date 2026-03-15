import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../exts.dart';
import '../services/remote_config.dart';
import '../utils.dart';
import '../widgets/chat.dart';
import '../widgets/controls.dart';
import '../widgets/participant.dart';

class RoomPage extends StatefulWidget {
  final Room room;
  final EventsListener<RoomEvent> listener;
  final String? authCode;
  final String? displayRoomName;

  const RoomPage(
    this.room,
    this.listener, {
    this.authCode,
    this.displayRoomName,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> with WidgetsBindingObserver {
  List<ParticipantTrack> participantTracks = [];
  final ValueNotifier<List<LocalChatMessage>> _chatMessagesNotifier = ValueNotifier([]);
  bool _isDisconnecting = false;

  EventsListener<RoomEvent> get _listener => widget.listener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // add callback for a `RoomEvent` as opposed to a `ParticipantEvent`
    widget.room.addListener(_onRoomDidUpdate);
    // add callbacks for finer grained events
    _setUpListeners();
    _sortParticipants();
    // 不再弹出发布确认对话框，默认进入会议时音视频关闭

    if (lkPlatformIs(PlatformType.android)) {
      unawaited(Hardware.instance.setSpeakerphoneOn(true));
    }

    if (lkPlatformIsDesktop()) {
      onWindowShouldClose = () async {
        unawaited(widget.room.disconnect());
        await _listener.waitFor<RoomDisconnectedEvent>(duration: const Duration(seconds: 5));
      };
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // App 被系统杀掉或切到后台时主动断开连接
    if (state == AppLifecycleState.detached) {
      unawaited(_safeDisconnect());
    }
  }

  Future<void> _safeDisconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    try {
      await widget.room.disconnect();
      // 通知 Token Server 释放授权码
      await _releaseAuthCode();
    } catch (e) {
      print('Error disconnecting: $e');
    }
  }

  /// 通知服务器释放邀请码使用状态
  Future<void> _releaseAuthCode() async {
    final authCode = widget.authCode;
    if (authCode == null || authCode.isEmpty) return;
    try {
      final config = RemoteConfig.instance;
      await config.refresh();

      Future<void> sendLeave() {
        final uri = Uri.parse('${config.apiUrl}/api/leave');
        return http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'authCode': authCode,
                'force': true,
              }),
            )
            .timeout(const Duration(seconds: 5));
      }

      try {
        await sendLeave();
      } catch (_) {
        await config.refresh();
        await sendLeave();
      }
    } catch (e) {
      print('释放邀请码失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // always dispose listener
    widget.room.removeListener(_onRoomDidUpdate);
    // 确保断开连接后再 dispose
    unawaited(_disposeRoomAsync());
    onWindowShouldClose = null;
    super.dispose();
  }

  Future<void> _disposeRoomAsync() async {
    await _safeDisconnect();
    await _listener.dispose();
    await widget.room.dispose();
    _chatMessagesNotifier.dispose();
  }

  /// for more information, see [event types](https://docs.livekit.io/client/events/#events)
  void _setUpListeners() => _listener
    ..on<RoomDisconnectedEvent>((event) async {
      if (event.reason != null) {
        print('Room disconnected: reason => ${event.reason}');
      }
      WidgetsBindingCompatible.instance
          ?.addPostFrameCallback((timeStamp) => Navigator.popUntil(context, (route) => route.isFirst));
    })
    ..on<ParticipantEvent>((event) {
      // sort participants on many track events as noted in documentation linked above
      _sortParticipants();
    })
    ..on<LocalTrackPublishedEvent>((_) => _sortParticipants())
    ..on<LocalTrackUnpublishedEvent>((_) => _sortParticipants())
    ..on<TrackSubscribedEvent>((_) => _sortParticipants())
    ..on<TrackUnsubscribedEvent>((_) => _sortParticipants())
    ..on<DataReceivedEvent>((event) {
      String decoded = 'Failed to decode';
      try {
        decoded = utf8.decode(event.data);
      } catch (err) {
        print('Failed to decode: $err');
      }
      _chatMessagesNotifier.value = [
        ..._chatMessagesNotifier.value,
        LocalChatMessage(
          senderName: event.participant?.name ?? event.participant?.identity ?? '未知',
          senderIdentity: event.participant?.identity ?? '',
          content: decoded,
          timestamp: DateTime.now(),
          isLocal: false,
        ),
      ];
    })
    ..on<AudioPlaybackStatusChanged>((event) async {
      if (!widget.room.canPlaybackAudio) {
        print('Audio playback failed for iOS Safari ..........');
        final yesno = await context.showPlayAudioManuallyDialog();
        if (yesno == true) {
          await widget.room.startAudio();
        }
      }
    });

  void _sendChatMessage(String text) async {
    _chatMessagesNotifier.value = [
      ..._chatMessagesNotifier.value,
      LocalChatMessage(
        senderName: widget.room.localParticipant?.name ?? '我',
        senderIdentity: widget.room.localParticipant?.identity ?? '',
        content: text,
        timestamp: DateTime.now(),
        isLocal: true,
      ),
    ];
    unawaited(widget.room.localParticipant?.publishData(
      utf8.encode(text),
      reliable: true,
    ));
  }

  void _showChatPanel() {
    unawaited(showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      builder: (_) => ChatPanel(
        room: widget.room,
        messagesNotifier: _chatMessagesNotifier,
        onSend: _sendChatMessage,
      ),
    ));
  }

  void _onRoomDidUpdate() {
    _sortParticipants();
  }

  void _sortParticipants() {
    final userMediaTracks = <ParticipantTrack>[];
    final screenTracks = <ParticipantTrack>[];
    for (var participant in widget.room.remoteParticipants.values) {
      for (var t in participant.videoTrackPublications) {
        if (t.isScreenShare) {
          screenTracks.add(ParticipantTrack(
            participant: participant,
            type: ParticipantTrackType.kScreenShare,
          ));
        } else {
          userMediaTracks.add(ParticipantTrack(participant: participant));
        }
      }
    }
    // sort speakers for the grid
    userMediaTracks.sort((a, b) {
      // loudest speaker first
      if (a.participant.isSpeaking && b.participant.isSpeaking) {
        if (a.participant.audioLevel > b.participant.audioLevel) {
          return -1;
        } else {
          return 1;
        }
      }

      // last spoken at
      final aSpokeAt = a.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;
      final bSpokeAt = b.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;

      if (aSpokeAt != bSpokeAt) {
        return aSpokeAt > bSpokeAt ? -1 : 1;
      }

      // video on
      if (a.participant.hasVideo != b.participant.hasVideo) {
        return a.participant.hasVideo ? -1 : 1;
      }

      // joinedAt
      return a.participant.joinedAt.millisecondsSinceEpoch - b.participant.joinedAt.millisecondsSinceEpoch;
    });

    final localParticipantTracks = widget.room.localParticipant?.videoTrackPublications;
    if (localParticipantTracks != null) {
      for (var t in localParticipantTracks) {
        if (t.isScreenShare) {
          screenTracks.add(ParticipantTrack(
            participant: widget.room.localParticipant!,
            type: ParticipantTrackType.kScreenShare,
          ));
        } else {
          userMediaTracks.add(ParticipantTrack(participant: widget.room.localParticipant!));
        }
      }
    }
    setState(() {
      participantTracks = [...screenTracks, ...userMediaTracks];
    });
  }

  List<Participant> get _allParticipants {
    final participants = <Participant>[];
    final localParticipant = widget.room.localParticipant;
    if (localParticipant != null) {
      participants.add(localParticipant);
    }
    participants.addAll(widget.room.remoteParticipants.values);
    return participants;
  }

  Widget _buildRoomHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.meeting_room, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.displayRoomName?.isNotEmpty == true
                      ? widget.displayRoomName!
                      : (widget.room.name?.isNotEmpty == true ? widget.room.name! : '未命名房间'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '参会人数 ${_allParticipants.length} 人',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStage() {
    if (participantTracks.isEmpty) {
      return Container(
        color: const Color(0xFF0a1929),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_off,
              size: 56,
              color: Colors.white38,
            ),
            SizedBox(height: 12),
            Text(
              '等待音视频画面',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return ParticipantWidget.widgetFor(participantTracks.first);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final navigator = Navigator.of(context);
          // 按返回键时先断开连接再退出
          await _safeDisconnect();
          if (mounted) {
            navigator.pop();
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  Expanded(child: _buildStage()),
                  if (widget.room.localParticipant != null)
                    SafeArea(
                      top: false,
                      child: ControlsWidget(
                        widget.room,
                        widget.room.localParticipant!,
                        onChatOpen: _showChatPanel,
                      ),
                    ),
                ],
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildRoomHeader(),
              ),
            ],
          ),
        ),
      );
}
