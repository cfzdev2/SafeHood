import 'package:flutter/material.dart';

import '../features/auth/presentation/auth_gate.dart';

class SafeHoodApp extends StatelessWidget {
  const SafeHoodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeHood',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const AuthGate(),
    );
  }
}