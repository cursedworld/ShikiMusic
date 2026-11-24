import 'package:flutter/material.dart';

class DesktopPlayerPanel extends StatelessWidget {
  const DesktopPlayerPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      color: Colors.black.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: const Alignment(0, 0.5),
      child: SingleChildScrollView(
        primary: false,
        physics: const ClampingScrollPhysics(),
        // In a short window, show the transport before the artwork.
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: child,
      ),
    );
  }
}
