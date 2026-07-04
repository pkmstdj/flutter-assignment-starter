// ignore_for_file: unused_element, unused_field

import 'dart:convert';

import 'package:dio/dio.dart';

import '../dtos/naver_stock_dtos.dart';

abstract interface class NaverStockDataClient {
  Future<List<NaverAutocompleteItemDto>> searchStocks(String query);

  Future<Map<String, NaverRealtimeQuoteDto>> fetchRealtimeQuotes(
    Iterable<String> symbols,
  );

  Future<NaverChartMetadataDto> fetchChartMetadata(String symbol);

  Future<NaverDailyHistoryPageDto> fetchDailyHistoryPage({
    required String symbol,
    required int page,
  });
}

class NaverDomesticStockClient implements NaverStockDataClient {
  const NaverDomesticStockClient(this._dio);

  final Dio _dio;

  static const Map<String, String> _defaultHeaders = {
    'accept': 'application/json, text/plain, */*',
    'referer': 'https://m.stock.naver.com/',
    'accept-language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
    'user-agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/123.0.0.0 Safari/537.36',
  };

  static Map<String, dynamic> _decodeJsonObjectBody(
    Object? data,
    String contextLabel,
  ) {
    if (data == null) {
      throw FormatException('$contextLabel response body is empty');
    }

    if (data is Map<String, dynamic>) {
      return data;
    }

    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw FormatException('$contextLabel response is not a JSON object');
    }

    if (data is List<int>) {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw FormatException('$contextLabel response is not a JSON object');
    }

    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }

    throw FormatException('$contextLabel response body has unsupported shape');
  }

  static Map<String, dynamic> _asStringKeyedMap(
    Object? value,
    String contextLabel,
  ) {
    if (value is Map<String, dynamic>) {
      return value;
    }

    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }

    throw FormatException('$contextLabel is not a JSON object');
  }

  @override
  Future<List<NaverAutocompleteItemDto>> searchStocks(String query) async {
    // 자동완성 endpoint는 text/plain으로 내려오는 경우가 있어 plain으로 받고
    // _decodeJsonObjectBody로 직접 디코드한다.
    final response = await _dio.get<dynamic>(
      'https://ac.stock.naver.com/ac',
      queryParameters: <String, dynamic>{
        'q': query,
        'target': 'stock,ipo,index,marketindicator',
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: _defaultHeaders,
      ),
    );

    final body = _decodeJsonObjectBody(response.data, 'Naver autocomplete');
    final items = body['items'];
    if (items is! List) {
      return const <NaverAutocompleteItemDto>[];
    }

    return <NaverAutocompleteItemDto>[
      for (final item in items)
        if (item is Map)
          NaverAutocompleteItemDto.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
  }

  @override
  Future<Map<String, NaverRealtimeQuoteDto>> fetchRealtimeQuotes(
    Iterable<String> symbols,
  ) async {
    // 중복 symbol 제거 후, 요청할 게 없으면 네트워크 호출을 생략한다.
    final uniqueSymbols = symbols.toSet().toList(growable: false);
    if (uniqueSymbols.isEmpty) {
      return const <String, NaverRealtimeQuoteDto>{};
    }

    final response = await _dio.get<dynamic>(
      'https://polling.finance.naver.com/api/realtime',
      queryParameters: <String, dynamic>{
        'query': 'SERVICE_ITEM:${uniqueSymbols.join(',')}',
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: _defaultHeaders,
      ),
    );

    // 응답 구조: result -> areas[] -> datas[] 각 행이 종목 하나.
    final body = _decodeJsonObjectBody(response.data, 'Naver realtime');
    final result = _asStringKeyedMap(body['result'], 'Naver realtime result');
    final areas = result['areas'];
    final quotes = <String, NaverRealtimeQuoteDto>{};
    if (areas is List) {
      for (final area in areas) {
        if (area is! Map) {
          continue;
        }
        final datas = area['datas'];
        if (datas is! List) {
          continue;
        }
        for (final data in datas) {
          if (data is Map) {
            final quote = NaverRealtimeQuoteDto.fromJson(
              data.map((key, value) => MapEntry(key.toString(), value)),
            );
            quotes[quote.symbol] = quote;
          }
        }
      }
    }
    return quotes;
  }

  @override
  Future<NaverChartMetadataDto> fetchChartMetadata(String symbol) async {
    final response = await _dio.get<dynamic>(
      'https://stock.naver.com/api/securityFe/api/fchart/domestic/stock/$symbol',
      options: Options(
        responseType: ResponseType.plain,
        headers: _defaultHeaders,
      ),
    );

    final body = _decodeJsonObjectBody(response.data, 'Naver chart metadata');
    return NaverChartMetadataDto.fromJson(body);
  }

  @override
  Future<NaverDailyHistoryPageDto> fetchDailyHistoryPage({
    required String symbol,
    required int page,
  }) async {
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'page must be >= 1');
    }

    // 이 endpoint는 JSON이 아니라 EUC-KR HTML을 반환한다. 우리가 쓰는 값은
    // 날짜/숫자(ASCII)뿐이라, 바이트를 latin1로 그대로 디코드해도 안전하다.
    final response = await _dio.get<List<int>>(
      'https://finance.naver.com/item/sise_day.naver',
      queryParameters: <String, dynamic>{'code': symbol, 'page': page},
      options: Options(
        responseType: ResponseType.bytes,
        headers: _defaultHeaders,
      ),
    );

    final html = latin1.decode(
      response.data ?? const <int>[],
      allowInvalid: true,
    );

    return NaverDailyHistoryPageDto(
      symbol: symbol,
      page: page,
      lastPage: _parseLastPage(html, fallbackPage: page),
      priceInfos: _parseDailyHistoryRows(html),
    );
  }
}

/// sise_day HTML 테이블에서 일별 OHLCV 행을 파싱한다.
///
/// 데이터 행은 `날짜(td align=center) + num 셀 6개(종가, 전일비, 시가, 고가,
/// 저가, 거래량)` 구조다. 날짜가 없는 헤더/여백 행은 자연히 걸러진다.
List<NaverHistoricalPriceDto> _parseDailyHistoryRows(String html) {
  final rowPattern = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true);
  final datePattern = RegExp(r'(\d{4})\.(\d{2})\.(\d{2})');
  final numCellPattern = RegExp(
    r'<td[^>]*class="num[^"]*"[^>]*>(.*?)</td>',
    dotAll: true,
  );
  final tagPattern = RegExp(r'<[^>]*>');

  final rows = <NaverHistoricalPriceDto>[];
  for (final rowMatch in rowPattern.allMatches(html)) {
    final rowHtml = rowMatch.group(1)!;
    final dateMatch = datePattern.firstMatch(rowHtml);
    if (dateMatch == null) {
      continue;
    }

    // num 셀은 위치가 고정(0:종가,1:전일비,2:시가,3:고가,4:저가,5:거래량)이라
    // 빈 값도 제거하지 않고 인덱스로 접근한다.
    final numbers = numCellPattern
        .allMatches(rowHtml)
        .map(
          (cell) => cell
              .group(1)!
              .replaceAll(tagPattern, '')
              .replaceAll('&nbsp;', '')
              .trim(),
        )
        .toList(growable: false);
    if (numbers.length < 6) {
      continue;
    }

    final localDate =
        '${dateMatch.group(1)}${dateMatch.group(2)}${dateMatch.group(3)}';
    rows.add(
      // 문자열 map으로 넘겨 DTO의 파싱/날짜 정규화 로직을 그대로 재사용한다.
      NaverHistoricalPriceDto.fromJson(<String, dynamic>{
        'localDate': localDate,
        'closePrice': numbers[0],
        'openPrice': numbers[2],
        'highPrice': numbers[3],
        'lowPrice': numbers[4],
        'accumulatedTradingVolume': numbers[5],
      }),
    );
  }
  return rows;
}

/// 페이지네이션 영역에서 마지막 페이지 번호를 읽는다.
/// `pgRR`(맨뒤) 링크가 있으면 그 page 값을, 없으면(단일 페이지 등) 페이지
/// 링크 중 최댓값을, 그것도 없으면 현재 페이지를 사용한다.
int _parseLastPage(String html, {required int fallbackPage}) {
  final lastLink = RegExp(
    r'pgRR[^>]*>\s*<a[^>]*href="[^"]*page=(\d+)',
    dotAll: true,
  ).firstMatch(html);
  if (lastLink != null) {
    return int.parse(lastLink.group(1)!);
  }

  var maxPage = fallbackPage;
  for (final match in RegExp(r'page=(\d+)').allMatches(html)) {
    final value = int.tryParse(match.group(1)!);
    if (value != null && value > maxPage) {
      maxPage = value;
    }
  }
  return maxPage;
}

double _parseDouble(String value) {
  return double.parse(value.replaceAll(',', ''));
}

int _parseInt(String value) {
  return int.parse(value.replaceAll(',', ''));
}

Map<String, String> naverDesktopLikeHeaders() =>
    Map<String, String>.unmodifiable(NaverDomesticStockClient._defaultHeaders);
