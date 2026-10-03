import 'package:flutter/material.dart';

bool reduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
    MediaQuery.accessibleNavigationOf(context);

Duration motionDuration(BuildContext context, [int milliseconds = 180]) =>
    reduceMotion(context) ? Duration.zero : Duration(milliseconds: milliseconds);

Widget buttonPressFeedback(
  BuildContext context,
  Set<WidgetState> states,
  Widget? child,
) {
  return AnimatedScale(
    scale: !reduceMotion(context) && states.contains(WidgetState.pressed) ? 0.96 : 1,
    duration: motionDuration(context, 100),
    curve: Curves.easeOutCubic,
    child: child,
  );
}

class NothingPageTransitionsBuilder extends PageTransitionsBuilder {
  const NothingPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion(context)) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
      child: SlideTransition(
        position: animation.drive(
          Tween(begin: const Offset(0.025, 0), end: Offset.zero)
              .chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        child: child,
      ),
    );
  }
}
