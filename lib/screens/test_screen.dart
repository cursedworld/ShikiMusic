import 'package:flutter/material.dart';
import '../localization.dart';

class TestScreen extends StatelessWidget {
  const TestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(tr('test_screen'))));
  }
}
