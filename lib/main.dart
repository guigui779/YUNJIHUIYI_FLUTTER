import 'package:flutter/material.dart';
import 'package:yunjihuiyi_meeting/theme.dart';
import 'pages/login.dart';
import 'services/remote_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RemoteConfig.instance.init();

  runApp(const YunjihuiyiMeetingApp());
}

class YunjihuiyiMeetingApp extends StatelessWidget {
  //
  const YunjihuiyiMeetingApp({
    super.key,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '云际会议',
        theme: MeetingTheme().buildThemeData(context),
        home: const LoginPage(),
      );
}
