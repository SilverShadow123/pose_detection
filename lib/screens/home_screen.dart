import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late final AnimationController _staggerController;
  late final List<Animation<double>> _buttonAnimations;

  @override
  void initState() {
    super.initState();

    // Staggered animation controller
    _staggerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    // Create three curved animations with offsets
    _buttonAnimations = List.generate(3, (i) {
      final start = i * 0.2;
      final end = start + 0.5;
      return CurvedAnimation(
        parent: _staggerController,
        curve: Interval(start, end, curve: Curves.easeOut),
      );
    });
  }

  @override
  void dispose() {
    _staggerController.dispose();
    super.dispose();
  }

  Widget _buildGlassButton({
    required Animation<double> animation,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: animation,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Material(
                color: Colors.white.withAlpha(20),
                child: InkWell(
                  onTap: onTap,
                  splashColor: Colors.white24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 24,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white30),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(icon, size: 28, color: Colors.white),
                        const SizedBox(width: 16),
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.arrow_forward_ios,
                          size: 16,
                          color: Colors.white70,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Transparent AppBar over gradient
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Attendance System',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF3366FF), Color(0xFF00CCFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with avatar + greeting
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.white24,
                      child: const Icon(
                        Icons.people,
                        size: 32,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Welcome,',
                          style: TextStyle(fontSize: 16, color: Colors.white70),
                        ),
                        Text(
                          'User',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 40),

                // Buttons in a glassmorphic container
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _buildGlassButton(
                          animation: _buttonAnimations[0],
                          icon: Icons.person_add_alt_1,
                          label: 'Register',
                          onTap:
                              () => Navigator.pushNamed(
                                context,
                                '/register_student',
                              ),
                        ),
                        _buildGlassButton(
                          animation: _buttonAnimations[1],
                          icon: Icons.face_retouching_natural,
                          label: 'Real-time Recognition',
                          onTap:
                              () => Navigator.pushNamed(
                                context,
                                '/face_recognition',
                              ),
                        ),
                        _buildGlassButton(
                          animation: _buttonAnimations[2],
                          icon: Icons.exit_to_app,
                          label: 'Exit',
                          onTap: () => exit(0),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
