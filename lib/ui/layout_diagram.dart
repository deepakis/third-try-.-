import 'package:flutter/material.dart';

import '../obs/obs_models.dart';

/// Miniature wireframe of what a shot looks like: a talking head filling the
/// frame, a tighter digital zoom, a strip down one side, or a corner box.
///
/// Shared by the camera tile (as a placeholder before OBS sends a frame) and the
/// shot picker (so a shot can be recognised before it exists).
class LayoutDiagram extends StatelessWidget {
  const LayoutDiagram({
    super.key,
    required this.layout,
    required this.color,
    this.cornerRadius = 14,
    this.strokeWidth = 2,
  });

  final CameraLayout layout;
  final Color color;
  final double cornerRadius;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: LayoutDiagramPainter(
        layout: layout,
        color: color,
        cornerRadius: cornerRadius,
        strokeWidth: strokeWidth,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class LayoutDiagramPainter extends CustomPainter {
  const LayoutDiagramPainter({
    required this.layout,
    required this.color,
    this.cornerRadius = 14,
    this.strokeWidth = 2,
  });

  final CameraLayout layout;
  final Color color;
  final double cornerRadius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color.withValues(alpha: 0.45);
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.16);

    final frame = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(cornerRadius),
    );
    canvas.drawRRect(frame, stroke);

    final inset = size.shortestSide * 0.1;
    if (layout == CameraLayout.fullBleed) {
      _drawPerson(
        canvas,
        center: Offset(size.width / 2, size.height / 2 + inset * 0.25),
        height: size.height * 0.62,
        stroke: stroke,
        fill: fill,
      );
      return;
    }

    if (layout == CameraLayout.zoomedBleed) {
      // The same shot, tighter: a bigger subject with the corner ticks that
      // read as "zoomed in".
      _drawPerson(
        canvas,
        center: Offset(size.width / 2, size.height / 2 + inset * 0.4),
        height: size.height * 0.95,
        stroke: stroke,
        fill: fill,
      );
      final tick = Paint()
        ..color = color.withValues(alpha: 0.6)
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      const length = 10.0;
      final step = inset * 1.1;
      for (final corner in const [
        Offset(-1, -1),
        Offset(1, -1),
        Offset(-1, 1),
        Offset(1, 1),
      ]) {
        final x = size.width / 2 + corner.dx * step;
        final y = size.height / 2 + corner.dy * step;
        canvas.drawLine(
          Offset(x, y),
          Offset(x - corner.dx * length, y),
          tick,
        );
        canvas.drawLine(
          Offset(x, y),
          Offset(x, y - corner.dy * length),
          tick,
        );
      }
      return;
    }

    // A talking head placed where the shot actually puts it: filling one side,
    // or boxed into a corner.
    if (layout == CameraLayout.sideBleed) {
      final stripWidth = size.width * 0.34;
      final strip = RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width - stripWidth - inset, inset, stripWidth, size.height - inset * 2),
        const Radius.circular(10),
      );
      canvas.drawRRect(strip, fill);
      canvas.drawRRect(strip, stroke);
      _drawPerson(
        canvas,
        center: strip.center,
        height: strip.height * 0.72,
        stroke: stroke,
        fill: fill,
      );
      return;
    }

    final boxWidth = size.width * 0.28;
    final boxHeight = size.height * 0.32;
    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width - boxWidth - inset,
        layout == CameraLayout.topPiP
            ? inset
            : size.height - boxHeight - inset,
        boxWidth,
        boxHeight,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(box, fill);
    canvas.drawRRect(box, stroke);
    _drawPerson(
      canvas,
      center: box.center,
      height: box.height * 0.74,
      stroke: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: 0.5)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
      fill: fill,
    );
  }

  void _drawPerson(
    Canvas canvas, {
    required Offset center,
    required double height,
    required Paint stroke,
    required Paint fill,
  }) {
    final headRadius = height * 0.22;
    final head = Offset(center.dx, center.dy - height * 0.18);
    canvas.drawCircle(head, headRadius, fill);
    canvas.drawCircle(head, headRadius, stroke);

    final shoulderWidth = height * 0.86;
    final shoulderRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy + height * 0.30),
      width: shoulderWidth,
      height: height * 0.46,
    );
    final shoulders = RRect.fromRectAndCorners(
      shoulderRect,
      topLeft: Radius.circular(height * 0.26),
      topRight: Radius.circular(height * 0.26),
      bottomLeft: Radius.circular(height * 0.06),
      bottomRight: Radius.circular(height * 0.06),
    );
    canvas.drawRRect(shoulders, fill);
    canvas.drawRRect(shoulders, stroke);
  }

  @override
  bool shouldRepaint(LayoutDiagramPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.color != color ||
      oldDelegate.cornerRadius != cornerRadius ||
      oldDelegate.strokeWidth != strokeWidth;
}
