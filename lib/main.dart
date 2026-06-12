import 'package:distance/screens/intro_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:distance/widgets/foreground.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  initForegroundTask();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(360, 780),
      child: WithForegroundTask(
        child: MaterialApp(
          title: 'Smartphone Loss Device',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: 'sans-serif',
            scaffoldBackgroundColor: const Color(0xFFFAF7F2),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF7B6B5A),
              background: const Color(0xFFFAF7F2),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFFAF7F2),
              elevation: 0,
              iconTheme: IconThemeData(color: Color(0xFF3D3530)),
              titleTextStyle: TextStyle(
                color: Color(0xFF3D3530),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          home: const IntroPage(),
        ),
      ),
    );
  }
}
