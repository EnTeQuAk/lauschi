import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Manage existing cards: view collection, delete cards.
class ManageCardsScreen extends ConsumerWidget {
  const ManageCardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(allCardsProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Karten verwalten'),
        actions: [
          IconButton(
            onPressed: () => context.push(AppRoutes.parentAddCard),
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Hörspiel hinzufügen',
          ),
        ],
      ),
      body: cardsAsync.when(
        data: (cards) => cards.isEmpty
            ? _EmptyState(
                onAdd: () => context.push(AppRoutes.parentAddCard),
              )
            : _CardList(cards: cards),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(
          child: Text('Fehler beim Laden der Karten.'),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.library_music_rounded,
            size: 48,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Noch keine Karten',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Hörspiel hinzufügen'),
          ),
        ],
      ),
    );
  }
}

class _CardList extends ConsumerWidget {
  const _CardList({required this.cards});
  final List<db.Card> cards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: cards.length,
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      itemBuilder: (context, index) {
        final card = cards[index];
        return _CardTile(
          card: card,
          onDelete: () => _confirmDelete(context, ref, card),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, db.Card card) {
    unawaited(showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Karte entfernen?'),
        content: Text(
          '„${card.customTitle ?? card.title}" wird aus der '
          'Sammlung entfernt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              unawaited(ref.read(cardRepositoryProvider).delete(card.id));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${card.customTitle ?? card.title} entfernt'),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    ));
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.card,
    required this.onDelete,
  });

  final db.Card card;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 48,
          height: 48,
          child: card.coverUrl != null
              ? CachedNetworkImage(
                  imageUrl: card.coverUrl!,
                  fit: BoxFit.cover,
                )
              : const ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Icon(Icons.music_note_rounded),
                ),
        ),
      ),
      title: Text(
        card.customTitle ?? card.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        card.cardType,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 13,
          color: AppColors.textSecondary,
        ),
      ),
      trailing: IconButton(
        onPressed: onDelete,
        icon: const Icon(Icons.delete_outline_rounded),
        color: AppColors.error,
        tooltip: 'Entfernen',
      ),
      tileColor: AppColors.parentSurface,
    );
  }
}
