// ignore_for_file: unused_element

import '../../domain/services/watchlist_sorting.dart';

class NaverAutocompleteItemDto {
  const NaverAutocompleteItemDto({
    required this.code,
    required this.name,
    required this.typeCode,
    required this.typeName,
    required this.url,
    required this.nationCode,
    required this.category,
  });

  factory NaverAutocompleteItemDto.fromJson(Map<String, dynamic> json) {
    // 자동완성 응답은 문자열 필드 위주라 그대로 읽는다.
    // 국내주식 판별(isDomesticStock)에 쓰이는 code/url/nationCode/category는
    // 누락되면 안 되므로 _readString으로 강제하고, 나머지는 빈 값 허용을 위해
    // toString fallback을 사용한다.
    return NaverAutocompleteItemDto(
      code: _readString(json['code']),
      name: _readString(json['name']),
      typeCode: json['typeCode']?.toString() ?? '',
      typeName: json['typeName']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      nationCode: json['nationCode']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
    );
  }

  final String code;
  final String name;
  final String typeCode;
  final String typeName;
  final String url;
  final String nationCode;
  final String category;

  bool get isDomesticStock =>
      category == 'stock' &&
      nationCode == 'KOR' &&
      RegExp(r'^\d{6}$').hasMatch(code) &&
      url.contains('/domestic/stock/');
}

class NaverRealtimeQuoteDto {
  const NaverRealtimeQuoteDto({
    required this.symbol,
    required this.currentPrice,
    required this.previousClose,
    required this.openPrice,
    required this.highPrice,
    required this.lowPrice,
    required this.accumulatedTradingVolume,
    required this.countOfListedStock,
  });

  factory NaverRealtimeQuoteDto.fromJson(Map<String, dynamic> json) {
    // realtime 응답은 축약 키(cd/nv/pcv...)를 쓴다. 숫자 값이 문자열/숫자로
    // 섞여 오므로 _readDouble/_readInt로 정규화한다. countOfListedStock는
    // 시총 계산용 부가 정보라 없으면 0으로 둔다.
    return NaverRealtimeQuoteDto(
      symbol: _readString(json['cd']),
      currentPrice: _readDouble(json['nv']),
      previousClose: _readDouble(json['pcv']),
      openPrice: _readDouble(json['ov']),
      highPrice: _readDouble(json['hv']),
      lowPrice: _readDouble(json['lv']),
      accumulatedTradingVolume: _readInt(json['aq']),
      countOfListedStock: _readNullableInt(json['countOfListedStock']) ?? 0,
    );
  }

  final String symbol;
  final double currentPrice;
  final double previousClose;
  final double openPrice;
  final double highPrice;
  final double lowPrice;
  final int accumulatedTradingVolume;
  final int countOfListedStock;

  double get changeAmount => currentPrice - previousClose;

  double get changeRate {
    if (previousClose == 0) {
      return 0;
    }
    return double.parse(
      (((currentPrice - previousClose) / previousClose) * 100).toStringAsFixed(
        2,
      ),
    );
  }
}

class NaverChartMetadataDto {
  const NaverChartMetadataDto({
    required this.symbol,
    required this.stockName,
    required this.stockExchangeNameKor,
  });

  factory NaverChartMetadataDto.fromJson(Map<String, dynamic> json) {
    // 메타데이터 응답의 symbolCode/stockName/stockExchangeNameKor를 읽는다.
    // symbol은 이후 조회 key로 쓰이므로 필수, 이름/거래소명은 UI 표기용이라
    // 누락 시 빈 문자열로 둔다.
    return NaverChartMetadataDto(
      symbol: _readString(json['symbolCode']),
      stockName: json['stockName']?.toString() ?? '',
      stockExchangeNameKor: json['stockExchangeNameKor']?.toString() ?? '',
    );
  }

  final String symbol;
  final String stockName;
  final String stockExchangeNameKor;
}

class NaverHistoricalPriceDto {
  const NaverHistoricalPriceDto({
    required this.localDate,
    required this.closePrice,
    required this.openPrice,
    required this.highPrice,
    required this.lowPrice,
    required this.accumulatedTradingVolume,
  });

  factory NaverHistoricalPriceDto.fromJson(Map<String, dynamic> json) {
    // 일별 OHLCV 한 행. localDate는 yyyyMMdd 문자열이라 _readLocalDate로
    // 정규화하고, 가격/거래량은 콤마 포함 문자열도 처리되도록 헬퍼로 파싱한다.
    return NaverHistoricalPriceDto(
      localDate: _readLocalDate(json['localDate']),
      closePrice: _readDouble(json['closePrice']),
      openPrice: _readDouble(json['openPrice']),
      highPrice: _readDouble(json['highPrice']),
      lowPrice: _readDouble(json['lowPrice']),
      accumulatedTradingVolume: _readInt(json['accumulatedTradingVolume']),
    );
  }

  final DateTime localDate;
  final double closePrice;
  final double openPrice;
  final double highPrice;
  final double lowPrice;
  final int accumulatedTradingVolume;
}

class NaverHistoricalChartDto {
  const NaverHistoricalChartDto({
    required this.symbol,
    required this.periodType,
    required this.priceInfos,
  });

  factory NaverHistoricalChartDto.fromJson(Map<String, dynamic> json) {
    // chart wrapper: code/periodType + priceInfos 배열. 각 행은
    // NaverHistoricalPriceDto.fromJson으로 위임해 파싱한다.
    final rawPriceInfos = json['priceInfos'];
    final priceInfos = <NaverHistoricalPriceDto>[];
    if (rawPriceInfos is List) {
      for (final row in rawPriceInfos) {
        if (row is Map) {
          priceInfos.add(
            NaverHistoricalPriceDto.fromJson(
              row.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
    }

    return NaverHistoricalChartDto(
      symbol: _readString(json['code']),
      periodType: json['periodType']?.toString() ?? '',
      priceInfos: List<NaverHistoricalPriceDto>.unmodifiable(priceInfos),
    );
  }

  final String symbol;
  final String periodType;
  final List<NaverHistoricalPriceDto> priceInfos;
}

class NaverDailyHistoryPageDto {
  const NaverDailyHistoryPageDto({
    required this.symbol,
    required this.page,
    required this.lastPage,
    required this.priceInfos,
  });

  final String symbol;
  final int page;
  final int lastPage;
  final List<NaverHistoricalPriceDto> priceInfos;
}

DateTime _readLocalDate(Object? value) {
  final text = _readString(value);
  if (text.length != 8) {
    throw FormatException('Invalid Naver localDate "$text"');
  }

  return normalizeAsOfDate(
    DateTime(
      int.parse(text.substring(0, 4)),
      int.parse(text.substring(4, 6)),
      int.parse(text.substring(6, 8)),
    ),
  );
}

String _readString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    throw FormatException('Missing string value for "$value"');
  }
  return text;
}

double _readDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.parse(_readString(value).replaceAll(',', ''));
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.parse(_readString(value).replaceAll(',', ''));
}

int? _readNullableInt(Object? value) {
  if (value == null) {
    return null;
  }
  return _readInt(value);
}
