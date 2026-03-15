import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:yunjihuiyi_meeting/theme.dart';

import 'no_video.dart';

enum ParticipantTrackType {
  kUserMedia,
  kScreenShare,
}

extension ParticipantTrackTypeExt on ParticipantTrackType {
  TrackSource get lkVideoSourceType => {
        ParticipantTrackType.kUserMedia: TrackSource.camera,
        ParticipantTrackType.kScreenShare: TrackSource.screenShareVideo,
      }[this]!;

  TrackSource get lkAudioSourceType => {
        ParticipantTrackType.kUserMedia: TrackSource.microphone,
        ParticipantTrackType.kScreenShare: TrackSource.screenShareAudio,
      }[this]!;
}

class ParticipantTrack {
  ParticipantTrack({required this.participant, this.type = ParticipantTrackType.kUserMedia});

  final Participant participant;
  final ParticipantTrackType type;
}

abstract class ParticipantWidget extends StatefulWidget {
  static ParticipantWidget widgetFor(ParticipantTrack participantTrack) {
    if (participantTrack.participant is LocalParticipant) {
      return LocalParticipantWidget(participantTrack.participant as LocalParticipant, participantTrack.type);
    }
    if (participantTrack.participant is RemoteParticipant) {
      return RemoteParticipantWidget(participantTrack.participant as RemoteParticipant, participantTrack.type);
    }
    throw UnimplementedError('Unknown participant type');
  }

  abstract final Participant participant;
  abstract final ParticipantTrackType type;

  const ParticipantWidget({super.key});
}

class LocalParticipantWidget extends ParticipantWidget {
  @override
  final LocalParticipant participant;

  @override
  final ParticipantTrackType type;

  const LocalParticipantWidget(this.participant, this.type, {super.key});

  @override
  State<StatefulWidget> createState() => _LocalParticipantWidgetState();
}

class RemoteParticipantWidget extends ParticipantWidget {
  @override
  final RemoteParticipant participant;

  @override
  final ParticipantTrackType type;

  const RemoteParticipantWidget(this.participant, this.type, {super.key});

  @override
  State<StatefulWidget> createState() => _RemoteParticipantWidgetState();
}

abstract class _ParticipantWidgetState<T extends ParticipantWidget> extends State<T> {
  VideoTrack? get activeVideoTrack;
  bool get isScreenShare => widget.type == ParticipantTrackType.kScreenShare;
  bool get isLocal => widget.participant is LocalParticipant;

  @override
  void initState() {
    super.initState();
    widget.participant.addListener(_onParticipantChanged);
  }

  @override
  void dispose() {
    widget.participant.removeListener(_onParticipantChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      oldWidget.participant.removeListener(_onParticipantChanged);
      widget.participant.addListener(_onParticipantChanged);
    }
  }

  void _onParticipantChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        foregroundDecoration: BoxDecoration(
          border: widget.participant.isSpeaking && !isScreenShare
              ? Border.all(
                  width: 5,
                  color: LKColors.lkBlue,
                )
              : null,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF0a1929),
        ),
        child: _buildVideoContent(),
      );

  Widget _buildVideoContent() {
    final isLocalScreenShare = isLocal && isScreenShare;
    if (!isLocalScreenShare && activeVideoTrack != null && !activeVideoTrack!.muted) {
      return VideoTrackRenderer(
        renderMode: VideoRenderMode.auto,
        fit: VideoViewFit.cover,
        activeVideoTrack!,
      );
    }
    if (isLocalScreenShare) {
      return const _LocalScreenSharePlaceholder();
    }
    return const NoVideoWidget();
  }
}

class _LocalScreenSharePlaceholder extends StatelessWidget {
  const _LocalScreenSharePlaceholder();

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.screen_share_outlined,
              size: 48,
              color: Colors.white70,
            ),
            SizedBox(height: 8),
            Text(
              '本地共享屏幕预览已隐藏',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
}

class _LocalParticipantWidgetState extends _ParticipantWidgetState<LocalParticipantWidget> {
  LocalTrackPublication<LocalVideoTrack>? get videoPublication => widget.participant.videoTrackPublications
      .where((element) => element.source == widget.type.lkVideoSourceType)
      .firstOrNull;

  @override
  VideoTrack? get activeVideoTrack => videoPublication?.track;
}

class _RemoteParticipantWidgetState extends _ParticipantWidgetState<RemoteParticipantWidget> {
  RemoteTrackPublication<RemoteVideoTrack>? get videoPublication => widget.participant.videoTrackPublications
      .where((element) => element.source == widget.type.lkVideoSourceType)
      .firstOrNull;

  @override
  VideoTrack? get activeVideoTrack => videoPublication?.track;
}
