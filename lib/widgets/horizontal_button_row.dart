import 'package:flutter/material.dart';

class HorizontalButtonRow extends StatelessWidget {
  final List<Widget> buttons;
  final double spacing;
  final double height;

  const HorizontalButtonRow({
    super.key,
    required this.buttons,
    this.spacing = 6,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: buttons.length,
        separatorBuilder: (_, __) => SizedBox(width: spacing),
        itemBuilder: (_, i) => buttons[i],
      ),
    );
  }
}
