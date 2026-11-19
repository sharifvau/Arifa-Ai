import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Visual states. Only five expressions are drawn; success/error reuse
/// happy/sad with different body motion.
enum AvatarMood { happy, listening, speaking, thinking, success, error }

/// A hand-drawn, fully animated 2D ARIFA avatar. No image assets, no Rive
/// file and no 3D engine needed — she is painted every frame.
class ArifaAvatar extends StatefulWidget {
  const ArifaAvatar({
    super.key,
    required this.mood,
    this.caption,
    this.scale = 1,
  });

  final AvatarMood mood;
  final String? caption;
  final double scale;

  @override
  State<ArifaAvatar> createState() => _ArifaAvatarState();
}

class _ArifaAvatarState extends State<ArifaAvatar>
    with TickerProviderStateMixin {
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  late final AnimationController _talk = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..repeat(reverse: true);

  Timer? _blinkTimer;
  bool _blinking = false;

  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted ||
          widget.mood == AvatarMood.speaking ||
          widget.mood == AvatarMood.thinking) {
        return;
      }
      setState(() => _blinking = true);
      Timer(const Duration(milliseconds: 130), () {
        if (mounted) setState(() => _blinking = false);
      });
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _life.dispose();
    _talk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_life, _talk]),
      builder: (context, _) {
        final t = _life.value;
        final wave = math.sin(t * math.pi * 2);
        final talk = widget.mood == AvatarMood.speaking
            ? math.sin(_talk.value * math.pi * 2)
            : 0.0;
        final jump = widget.mood == AvatarMood.success
            ? math.sin(_talk.value * math.pi).abs()
            : 0.0;
        final lean = widget.mood == AvatarMood.listening ? 1.05 : 1.0;
        final sway = switch (widget.mood) {
          AvatarMood.thinking => -0.045,
          AvatarMood.error => 0.02,
          AvatarMood.listening => 0.0,
          _ => 0.014 * wave,
        };
        final scale =
            widget.scale * lean * (1 + 0.012 * wave + 0.045 * jump);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.translate(
              offset: Offset(0, -12 * jump),
              child: Transform.rotate(
                angle: sway,
                child: Transform.scale(
                  scale: scale,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: child,
                    ),
                    child: CustomPaint(
                      key: ValueKey(widget.mood),
                      painter: _AvatarPainter(
                        mood: widget.mood,
                        blink: _blinking,
                        talk: talk,
                        time: t,
                      ),
                      child: const SizedBox(width: 300, height: 360),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.caption != null) ...[
              const SizedBox(height: 2),
              Container(
                constraints: const BoxConstraints(maxWidth: 300),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xB306182B),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.cyanAccent.withOpacity(0.45),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.cyan.withOpacity(0.18),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Text(
                  widget.caption!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

enum _Face { happy, listening, speaking, thinking, sad }

class _AvatarPainter extends CustomPainter {
  _AvatarPainter({
    required this.mood,
    required this.blink,
    required this.talk,
    required this.time,
  });

  final AvatarMood mood;
  final bool blink;
  final double talk;
  final double time;

  _Face get face => switch (mood) {
        AvatarMood.happy => _Face.happy,
        AvatarMood.listening => _Face.listening,
        AvatarMood.speaking => _Face.speaking,
        AvatarMood.thinking => _Face.thinking,
        AvatarMood.success => _Face.happy,
        AvatarMood.error => _Face.sad,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final faceCy = h * 0.34;
    final rx = w * 0.255;
    final ry = h * 0.185;
    final t = time * math.pi * 2;
    final currentFace = face;

    // --- aura -------------------------------------------------------------
    final aura = Paint()
      ..color = Colors.cyan.withOpacity(
        mood == AvatarMood.speaking || mood == AvatarMood.listening
            ? 0.20
            : 0.10,
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawCircle(
      Offset(cx, h * 0.50),
      w * 0.42,
      aura,
    );

    // --- hair behind head --------------------------------------------------
    final hair = Paint()..color = const Color(0xFF0B1024);
    final hairShine = Paint()..color = const Color(0xFF172B4D);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, faceCy + h * 0.01),
        width: rx * 2.5,
        height: ry * 2.85,
      ),
      hair,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - rx * 0.45, faceCy + ry * 0.30),
        width: rx * 0.55,
        height: ry * 1.9,
      ),
      hairShine,
    );

    // --- dress / body ------------------------------------------------------
    final dressGradient = LinearGradient(
      colors: [Color(0xFF0B4C7A), Color(0xFF06213B), Color(0xFF0A2D55)],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );
    final dress = Paint()..shader = dressGradient.createShader(
      Rect.fromLTWH(cx - w * 0.34, h * 0.58, w * 0.68, h * 0.42),
    );
    final dressPath = Path()
      ..moveTo(cx - w * 0.12, h * 0.56)
      ..lineTo(cx + w * 0.12, h * 0.56)
      ..quadraticBezierTo(cx + w * 0.34, h * 0.70, cx + w * 0.38, h)
      ..lineTo(cx - w * 0.38, h)
      ..quadraticBezierTo(cx - w * 0.34, h * 0.70, cx - w * 0.12, h * 0.56)
      ..close();
    canvas.drawPath(dressPath, dress);

    final edge = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(cx - w * 0.10, h * 0.58),
      Offset(cx - w * 0.33, h * 0.97),
      edge,
    );
    canvas.drawLine(
      Offset(cx + w * 0.10, h * 0.58),
      Offset(cx + w * 0.33, h * 0.97),
      edge,
    );

    // --- neck --------------------------------------------------------------
    final skin = Paint()..color = const Color(0xFFF3C3A2);
    final skinShade = Paint()..color = const Color(0xFFDDA583);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, faceCy + ry * 1.05),
          width: rx * 0.42,
          height: ry * 0.62,
        ),
        const Radius.circular(10),
      ),
      skinShade,
    );

    // --- ears --------------------------------------------------------------
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - rx * 1.01, faceCy + ry * 0.12),
        width: rx * 0.22,
        height: ry * 0.42,
      ),
      skin,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + rx * 1.01, faceCy + ry * 0.12),
        width: rx * 0.22,
        height: ry * 0.42,
      ),
      skin,
    );

    // --- face --------------------------------------------------------------
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, faceCy), width: rx * 2, height: ry * 2),
      skin,
    );

    // --- front hair with slow sway ----------------------------------------
    final sway = math.sin(t) * rx * 0.035;
    final bang = Path()
      ..moveTo(cx - rx, faceCy - ry * 0.35)
      ..quadraticBezierTo(
        cx - rx * 0.55,
        faceCy - ry * 1.35,
        cx + rx * 0.10,
        faceCy - ry * 1.05,
      )
      ..quadraticBezierTo(
        cx + rx * 0.85,
        faceCy - ry * 0.95,
        cx + rx,
        faceCy - ry * 0.20,
      )
      ..quadraticBezierTo(
        cx + rx * 0.45,
        faceCy - ry * 0.72,
        cx - rx * 0.10,
        faceCy - ry * 0.54,
      )
      ..quadraticBezierTo(
        cx - rx * 0.70,
        faceCy - ry * 0.38,
        cx - rx,
        faceCy - ry * 0.35,
      )
      ..close();
    canvas.drawPath(bang, hair);

    final leftLock = Path()
      ..moveTo(cx - rx * 0.92, faceCy - ry * 0.25)
      ..quadraticBezierTo(
        cx - rx * 1.22 + sway,
        faceCy + ry * 0.75,
        cx - rx * 0.80 + sway,
        faceCy + ry * 1.55,
      )
      ..quadraticBezierTo(
        cx - rx * 0.60,
        faceCy + ry * 0.80,
        cx - rx * 0.72,
        faceCy - ry * 0.10,
      )
      ..close();
    final rightLock = Path()
      ..moveTo(cx + rx * 0.92, faceCy - ry * 0.25)
      ..quadraticBezierTo(
        cx + rx * 1.22 - sway,
        faceCy + ry * 0.75,
        cx + rx * 0.80 - sway,
        faceCy + ry * 1.55,
      )
      ..quadraticBezierTo(
        cx + rx * 0.60,
        faceCy + ry * 0.80,
        cx + rx * 0.72,
        faceCy - ry * 0.10,
      )
      ..close();
    canvas.drawPath(leftLock, hair);
    canvas.drawPath(rightLock, hair);

    // --- eyes --------------------------------------------------------------
    final eyeY = faceCy + ry * 0.02;
    final eyeDx = rx * 0.44;
    final eyeW = rx * 0.28;
    final eyeH = ry * 0.20;
    final lookX = currentFace == _Face.thinking
        ? rx * 0.04
        : math.sin(t * 0.7) * rx * 0.035;
    final lookY = currentFace == _Face.thinking ? -ry * 0.05 : 0.0;

    final white = Paint()..color = Colors.white;
    final pupil = Paint()..color = const Color(0xFF3B2418);
    final shine = Paint()..color = Colors.white;

    if (blink && currentFace != _Face.thinking) {
      final lid = Paint()
        ..color = const Color(0xFF8E5B45)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      for (final dx in [-eyeDx, eyeDx]) {
        canvas.drawLine(
          Offset(cx + dx - eyeW * 0.5, eyeY),
          Offset(cx + dx + eyeW * 0.5, eyeY),
          lid,
        );
      }
    } else {
      for (final dx in [-eyeDx, eyeDx]) {
        final c = Offset(cx + dx, eyeY);
        canvas.drawOval(
          Rect.fromCenter(center: c, width: eyeW, height: eyeH),
          white,
        );
        final p = c + Offset(lookX, lookY);
        canvas.drawCircle(p, eyeH * 0.46, pupil);
        canvas.drawCircle(
          p + Offset(-eyeH * 0.14, -eyeH * 0.16),
          eyeH * (mood == AvatarMood.listening ? 0.20 : 0.14),
          shine,
        );
      }
    }

    // --- brows -------------------------------------------------------------
    final brow = Paint()
      ..color = const Color(0xFF3A2318)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (final dx in [-eyeDx, eyeDx]) {
      final y = eyeY - eyeH * 1.15;
      final tilt = switch (currentFace) {
        _Face.thinking => (dx > 0 ? -ry * 0.09 : ry * 0.04),
        _Face.sad => (dx > 0 ? ry * 0.07 : -ry * 0.07),
        _ => 0.0,
      };
      canvas.drawLine(
        Offset(cx + dx - eyeW * 0.48, y + tilt),
        Offset(cx + dx + eyeW * 0.48, y - tilt),
        brow,
      );
    }

    // --- nose + cheeks -----------------------------------------------------
    final line = Paint()
      ..color = const Color(0xFFC98F70)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx, faceCy + ry * 0.22),
      Offset(cx - rx * 0.03, faceCy + ry * 0.34),
      line,
    );
    final blush = Paint()..color = Colors.pinkAccent.withOpacity(0.16);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - rx * 0.62, faceCy + ry * 0.38),
        width: rx * 0.30,
        height: ry * 0.12,
      ),
      blush,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + rx * 0.62, faceCy + ry * 0.38),
        width: rx * 0.30,
        height: ry * 0.12,
      ),
      blush,
    );

    // --- mouth -------------------------------------------------------------
    final mouthY = faceCy + ry * 0.58;
    final mouth = Paint()
      ..color = const Color(0xFF8E3550)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;

    if (currentFace == _Face.speaking) {
      final open = h * (0.018 + 0.016 * talk.abs());
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, mouthY), width: rx * 0.22, height: open),
        Paint()..color = const Color(0xFF7A2D45),
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, mouthY + open * 0.35),
          width: rx * 0.11,
          height: open * 0.45,
        ),
        Paint()..color = const Color(0xFFF49AB0),
      );
    } else if (currentFace == _Face.sad) {
      final p = Path()
        ..moveTo(cx - rx * 0.16, mouthY + ry * 0.06)
        ..quadraticBezierTo(cx, mouthY - ry * 0.10, cx + rx * 0.16, mouthY + ry * 0.06);
      canvas.drawPath(p, mouth);
    } else if (currentFace == _Face.thinking) {
      canvas.drawLine(
        Offset(cx - rx * 0.05, mouthY),
        Offset(cx + rx * 0.05, mouthY),
        mouth,
      );
    } else {
      final p = Path()
        ..moveTo(cx - rx * 0.18, mouthY - ry * 0.03)
        ..quadraticBezierTo(cx, mouthY + ry * 0.16, cx + rx * 0.18, mouthY - ry * 0.03);
      canvas.drawPath(p, mouth);
    }

    // --- glowing arc-reactor necklace --------------------------------------
    final reactorC = Offset(cx, h * 0.66);
    final glow = Paint()
      ..color = Colors.cyan.withOpacity(
        mood == AvatarMood.speaking ? 0.35 : 0.20,
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(reactorC, w * 0.075, glow);
    canvas.drawCircle(
      reactorC,
      w * 0.052,
      Paint()
        ..color = const Color(0xFF06213B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      reactorC,
      w * 0.034,
      Paint()..color = Colors.cyanAccent.withOpacity(0.85),
    );
    canvas.drawCircle(
      reactorC,
      w * 0.018,
      Paint()..color = Colors.white,
    );

    // --- arms / hands -------------------------------------------------------
    final handPaint = Paint()..color = const Color(0xFFF3C3A2);
    final sleeve = Paint()..color = const Color(0xFF0B4C7A);
    final handY = h * 0.80;

    if (mood == AvatarMood.success) {
      final clap = w * (0.055 + 0.025 * talk.abs());
      for (final s in [-1.0, 1.0]) {
        final hc = Offset(cx + s * clap, h * 0.72);
        canvas.drawCircle(hc, w * 0.045, handPaint);
        canvas.drawCircle(
          hc,
          w * 0.052,
          Paint()
            ..color = Colors.cyanAccent.withOpacity(0.18)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }
    } else if (currentFace == _Face.thinking) {
      final hc = Offset(cx + rx * 0.72, faceCy + ry * 0.95);
      canvas.drawCircle(hc, w * 0.040, handPaint);
      final finger = Paint()
        ..color = const Color(0xFFF3C3A2)
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        hc + const Offset(-6, -10),
        Offset(cx + rx * 0.20, faceCy + ry * 0.78),
        finger,
      );
    } else if (mood == AvatarMood.listening) {
      final hc = Offset(cx + rx * 1.05, faceCy + ry * 0.10);
      canvas.drawCircle(hc, w * 0.042, handPaint);
      canvas.drawCircle(
        hc,
        w * 0.056,
        Paint()
          ..color = Colors.cyanAccent.withOpacity(0.15)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    } else {
      final move = currentFace == _Face.speaking ? h * 0.025 * talk : 0.0;
      for (final s in [-1.0, 1.0]) {
        final hc = Offset(cx + s * w * 0.27, handY + s * move);
        canvas.drawOval(
          Rect.fromCenter(center: hc, width: w * 0.085, height: h * 0.055),
          sleeve,
        );
        canvas.drawCircle(hc, w * 0.035, handPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AvatarPainter oldDelegate) => true;
}

