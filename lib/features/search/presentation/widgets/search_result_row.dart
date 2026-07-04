import 'package:flutter/material.dart';

import '../../../watchlist/domain/models/watchlist_models.dart';
import '../../../../theme/app_assets.dart';
import '../../../../theme/app_theme.dart';
import '../../domain/services/search_text_utils.dart';
import '../layout/search_layout_spec.dart';
import 'search_action_bar.dart';

class SearchResultRow extends StatelessWidget {
  const SearchResultRow({
    required this.item,
    required this.query,
    required this.isSelected,
    required this.layout,
    required this.onTap,
    required this.onHeartTap,
    required this.onActionTap,
    super.key,
  });

  final StockSearchItem item;
  final String query;
  final bool isSelected;
  final SearchLayoutSpec layout;
  final VoidCallback onTap;
  final VoidCallback onHeartTap;
  final ValueChanged<String> onActionTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('search-result-${item.id}'),
        onTap: onTap,
        child: Column(
          children: [
            SizedBox(
              key: Key('search-result-row-${item.id}'),
              height: SearchLayoutSpec.resultRowHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.horizontalPadding,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _SearchTextColumn(item: item, query: query),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      key: Key('search-heart-${item.id}'),
                      onTap: onHeartTap,
                      behavior: HitTestBehavior.opaque,
                      child: AppAssetSlotIcon(
                        key: Key('search-heart-icon-${item.id}'),
                        assetPath: AppAssets.favoriteHeart,
                        // Figma 하트 슬롯은 20x20, 에셋 자체는 16x13.
                        slotWidth: 20,
                        slotHeight: 20,
                        assetWidth: AppAssetSizes.favoriteHeart.width,
                        assetHeight: AppAssetSizes.favoriteHeart.height,
                        color: item.isFavorite
                            ? AppColors.mainAndAccent.up_f93f62
                            : AppColors.darkTheme.c_424242,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (isSelected) ...[
              const SizedBox(height: SearchLayoutSpec.expandedActionTopGap),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.horizontalPadding,
                ),
                child: KeyedSubtree(
                  key: Key('search-actions-${item.id}'),
                  // 뉴스/종목토론 두 액션 버튼은 SearchActionBar가 Figma 기준
                  // (아이콘+라벨, 구분선, 보더/그림자)으로 구성한다.
                  child: SearchActionBar(
                    layout: layout,
                    onActionTap: onActionTap,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchTextColumn extends StatelessWidget {
  const _SearchTextColumn({required this.item, required this.query});

  final StockSearchItem item;
  final String query;

  @override
  Widget build(BuildContext context) {
    // 제목/서브텍스트 2줄을 RichText(Text.rich)로 구성하고, 검색어와 일치하는
    // 구간만 point 색상으로 강조한다. 강조 규칙은 splitSearchTextParts로 통일.
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          _highlightedSpan(
            text: item.name,
            baseStyle: AppTypography.searchName,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text.rich(
          _highlightedSpan(
            text: buildSearchSubtitle(item),
            baseStyle: AppTypography.searchMeta,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  TextSpan _highlightedSpan({
    required String text,
    required TextStyle baseStyle,
  }) {
    final parts = splitSearchTextParts(text, query);
    return TextSpan(
      style: baseStyle,
      children: [
        for (final part in parts)
          TextSpan(
            text: part.text,
            style: part.isHighlighted
                ? baseStyle.copyWith(
                    color: AppColors.mainAndAccent.point_b980ff,
                  )
                : null,
          ),
      ],
    );
  }
}
