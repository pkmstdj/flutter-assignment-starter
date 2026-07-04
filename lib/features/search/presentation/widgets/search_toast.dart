import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../../theme/app_assets.dart';
import '../../../../theme/app_theme.dart';
import '../layout/search_layout_spec.dart';

class SearchToast extends StatelessWidget {
  const SearchToast({required this.layout, required this.message, super.key});

  final SearchLayoutSpec layout;
  final String message;

  @override
  Widget build(BuildContext context) {
    // Figma의 토스트는 반투명 glass 위에 blur를 깔고 보더/글로우 그림자를 얹는다.
    // ClipRRect로 라운드를 자른 뒤 BackdropFilter로 뒤 배경을 흐린다.
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: SearchLayoutSpec.toastHeight,
          padding: EdgeInsets.symmetric(horizontal: 16 * layout.horizontalScale),
          decoration: BoxDecoration(
            color: AppDerivedColors.searchToastBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppDerivedColors.searchToastBorder),
            boxShadow: const [
              BoxShadow(
                color: AppDerivedColors.searchToastGlow,
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              const _ToastHeartCheck(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: AppTypography.searchToast,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 채워진 하트 위에 흰색 체크를 합성한 20x20 아이콘.
class _ToastHeartCheck extends StatelessWidget {
  const _ToastHeartCheck();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('search-toast-favorite-icon'),
      width: 20,
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AppAssetSlotIcon(
            assetPath: AppAssets.favoriteHeart,
            slotWidth: 20,
            slotHeight: 20,
            assetWidth: 20,
            assetHeight: 20,
            color: AppColors.mainAndAccent.up_f93f62,
          ),
          AppAssetSlotIcon(
            key: const Key('search-toast-check-icon'),
            assetPath: AppAssets.toastCheck,
            slotWidth: 20,
            slotHeight: 20,
            assetWidth: AppAssetSizes.toastCheck.width,
            assetHeight: AppAssetSizes.toastCheck.height,
            color: AppColors.grays.white,
          ),
        ],
      ),
    );
  }
}
