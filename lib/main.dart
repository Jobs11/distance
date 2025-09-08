import 'package:distance/screens/mainhome.dart';
import 'package:distance/widgets/foreground.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:flutter_screenutil/flutter_screenutil.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  initForegroundTask();

  // 포트 초기화 (필수)
  FlutterForegroundTask.initCommunicationPort();

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(360, 780),
      child: WithForegroundTask(child: MaterialApp(home: Mainhome())),
    );
  }
}
