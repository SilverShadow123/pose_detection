
import 'package:flutter/material.dart';

class ConfidenceBar extends StatelessWidget {
  const ConfidenceBar({
    super.key,
    required this.confidence,
  });

  final double confidence;

  @override
  Widget build(BuildContext context) {
    final displayConfidence = (confidence * 100).toStringAsFixed(1);
    Color barColor;

    // Color based on confidence level
    if (confidence > 0.8) {
      barColor = Colors.green;
    } else if (confidence > 0.6) {
      barColor = Colors.amber;
    } else {
      barColor = Colors.redAccent;
    }

    return Row(
      children: [
        const Text(
          'Confidence: ',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(width: 4),
        Container(
          width: 100,
          height: 6,
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(3),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: confidence.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$displayConfidence%',
          style: TextStyle(color: barColor, fontSize: 12),
        ),
      ],
    );
  }
}