import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated galaxy + energy waves + voice visualizer. No static black screen.
class LiveBackground extends StatefulWidget {
  const LiveBackground({
    super.key,
    required this.speaking,
    required this.listening,
  });

  final bool speaking;
  final bool listening;

  @override
  State<LiveBackground> createState() => _LiveBackgroundState();
}

class _LiveBackgroundState extends State<LiveBackground>
    with TickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

  late final AnimationController _bars = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final List<_Star> _stars;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(42);
    _stars = List.generate(
      110,
      (_) => _Star(
        x: rnd.nextDouble(),
        y: rnd.nextDouble(),
        size: 0.6 + rnd.nextDouble() * 1.8,
        brightness: 0.45 + rnd.nextDouble() * 0.55,
        phase: rnd.nextDouble() * math.pi * 2,
      ),
    );
  }

  @override
  void dispose() {
    _flow.dispose();
    _bars.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_flow, _bars]),
      builder: (context, _) => CustomPaint(
        painter: _GalaxyPainter(
          stars: _stars,
          flow: _flow.value,
          bars: _bars.value,
          speaking: widget.speaking,
          listening: widget.listening,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.brightness,
    required this.phase,
  });

  final double x;
  final double y;
  final double size;
  final double brightness;
  final double phase;
}

class _GalaxyPainter extends CustomPainter {
  const _GalaxyPainter({
    required this.stars,
    required this.flow,
    required this.bars,
    required this.speaking,
    required this.listening,
  });

  final List<_Star> stars;
  final double flow;
  final double bars;
  final bool speaking;
  final bool listening;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    final energy = speaking ? 1.0 : (listening ? 0.55 : 0.0);

    // Deep space base.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Color(0xFF010610), Color(0xFF041427), Color(0xFF010812)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(rect),
    );

    // Central breathing glow.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.02),
          radius: 0.78,
          colors: [
            Colors.cyan.withOpacity(0.09 + energy * 0.12),
            Colors.blue.withOpacity(0.06 + energy * 0.05),
            Colors.transparent,
          ],
        ).createShader(rect),
    );

    // Slow-moving stars.
    for (final s in stars) {
      final drift = speaking ? 0.075 : 0.028;
      final y = ((s.y - flow * drift) % 1.0) * h;
      final x = s.x * w + math.sin(flow * math.pi * 2 + s.phase) * 7;
      final pulse = 0.5 + 0.5 * math.sin(flow * math.pi * 4 + s.phase);
      final alpha =
          ((0.18 + 0.55 * pulse) * s.brightness).clamp(0.0, 1.0).toDouble();
      canvas.drawCircle(
        Offset(x, y),
        s.size,
        Paint()..color = Colors.white.withOpacity(alpha),
      );
    }

    // Energy waves behind the avatar.
    final phase = flow * math.pi * 2 * (speaking ? 5 : 2);
    for (var i = 0; i < 5; i++) {
      final path = Path();
      final baseY = h * (0.30 + i * 0.13);
      for (var x = 0.0; x <= w + 12; x += 12) {
        final y = baseY +
            math.sin(x / w * math.pi * 4 + phase + i * 0.8) *
                (10 + energy * 26);
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.cyan
              .withOpacity((0.16 - i * 0.02) + energy * (0.16 - i * 0.02))
          ..style = PaintingStyle.stroke
          ..strokeWidth = speaking ? 2.4 : 1.3
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }

    // Voice visualizer at the bottom.
    const count = 56;
    for (var i = 0; i < count; i++) {
      final norm = i / (count - 1);
      final wobble =
          0.5 + 0.5 * math.sin(i * 0.72 + bars * math.pi * 2 * (speaking ? 3 : 1));
      final amp = (speaking ? h * 0.085 : h * 0.022) * (0.35 + wobble * 0.65);
      final barWidth = math.max(2.0, w / count * 0.48);
      final r = Rect.fromLTWH(w * norm - barWidth / 2, h - amp, barWidth, amp);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(3)),
        Paint()
          ..color = Colors.cyan.withOpacity(
            0.10 + wobble * (speaking ? 0.48 : 0.18),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GalaxyPainter oldDelegate) => true;
}
