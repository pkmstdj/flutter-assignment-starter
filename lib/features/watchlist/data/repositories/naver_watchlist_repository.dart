// ignore_for_file: unused_element, unused_field

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/models/watchlist_models.dart';
import '../../domain/repositories/watchlist_repository.dart';
import '../../domain/services/watchlist_sorting.dart';
import '../clients/naver_domestic_stock_client.dart';
import '../clients/naver_stock_logo_url_resolver.dart';
import '../dtos/naver_stock_dtos.dart';
import 'favorite_ids_local_store.dart';

class NaverWatchlistRepository implements WatchlistRepository {
  NaverWatchlistRepository({
    required Dio dio,
    required FavoriteIdsLocalStore favoriteIdsLocalStore,
    NaverStockDataClient? client,
    NaverStockLogoUrlResolver? logoUrlResolver,
    this.realtimeCacheTtl = const Duration(seconds: 10),
    this.dailyHistoryFetchBatchSize = 4,
    this.maxAvailableDatePages = 25,
  }) : _client = client ?? NaverDomesticStockClient(dio),
       _favoriteIdsLocalStore = favoriteIdsLocalStore,
       _logoUrlResolver = logoUrlResolver ?? const NaverStockLogoUrlResolver();

  static const _historyRowsPerPage = 10;

  final NaverStockDataClient _client;
  final FavoriteIdsLocalStore _favoriteIdsLocalStore;
  final NaverStockLogoUrlResolver _logoUrlResolver;
  final Duration realtimeCacheTtl;
  final int dailyHistoryFetchBatchSize;

  /// 거래일 목록을 만들 때 최대로 조회할 일별 시세 페이지 수.
  /// 실제 종목은 lastPage가 수백(수십 년치)에 달하므로, 날짜 선택 picker에
  /// 필요한 최근 구간만 가져오도록 상한을 둔다(전체를 받으면 앱이 멈춘다).
  final int maxAvailableDatePages;

  final Map<String, NaverChartMetadataDto> _metadataCache = {};
  final Map<String, NaverDailyHistoryPageDto> _dailyHistoryPageCache = {};
  final Map<String, _RealtimeQuoteCacheEntry> _realtimeQuoteCache = {};

  Set<String>? _favoriteIdsCache;
  List<DateTime>? _availableDatesCache;

  @override
  Future<WatchlistSnapshot> fetchWatchlist({DateTime? asOf}) async {
    final symbols = await _favoriteSymbols();
    final metadataBySymbol = await _loadMetadataBatch(symbols);

    // 기본(최신) 로드는 전체 거래일 목록이 필요 없다. 각 종목 page 1의 최신
    // 행 + realtime만으로 스냅샷을 만들어 앱 시작을 빠르게 유지한다.
    // (전체 거래일 목록은 날짜 picker를 열 때 lazy load 한다.)
    if (asOf == null) {
      return _buildLatestSnapshot(symbols, metadataBySymbol);
    }

    // 특정 과거 거래일 요청: 거래일 축을 확보해 asOf를 실제 거래일로 정규화하고
    // 해당 날짜 행으로 스냅샷을 만든다. 과거 날짜는 realtime을 쓰지 않는다.
    final availableDates = await fetchAvailableDates();
    final resolvedAsOf = _resolveAsOf(availableDates, asOf);
    final latestDate = availableDates.isEmpty ? null : availableDates.first;
    final isLatest = latestDate != null && resolvedAsOf == latestDate;

    final realtimeBySymbol = isLatest
        ? await _loadRealtimeQuotes(symbols)
        : const <String, NaverRealtimeQuoteDto>{};

    final items = <WatchlistItem>[];
    for (final symbol in symbols) {
      final metadata = metadataBySymbol[symbol];
      if (metadata == null) {
        continue;
      }

      final historicalEntry = availableDates.isEmpty
          ? await _loadLatestHistoricalEntry(symbol)
          : await _loadHistoricalEntryForDate(
              symbol: symbol,
              availableDates: availableDates,
              asOf: resolvedAsOf,
            );
      if (historicalEntry == null) {
        continue;
      }

      items.add(
        _buildWatchlistItem(
          symbol: symbol,
          metadata: metadata,
          historicalEntry: historicalEntry,
          realtimeQuote: realtimeBySymbol[symbol],
          latestDate: latestDate,
        ),
      );
    }

    return WatchlistSnapshot(
      asOf: resolvedAsOf,
      items: items,
      availableDates: availableDates,
    );
  }

  /// 최신 거래일 스냅샷: 각 종목의 page 1 최신 행 + realtime으로 구성한다.
  Future<WatchlistSnapshot> _buildLatestSnapshot(
    List<String> symbols,
    Map<String, NaverChartMetadataDto> metadataBySymbol,
  ) async {
    final realtimeBySymbol = await _loadRealtimeQuotes(symbols);

    final items = <WatchlistItem>[];
    DateTime? snapshotDate;
    for (final symbol in symbols) {
      final metadata = metadataBySymbol[symbol];
      if (metadata == null) {
        continue;
      }

      final historicalEntry = await _loadLatestHistoricalEntry(symbol);
      if (historicalEntry == null) {
        continue;
      }

      // 종목별 최신 거래일 중 가장 최근 날짜를 스냅샷 기준일로 삼는다.
      final rowDate = normalizeAsOfDate(historicalEntry.row.localDate);
      if (snapshotDate == null || rowDate.isAfter(snapshotDate)) {
        snapshotDate = rowDate;
      }

      items.add(
        _buildWatchlistItem(
          symbol: symbol,
          metadata: metadata,
          historicalEntry: historicalEntry,
          realtimeQuote: realtimeBySymbol[symbol],
          // 자기 자신의 최신 행이므로 isLatest=true가 되어 realtime이 반영된다.
          latestDate: rowDate,
        ),
      );
    }

    return WatchlistSnapshot(
      asOf: snapshotDate ?? normalizeAsOfDate(DateTime.now()),
      items: items,
    );
  }

  @override
  Future<List<DateTime>> fetchAvailableDates() async {
    // 거래일 목록은 종목마다 동일하므로 한 번만 만들어 캐시한다.
    final cached = _availableDatesCache;
    if (cached != null) {
      return List<DateTime>.unmodifiable(cached);
    }

    // 기준 종목 하나만으로 전체 거래일 축을 만든다.
    final referenceSymbol = await _firstFavoriteSymbol();
    if (referenceSymbol == null) {
      _availableDatesCache = const <DateTime>[];
      return const <DateTime>[];
    }

    // page 1을 먼저 읽어 lastPage를 파악한 뒤 나머지를 batch로 병렬 로드한다.
    final firstPage = await _loadDailyHistoryPage(referenceSymbol, 1);
    final dates = <DateTime>[
      for (final row in firstPage.priceInfos) row.localDate,
    ];

    // 실제 종목은 lastPage가 수백에 달하므로 picker에 필요한 최근 구간까지만
    // 가져온다(상한: maxAvailableDatePages).
    final lastPageToFetch = firstPage.lastPage < maxAvailableDatePages
        ? firstPage.lastPage
        : maxAvailableDatePages;

    for (
      var page = 2;
      page <= lastPageToFetch;
      page += dailyHistoryFetchBatchSize
    ) {
      final endPage = (page + dailyHistoryFetchBatchSize - 1)
          .clamp(page, lastPageToFetch);
      final pages = await Future.wait([
        for (var current = page; current <= endPage; current += 1)
          _loadDailyHistoryPage(referenceSymbol, current),
      ]);
      for (final historyPage in pages) {
        for (final row in historyPage.priceInfos) {
          dates.add(row.localDate);
        }
      }
    }

    // 중복 제거 후 최신순(내림차순) 정렬.
    final normalized =
        dates.map(normalizeAsOfDate).toSet().toList(growable: false)
          ..sort((left, right) => right.compareTo(left));
    _availableDatesCache = normalized;
    return List<DateTime>.unmodifiable(normalized);
  }

  @override
  Future<WatchlistDetail> fetchWatchlistDetail({
    required String symbol,
    required MarketType market,
    DateTime? asOf,
  }) async {
    // 상세 패널은 국내 주식만 지원한다.
    if (market != MarketType.domestic) {
      throw ArgumentError.value(
        market,
        'market',
        'NaverWatchlistRepository only supports domestic stocks',
      );
    }

    final availableDates = await fetchAvailableDates();
    final resolvedAsOf = _resolveAsOf(availableDates, asOf);
    final latestDate = availableDates.isEmpty ? null : availableDates.first;
    final isLatest = latestDate != null && resolvedAsOf == latestDate;

    final selectedIndex = _indexOfDate(availableDates, resolvedAsOf);
    if (selectedIndex == null) {
      // 거래일 축을 만들지 못한 예외 상황: 최신 1일 기준으로만 구성한다.
      return _buildLatestDetailFallback(symbol);
    }

    // 선택일을 포함한 직전 30거래일 window(내림차순).
    final windowDates = <DateTime>[];
    for (
      var index = selectedIndex;
      index < availableDates.length && windowDates.length < 30;
      index += 1
    ) {
      windowDates.add(availableDates[index]);
    }

    // window에 필요한 페이지 + 선택일 직전일(전일 종가용) 페이지를 모아
    // 날짜별 row 맵을 만든다. _loadDailyHistoryPage가 캐시하므로 중복 없다.
    final requiredPages = <int>{
      for (final date in windowDates)
        _pageNumberForIndex(_indexOfDate(availableDates, date)!),
    };
    if (selectedIndex + 1 < availableDates.length) {
      requiredPages.add(_pageNumberForIndex(selectedIndex + 1));
    }

    final rowsByDate = <String, NaverHistoricalPriceDto>{};
    for (final page in requiredPages) {
      final historyPage = await _loadDailyHistoryPage(symbol, page);
      for (final row in historyPage.priceInfos) {
        rowsByDate[_dateKey(row.localDate)] = row;
      }
    }

    final selectedRow = rowsByDate[_dateKey(resolvedAsOf)];
    if (selectedRow == null) {
      return _buildLatestDetailFallback(symbol);
    }

    // 전일 종가: 선택일 직전 거래일의 종가, 없으면 당일 시가로 대체.
    final double previousClose;
    if (selectedIndex + 1 < availableDates.length) {
      final previousRow = rowsByDate[_dateKey(availableDates[selectedIndex + 1])];
      previousClose = previousRow?.closePrice ?? selectedRow.openPrice;
    } else {
      previousClose = selectedRow.openPrice;
    }

    // realtime은 최신 거래일에서만 사용한다.
    final realtimeQuote = isLatest
        ? (await _loadRealtimeQuotes([symbol]))[symbol]
        : null;

    final currentPrice = realtimeQuote != null
        ? realtimeQuote.currentPrice
        : selectedRow.closePrice;
    final changeAmount = currentPrice - previousClose;
    final changeRate = realtimeQuote != null
        ? realtimeQuote.changeRate
        : _percentChange(changeAmount, previousClose);
    final tradeVolume = realtimeQuote != null
        ? realtimeQuote.accumulatedTradingVolume
        : selectedRow.accumulatedTradingVolume;

    return WatchlistDetail(
      itemId: canonicalDomesticFavoriteId(symbol),
      symbol: symbol,
      market: MarketType.domestic,
      currency: 'KRW',
      currentPrice: currentPrice,
      changeAmount: changeAmount,
      changeRate: changeRate,
      tradeVolume: tradeVolume,
      volumeRatio: _volumeRatio(
        windowDatesDescending: windowDates,
        rowsByDate: rowsByDate,
      ),
      openPrice: selectedRow.openPrice,
      openChangeRate: _percentChange(
        selectedRow.openPrice - previousClose,
        previousClose,
      ),
      highPrice: selectedRow.highPrice,
      highChangeRate: _percentChange(
        selectedRow.highPrice - previousClose,
        previousClose,
      ),
      lowPrice: selectedRow.lowPrice,
      lowChangeRate: _percentChange(
        selectedRow.lowPrice - previousClose,
        previousClose,
      ),
      candles: _candles(
        windowDatesDescending: windowDates,
        rowsByDate: rowsByDate,
      ),
    );
  }

  @override
  Future<List<StockSearchItem>> searchStocks({required String query}) async {
    // 빈 검색어는 네트워크 호출 없이 즉시 빈 결과.
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return const <StockSearchItem>[];
    }

    final items = await _client.searchStocks(trimmedQuery);
    final favoriteIds = await loadFavoriteIds();

    final seenSymbols = <String>{};
    final results = <StockSearchItem>[];
    for (final item in items) {
      // 국내 6자리 종목만 통과, 동일 symbol 중복 제거.
      if (!item.isDomesticStock || !seenSymbols.add(item.code)) {
        continue;
      }

      final canonicalId = canonicalDomesticFavoriteId(item.code);
      results.add(
        StockSearchItem(
          id: canonicalId,
          market: MarketType.domestic,
          marketLabel: item.typeName,
          symbol: item.code,
          name: item.name,
          isFavorite: favoriteIds.contains(canonicalId),
          logoUrl: _logoUrlResolver.resolveDomesticStockLogoUrl(item.code),
        ),
      );
    }

    return results;
  }

  Future<WatchlistDetail> _buildLatestDetailFallback(String symbol) async {
    final entry = await _loadLatestHistoricalEntry(symbol);
    if (entry == null) {
      throw StateError('No historical data available for $symbol');
    }
    final firstPage = await _loadDailyHistoryPage(symbol, 1);
    final windowDates = firstPage.priceInfos
        .take(30)
        .map((row) => normalizeAsOfDate(row.localDate))
        .toList(growable: false);
    final rowsByDate = <String, NaverHistoricalPriceDto>{
      for (final row in firstPage.priceInfos) _dateKey(row.localDate): row,
    };

    final realtimeQuote = (await _loadRealtimeQuotes([symbol]))[symbol];
    final previousClose = entry.previousClose;
    final currentPrice = realtimeQuote != null
        ? realtimeQuote.currentPrice
        : entry.row.closePrice;
    final changeAmount = currentPrice - previousClose;

    return WatchlistDetail(
      itemId: canonicalDomesticFavoriteId(symbol),
      symbol: symbol,
      market: MarketType.domestic,
      currency: 'KRW',
      currentPrice: currentPrice,
      changeAmount: changeAmount,
      changeRate: realtimeQuote != null
          ? realtimeQuote.changeRate
          : _percentChange(changeAmount, previousClose),
      tradeVolume: realtimeQuote != null
          ? realtimeQuote.accumulatedTradingVolume
          : entry.row.accumulatedTradingVolume,
      volumeRatio: _volumeRatio(
        windowDatesDescending: windowDates,
        rowsByDate: rowsByDate,
      ),
      openPrice: entry.row.openPrice,
      openChangeRate: _percentChange(
        entry.row.openPrice - previousClose,
        previousClose,
      ),
      highPrice: entry.row.highPrice,
      highChangeRate: _percentChange(
        entry.row.highPrice - previousClose,
        previousClose,
      ),
      lowPrice: entry.row.lowPrice,
      lowChangeRate: _percentChange(
        entry.row.lowPrice - previousClose,
        previousClose,
      ),
      candles: _candles(
        windowDatesDescending: windowDates,
        rowsByDate: rowsByDate,
      ),
    );
  }

  Future<List<String>> _favoriteSymbols() async {
    final favoriteIds = await loadFavoriteIds();
    final symbols = <String>[];
    for (final id in favoriteIds) {
      final symbol = domesticSymbolFromFavoriteId(id);
      if (symbol != null) {
        symbols.add(symbol);
      }
    }
    return symbols;
  }

  Future<String?> _firstFavoriteSymbol() async {
    final symbols = await _favoriteSymbols();
    return symbols.isEmpty ? null : symbols.first;
  }

  @override
  Future<Set<String>> loadFavoriteIds() async {
    if (_favoriteIdsCache != null) {
      return Set<String>.unmodifiable(_favoriteIdsCache!);
    }

    final rawIds = await _favoriteIdsLocalStore.loadRawIds();
    final canonicalIds = rawIds.where(_isCanonicalFavoriteId).toSet();
    final hasLegacyOrInvalidIds =
        rawIds.isNotEmpty && canonicalIds.length != rawIds.length;

    final resolvedIds = !_favoriteIdsLocalStore.hasStoredIds
        ? <String>{...defaultNaverDomesticFavoriteIds}
        : hasLegacyOrInvalidIds
        ? <String>{...defaultNaverDomesticFavoriteIds}
        : canonicalIds;

    _favoriteIdsCache = resolvedIds;

    if (!setEquals(rawIds, resolvedIds)) {
      await _favoriteIdsLocalStore.saveRawIds(resolvedIds);
    }

    return Set<String>.unmodifiable(resolvedIds);
  }

  @override
  Future<void> addFavorite({required String itemId}) async {
    final canonicalId = _requireCanonicalFavoriteId(itemId);
    final favoriteIds = {...await loadFavoriteIds(), canonicalId};
    _favoriteIdsCache = favoriteIds;
    await _favoriteIdsLocalStore.saveRawIds(favoriteIds);
  }

  @override
  Future<void> removeFavorite({required String itemId}) async {
    final canonicalId = _requireCanonicalFavoriteId(itemId);
    final favoriteIds = {...await loadFavoriteIds()}..remove(canonicalId);
    _favoriteIdsCache = favoriteIds;
    await _favoriteIdsLocalStore.saveRawIds(favoriteIds);
  }

  Future<Map<String, NaverChartMetadataDto>> _loadMetadataBatch(
    List<String> symbols,
  ) async {
    final results = <String, NaverChartMetadataDto>{};
    for (final symbol in symbols) {
      try {
        results[symbol] = await _loadMetadata(symbol);
      } catch (error, stackTrace) {
        debugPrint('Skipping Naver metadata for $symbol: $error\n$stackTrace');
      }
    }
    return results;
  }

  Future<NaverChartMetadataDto> _loadMetadata(String symbol) async {
    final cached = _metadataCache[symbol];
    if (cached != null) {
      return cached;
    }

    final metadata = await _client.fetchChartMetadata(symbol);
    _metadataCache[symbol] = metadata;
    return metadata;
  }

  Future<NaverDailyHistoryPageDto> _loadDailyHistoryPage(
    String symbol,
    int page,
  ) async {
    final cacheKey = _dailyHistoryPageCacheKey(symbol, page);
    final cached = _dailyHistoryPageCache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final historyPage = await _client.fetchDailyHistoryPage(
      symbol: symbol,
      page: page,
    );
    _dailyHistoryPageCache[cacheKey] = historyPage;
    return historyPage;
  }

  Future<Map<String, NaverRealtimeQuoteDto>> _loadRealtimeQuotes(
    Iterable<String> symbols,
  ) async {
    final requestedSymbols = symbols.toSet();
    final now = DateTime.now();
    final missingSymbols = <String>[];
    final quotes = <String, NaverRealtimeQuoteDto>{};

    for (final symbol in requestedSymbols) {
      final cached = _realtimeQuoteCache[symbol];
      final isFresh =
          cached != null &&
          now.difference(cached.fetchedAt) <= realtimeCacheTtl;
      if (isFresh) {
        quotes[symbol] = cached.quote;
      } else {
        missingSymbols.add(symbol);
      }
    }

    if (missingSymbols.isNotEmpty) {
      try {
        final fetchedQuotes = await _client.fetchRealtimeQuotes(missingSymbols);
        final fetchedAt = DateTime.now();
        for (final entry in fetchedQuotes.entries) {
          _realtimeQuoteCache[entry.key] = _RealtimeQuoteCacheEntry(
            quote: entry.value,
            fetchedAt: fetchedAt,
          );
          quotes[entry.key] = entry.value;
        }
      } catch (error, stackTrace) {
        debugPrint(
          'Falling back to historical-only Naver data for realtime batch: '
          '$error\n$stackTrace',
        );
      }
    }

    return quotes;
  }

  Future<_HistoricalEntry?> _loadHistoricalEntryForDate({
    required String symbol,
    required List<DateTime> availableDates,
    required DateTime asOf,
  }) async {
    final selectedIndex = _indexOfDate(availableDates, asOf);
    if (selectedIndex == null) {
      return null;
    }

    final selectedPageNumber = _pageNumberForIndex(selectedIndex);
    final selectedPage = await _loadDailyHistoryPage(
      symbol,
      selectedPageNumber,
    );
    final selectedRow = _rowForDate(selectedPage.priceInfos, asOf);
    if (selectedRow == null) {
      return null;
    }

    final previousClose = await _resolvePreviousClose(
      symbol: symbol,
      availableDates: availableDates,
      selectedIndex: selectedIndex,
      fallbackOpenPrice: selectedRow.openPrice,
      rowsByDate: {
        for (final row in selectedPage.priceInfos) _dateKey(row.localDate): row,
      },
    );

    return _HistoricalEntry(row: selectedRow, previousClose: previousClose);
  }

  Future<_HistoricalEntry?> _loadLatestHistoricalEntry(String symbol) async {
    final firstPage = await _loadDailyHistoryPage(symbol, 1);
    if (firstPage.priceInfos.isEmpty) {
      return null;
    }

    final selectedRow = firstPage.priceInfos.first;
    double previousClose = selectedRow.openPrice;
    if (firstPage.priceInfos.length > 1) {
      previousClose = firstPage.priceInfos[1].closePrice;
    } else {
      final nextPageRows = (await _loadDailyHistoryPage(symbol, 2)).priceInfos;
      if (nextPageRows.isNotEmpty) {
        previousClose = nextPageRows.first.closePrice;
      }
    }

    return _HistoricalEntry(row: selectedRow, previousClose: previousClose);
  }

  Future<double> _resolvePreviousClose({
    required String symbol,
    required List<DateTime> availableDates,
    required int selectedIndex,
    required double fallbackOpenPrice,
    required Map<String, NaverHistoricalPriceDto> rowsByDate,
  }) async {
    if (selectedIndex >= availableDates.length - 1) {
      return fallbackOpenPrice;
    }

    final previousDate = availableDates[selectedIndex + 1];
    final previousRowFromCache = rowsByDate[_dateKey(previousDate)];
    if (previousRowFromCache != null) {
      return previousRowFromCache.closePrice;
    }

    final page = await _loadDailyHistoryPage(
      symbol,
      _pageNumberForIndex(selectedIndex + 1),
    );
    final previousRow = _rowForDate(page.priceInfos, previousDate);
    return previousRow?.closePrice ?? fallbackOpenPrice;
  }

  WatchlistItem _buildWatchlistItem({
    required String symbol,
    required NaverChartMetadataDto metadata,
    required _HistoricalEntry historicalEntry,
    required NaverRealtimeQuoteDto? realtimeQuote,
    required DateTime? latestDate,
  }) {
    final isLatest =
        latestDate != null &&
        normalizeAsOfDate(historicalEntry.row.localDate) == latestDate;
    final currentPrice = isLatest && realtimeQuote != null
        ? realtimeQuote.currentPrice
        : historicalEntry.row.closePrice;
    final changeRate = isLatest && realtimeQuote != null
        ? realtimeQuote.changeRate
        : _percentChange(
            currentPrice - historicalEntry.previousClose,
            historicalEntry.previousClose,
          );
    final tradeVolume = isLatest && realtimeQuote != null
        ? realtimeQuote.accumulatedTradingVolume
        : historicalEntry.row.accumulatedTradingVolume;
    final marketCap = realtimeQuote == null
        ? 0
        : (realtimeQuote.countOfListedStock * realtimeQuote.currentPrice)
              .round();

    return WatchlistItem(
      id: canonicalDomesticFavoriteId(symbol),
      market: MarketType.domestic,
      symbol: symbol,
      name: metadata.stockName,
      currency: 'KRW',
      currentPrice: currentPrice,
      changeRate: changeRate,
      tradeVolume: tradeVolume,
      marketCap: marketCap,
      logoUrl: _logoUrlResolver.resolveDomesticStockLogoUrl(symbol),
    );
  }

  DateTime _resolveAsOf(
    List<DateTime> availableDates,
    DateTime? requestedAsOf,
  ) {
    if (availableDates.isEmpty) {
      return normalizeAsOfDate(requestedAsOf ?? DateTime.now());
    }

    if (requestedAsOf == null) {
      return availableDates.first;
    }

    final normalizedAsOf = normalizeAsOfDate(requestedAsOf);
    for (final date in availableDates) {
      if (date == normalizedAsOf) {
        return date;
      }
    }

    return availableDates.first;
  }

  int? _indexOfDate(List<DateTime> availableDates, DateTime asOf) {
    final normalizedAsOf = normalizeAsOfDate(asOf);
    for (var index = 0; index < availableDates.length; index += 1) {
      if (availableDates[index] == normalizedAsOf) {
        return index;
      }
    }
    return null;
  }

  int _pageNumberForIndex(int index) {
    return (index ~/ _historyRowsPerPage) + 1;
  }

  NaverHistoricalPriceDto? _rowForDate(
    Iterable<NaverHistoricalPriceDto> rows,
    DateTime date,
  ) {
    final dateKey = _dateKey(date);
    for (final row in rows) {
      if (_dateKey(row.localDate) == dateKey) {
        return row;
      }
    }
    return null;
  }

  double _volumeRatio({
    required List<DateTime> windowDatesDescending,
    required Map<String, NaverHistoricalPriceDto> rowsByDate,
  }) {
    if (windowDatesDescending.isEmpty) {
      return 0;
    }

    final selectedRow = rowsByDate[_dateKey(windowDatesDescending.first)];
    if (selectedRow == null) {
      return 0;
    }

    final previousVolumes = <int>[];
    for (
      var index = 1;
      index < windowDatesDescending.length && previousVolumes.length < 5;
      index += 1
    ) {
      final row = rowsByDate[_dateKey(windowDatesDescending[index])];
      if (row != null) {
        previousVolumes.add(row.accumulatedTradingVolume);
      }
    }

    if (previousVolumes.isEmpty) {
      return 0;
    }

    final averageVolume =
        previousVolumes.reduce((left, right) => left + right) /
        previousVolumes.length;
    if (averageVolume == 0) {
      return 0;
    }

    return double.parse(
      (selectedRow.accumulatedTradingVolume / averageVolume).toStringAsFixed(2),
    );
  }

  List<CandlePoint> _candles({
    required List<DateTime> windowDatesDescending,
    required Map<String, NaverHistoricalPriceDto> rowsByDate,
  }) {
    return windowDatesDescending.reversed
        .map((date) => rowsByDate[_dateKey(date)])
        .whereType<NaverHistoricalPriceDto>()
        .map(
          (item) => CandlePoint(
            time: item.localDate,
            open: item.openPrice,
            high: item.highPrice,
            low: item.lowPrice,
            close: item.closePrice,
            direction: directionFromDelta(item.closePrice - item.openPrice),
          ),
        )
        .toList(growable: false);
  }

  bool _isCanonicalFavoriteId(String itemId) {
    return domesticSymbolFromFavoriteId(itemId) != null;
  }

  String _requireCanonicalFavoriteId(String itemId) {
    final symbol = domesticSymbolFromFavoriteId(itemId);
    if (symbol == null) {
      throw ArgumentError.value(
        itemId,
        'itemId',
        'Naver repository only accepts canonical domestic favorite ids',
      );
    }
    return canonicalDomesticFavoriteId(symbol);
  }

  String _dailyHistoryPageCacheKey(String symbol, int page) => '$symbol::$page';

  String _dateKey(DateTime value) => formatApiDate(value);

  double _percentChange(double delta, double base) {
    if (base == 0) {
      return 0;
    }
    return double.parse(((delta / base) * 100).toStringAsFixed(2));
  }
}

class _RealtimeQuoteCacheEntry {
  const _RealtimeQuoteCacheEntry({
    required this.quote,
    required this.fetchedAt,
  });

  final NaverRealtimeQuoteDto quote;
  final DateTime fetchedAt;
}

class _HistoricalEntry {
  const _HistoricalEntry({required this.row, required this.previousClose});

  final NaverHistoricalPriceDto row;
  final double previousClose;
}
