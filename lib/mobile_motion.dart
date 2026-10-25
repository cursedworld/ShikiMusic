import 'package:flutter/material.dart';

const mobileControlTransition = Duration(milliseconds: 180);
const mobileLyricsTransition = Duration(milliseconds: 280);

/// Short, controller-free route transitions; no animation work while idle.
class MobilePageTransitionsBuilder extends PageTransitionsBuilder {
  const MobilePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final eased = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return FadeTransition(
      opacity: eased,
      child: SlideTransition(
        position: eased.drive(
          Tween(begin: const Offset(0, 0.025), end: Offset.zero),
        ),
        child: child,
      ),
    );
  }
}

/// Fades only when switching sections, never on playback/volume updates.
/// Keeps one child mounted so scroll controllers are not shared by two pages.
class MobileSectionTransition extends StatefulWidget {
  const MobileSectionTransition({
    super.key,
    required this.section,
    required this.child,
  });
  final Object section;
  final Widget child;

  @override
  State<MobileSectionTransition> createState() =>
      _MobileSectionTransitionState();
}

class _MobileSectionTransitionState extends State<MobileSectionTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: mobileControlTransition,
    value: 1,
  );
  late final _opacity = _controller.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _controller.isAnimating) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant MobileSectionTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}
