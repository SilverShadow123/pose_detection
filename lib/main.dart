import 'package:flutter/material.dart';
import 'package:pose_detection/screens/real_time_recognition.dart';
import 'package:pose_detection/screens/register_student.dart';
import 'package:pose_detection/screens/home_screen.dart';
import 'package:pose_detection/screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      initialRoute: '/splash',
      title: 'Face Recognition App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/face_recognition': (context) => RealtimeFaceRecognition(),
        '/home': (context) => const HomeScreen(),
        '/register_student': (context) => const RegisterStudent(),
      },
    );
  }
}
