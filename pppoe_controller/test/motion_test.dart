import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pppoe_controller/motion.dart';
import 'package:pppoe_controller/nothing_theme.dart';

void main() {
  for (final preference in ['normal', 'disableAnimations', 'accessibleNavigation']) {
    testWidgets('press feedback preserves activation and hitbox: $preference', (tester) async {
      var activations = 0;
      await tester.pumpWidget(MaterialApp(
        theme: getNothingTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: preference == 'disableAnimations',
            accessibleNavigation: preference == 'accessibleNavigation',
          ),
          child: Scaffold(body: Center(child: ElevatedButton(
            onPressed: () => activations++,
            child: const Text('Connect'),
          ))),
        ),
      ));
      final button = find.byType(ElevatedButton);
      final originalRect = tester.getRect(button);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pumpAndSettle();
      final feedback = tester.widget<AnimatedScale>(find.descendant(
        of: button, matching: find.byType(AnimatedScale),
      ));
      expect(feedback.scale, preference == 'normal' ? 0.96 : 1);
      if (preference != 'normal') expect(feedback.duration, Duration.zero);
      expect(tester.getRect(button), originalRect);
      expect(activations, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(activations, 1);
      expect(tester.widget<AnimatedScale>(find.descendant(
        of: button, matching: find.byType(AnimatedScale),
      )).scale, 1);
    });
  }

  testWidgets('disabled button cannot activate through animated feedback', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: getNothingTheme(),
      home: const Scaffold(body: ElevatedButton(onPressed: null, child: Text('Connect'))),
    ));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ElevatedButton)));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await gesture.up();
  });

  testWidgets('reduced motion removes page visual transitions', (tester) async {
    const child = Text('Destination');
    late Widget transition;
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Builder(builder: (context) {
        transition = const NothingPageTransitionsBuilder().buildTransitions<void>(
          MaterialPageRoute<void>(builder: (_) => child),
          context,
          const AlwaysStoppedAnimation(0.25),
          const AlwaysStoppedAnimation(0),
          child,
        );
        return transition;
      }),
    )));
    expect(identical(transition, child), isTrue);
  });
}
