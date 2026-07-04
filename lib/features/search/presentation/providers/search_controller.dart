import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../watchlist/data/providers/watchlist_repository_provider.dart';
import '../../../watchlist/domain/models/watchlist_models.dart';
import '../../../watchlist/domain/repositories/watchlist_repository.dart';
import '../../../watchlist/presentation/providers/favorite_ids_controller.dart';

final searchControllerProvider =
    NotifierProvider<SearchController, SearchUiState>(SearchController.new);

class SearchController extends Notifier<SearchUiState> {
  WatchlistRepository get _repository => ref.read(watchlistRepositoryProvider);

  Timer? _toastTimer;
  int _requestSequence = 0;

  @override
  SearchUiState build() {
    ref.onDispose(() => _toastTimer?.cancel());
    // 즐겨찾기 상태(favoriteIdsControllerProvider)가 바뀌면 현재 검색 결과의
    // isFavorite도 함께 다시 매핑한다. 관심 화면에서 추가/삭제해도 검색 결과의
    // 하트가 즉시 동기화된다.
    ref.listen(favoriteIdsControllerProvider, (previous, next) {
      _applyFavoriteIds(next.valueOrNull);
    });
    return const SearchUiState();
  }

  Future<void> setQuery(String query) async {
    _requestSequence += 1;
    final currentRequestId = _requestSequence;
    final trimmedQuery = query.trim();

    if (trimmedQuery.isEmpty) {
      _toastTimer?.cancel();
      state = state.copyWith(
        query: query,
        results: const AsyncData(<StockSearchItem>[]),
        selectedItemId: null,
        toast: null,
      );
      return;
    }

    final existingResults = state.results;
    final loadingResults = existingResults.hasValue
        ? const AsyncLoading<List<StockSearchItem>>().copyWithPrevious(
            existingResults,
          )
        : const AsyncLoading<List<StockSearchItem>>();

    state = state.copyWith(
      query: query,
      results: loadingResults,
      selectedItemId: null,
      toast: null,
    );

    final result = await AsyncValue.guard(
      () => _repository.searchStocks(query: trimmedQuery),
    );
    if (currentRequestId != _requestSequence) {
      return;
    }

    // 첫 검색 결과에도 현재 즐겨찾기 상태를 즉시 반영한다.
    final favoriteIds = ref.read(favoriteIdsControllerProvider).valueOrNull;
    state = state.copyWith(
      results: _syncResultsWithFavorites(result, favoriteIds),
      selectedItemId: null,
    );
  }

  void clearQuery() {
    _requestSequence += 1;
    _toastTimer?.cancel();
    state = state.copyWith(
      query: '',
      results: const AsyncData(<StockSearchItem>[]),
      selectedItemId: null,
      toast: null,
    );
  }

  void setFocused(bool isFocused) {
    if (state.isFocused == isFocused) {
      return;
    }
    state = state.copyWith(isFocused: isFocused);
  }

  void toggleSelection(StockSearchItem item) {
    state = state.copyWith(
      selectedItemId: state.selectedItemId == item.id ? null : item.id,
    );
  }

  void clearSelection() {
    if (state.selectedItemId == null) {
      return;
    }
    state = state.copyWith(selectedItemId: null);
  }

  Future<bool> toggleFavorite(StockSearchItem item) async {
    final isAdded = await ref
        .read(favoriteIdsControllerProvider.notifier)
        .toggle(item.id);

    // toggle 직후 최신 favorite 상태를 검색 결과에 다시 반영한다.
    // (build()의 listener도 반응하지만, 즉시 일관된 상태를 보장하기 위해
    // 여기서도 명시적으로 매핑한다.)
    _applyFavoriteIds(ref.read(favoriteIdsControllerProvider).valueOrNull);

    // 추가 시 토스트 노출, 제거 시 토스트 닫기.
    if (isAdded) {
      _showToast(const SearchToastData(message: '관심그룹에 추가되었습니다.'));
    } else {
      dismissToast();
    }

    return isAdded;
  }

  void dismissToast() {
    _toastTimer?.cancel();
    if (state.toast == null) {
      return;
    }
    state = state.copyWith(toast: null);
  }

  void _showToast(SearchToastData toast) {
    _toastTimer?.cancel();
    state = state.copyWith(toast: toast);
    _toastTimer = Timer(const Duration(seconds: 2), dismissToast);
  }

  void _applyFavoriteIds(Set<String>? favoriteIds) {
    if (favoriteIds == null) {
      return;
    }

    final syncedResults = _syncResultsWithFavorites(state.results, favoriteIds);
    if (identical(syncedResults, state.results)) {
      return;
    }

    // 재매핑으로 selected item이 사라졌다면 선택 상태도 정리한다.
    final selectedItemId = state.selectedItemId;
    final selectionStillExists =
        selectedItemId != null &&
        (syncedResults.valueOrNull ?? const <StockSearchItem>[]).any(
          (item) => item.id == selectedItemId,
        );

    state = state.copyWith(
      results: syncedResults,
      selectedItemId: selectionStillExists ? selectedItemId : null,
    );
  }

  /// results의 각 항목 isFavorite를 favoriteIds 기준으로 다시 매핑한다.
  /// 값이 없거나 실제 변화가 없으면 원본을 그대로 반환해 불필요한 rebuild를 막는다.
  AsyncValue<List<StockSearchItem>> _syncResultsWithFavorites(
    AsyncValue<List<StockSearchItem>> results,
    Set<String>? favoriteIds,
  ) {
    if (favoriteIds == null || !results.hasValue) {
      return results;
    }

    final items = results.requireValue;
    var changed = false;
    final mapped = <StockSearchItem>[];
    for (final item in items) {
      final shouldBeFavorite = favoriteIds.contains(item.id);
      if (item.isFavorite == shouldBeFavorite) {
        mapped.add(item);
      } else {
        mapped.add(item.copyWith(isFavorite: shouldBeFavorite));
        changed = true;
      }
    }

    return changed ? AsyncData(mapped) : results;
  }
}

@immutable
class SearchUiState {
  const SearchUiState({
    this.query = '',
    this.results = const AsyncData(<StockSearchItem>[]),
    this.selectedItemId,
    this.isFocused = false,
    this.toast,
  });

  final String query;
  final AsyncValue<List<StockSearchItem>> results;
  final String? selectedItemId;
  final bool isFocused;
  final SearchToastData? toast;

  SearchUiState copyWith({
    String? query,
    AsyncValue<List<StockSearchItem>>? results,
    Object? selectedItemId = _sentinel,
    bool? isFocused,
    Object? toast = _sentinel,
  }) {
    return SearchUiState(
      query: query ?? this.query,
      results: results ?? this.results,
      selectedItemId: selectedItemId == _sentinel
          ? this.selectedItemId
          : selectedItemId as String?,
      isFocused: isFocused ?? this.isFocused,
      toast: toast == _sentinel ? this.toast : toast as SearchToastData?,
    );
  }
}

@immutable
class SearchToastData {
  const SearchToastData({required this.message});

  final String message;
}

const _sentinel = Object();
