import 'package:flutter/material.dart';
import 'package:lauschi/core/providers/provider_type.dart';

/// Small provider icon badge for parent-facing content views.
///
/// Shows a provider icon so parents can see which service content
/// comes from at a glance. Not shown in kid UI.
class ProviderBadge extends StatelessWidget {
  const ProviderBadge({required this.provider, super.key});

  final ProviderType provider;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: provider.displayName,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: provider.color.withAlpha(30),
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        child: Icon(provider.icon, size: 14, color: provider.color),
      ),
    );
  }
}
