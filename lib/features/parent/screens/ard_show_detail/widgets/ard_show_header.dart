import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Collapsing sliver app bar showing the ARD show's cover image and title.
class ArdShowHeader extends StatelessWidget {
  const ArdShowHeader({required this.show, super.key});
  final ArdProgramSet show;

  @override
  Widget build(BuildContext context) {
    final imageUrl = ardImageUrl(show.imageUrl, width: 600);
    final subtitle = show.organizationName ?? show.publisher;

    return SliverAppBar(
      backgroundColor: AppColors.parentBackground,
      expandedHeight: 200,
      pinned: true,
      foregroundColor: Colors.white,
      iconTheme: const IconThemeData(
        color: Colors.white,
        shadows: [Shadow(blurRadius: 8)],
      ),
      flexibleSpace: FlexibleSpaceBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              show.title,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: Colors.white,
                shadows: [
                  Shadow(blurRadius: 12),
                  Shadow(blurRadius: 4),
                ],
              ),
            ),
            if (subtitle != null)
              Text(
                '$subtitle · ${show.numberOfElements} Folgen',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                  shadows: [
                    Shadow(blurRadius: 12),
                    Shadow(blurRadius: 4),
                  ],
                ),
              ),
          ],
        ),
        background:
            imageUrl != null
                ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.3, 0.65, 1.0],
                          colors: [
                            Colors.black.withAlpha(60),
                            Colors.black.withAlpha(20),
                            Colors.black.withAlpha(200),
                            Colors.black,
                          ],
                        ),
                      ),
                    ),
                  ],
                )
                : null,
      ),
    );
  }
}
