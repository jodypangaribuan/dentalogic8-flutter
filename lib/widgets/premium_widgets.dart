import 'package:flutter/material.dart';

import '../core/theme.dart';

class PremiumLoadingSpinner extends StatefulWidget {
  final double size;
  final Color? color;
  final String? message;

  const PremiumLoadingSpinner({
    super.key,
    this.size = 50.0,
    this.color,
    this.message,
  });

  @override
  State<PremiumLoadingSpinner> createState() => _PremiumLoadingSpinnerState();
}

class _PremiumLoadingSpinnerState extends State<PremiumLoadingSpinner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = widget.color ?? AppColors.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Stack(
                children: [
                  // Outer ring
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      value: null,
                      strokeWidth: 3,
                      backgroundColor: themeColor.withValues(alpha: 0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(themeColor),
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  // Inner pulsing dot
                  Center(
                    child: FadeTransition(
                      opacity: Tween<double>(begin: 0.5, end: 1.0).animate(
                        CurvedAnimation(
                          parent: _controller,
                          curve: Curves.easeInOut,
                        ),
                      ),
                      child: Container(
                        width: widget.size * 0.3,
                        height: widget.size * 0.3,
                        decoration: BoxDecoration(
                          color: themeColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: themeColor.withValues(alpha: 0.4),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (widget.message != null) ...[
          const SizedBox(height: 16),
          Text(
            widget.message!,
            style: AppTextStyles.body.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class PremiumOverlayLoader extends StatelessWidget {
  final String? message;

  const PremiumOverlayLoader({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.3),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: PremiumLoadingSpinner(message: message),
        ),
      ),
    );
  }
}
