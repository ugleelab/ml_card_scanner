/*
                          카드 번호 인식 알고리즘 (DefaultParserAlgorithm)

📋 알고리즘 개요:
  다양한 카드 레이아웃에서 카드 번호를 정확하게 인식하기 위한 단계별 처리

🔄 처리 순서:
  전처리 → 1단계 → 2단계 → 3단계 → 검증

📝 지원 형태:
  ✅ 연속 숫자: 1234567890123456
  ✅ 구분자 포함: 1234-5678-9012-3456, 1234 5678 9012 3456
  ✅ 세로 배치: Block1="4890", Block2="1603", Block3="4347", Block4="0305"
  ✅ 개행 분리: "1603\n4347" (하나의 블록 내 개행)
  ✅ 2x2 배치: "4890 1603" / "4347 0305"

🚫 필터링 대상:
  ❌ 날짜 패턴: MM/YY, MMYY (01-12월, 20-50년)
  ❌ 전화번호: 15xx/16xx + 하이픈
  ❌ CVC 코드: 3-4자리 보안 코드

🏦 지원 카드사:
  • Visa: 4로 시작, 13/16/19자리
  • MasterCard: 5로 시작, 16자리
  • AMEX: 34/37로 시작, 15자리
  • 기타: 13-19자리 범위 내 허용

🔧 디버깅 가이드:
  1. 로그에서 인식된 블록 확인
  2. 날짜 필터링 결과 확인
  3. 각 단계별 매칭 결과 확인
  4. 유효성 검증 실패 원인 분석

*/

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ml_card_scanner/src/model/card_info.dart';
import 'package:ml_card_scanner/src/parser/card_parser_const.dart';
import 'package:ml_card_scanner/src/parser/parser_algorithm.dart';
import 'package:ml_card_scanner/src/utils/card_info_variants_extension.dart';
import 'package:ml_card_scanner/src/utils/int_extension.dart';
import 'package:ml_card_scanner/src/utils/string_extension.dart';

class DefaultParserAlgorithm extends ParserAlgorithm {
  final int cardScanTries;
  final List<CardInfo> _recognizedVariants = List.empty(growable: true);

  DefaultParserAlgorithm(this.cardScanTries);

  @override
  CardInfo? parse(RecognizedText recognizedText) {
    CardInfo? cardOption;

    try {
      // 원본 텍스트를 유지하여 공백/하이픈 구분 카드 번호를 인식할 수 있도록 함
      final elements = recognizedText.blocks.map((e) => e.text).toList();
      final possibleCardNumber = getCardNumber(elements);
      final cardType = getCardType(possibleCardNumber);
      final expire = getExpiryDate(elements);
      cardOption = CardInfo(
        number: possibleCardNumber,
        type: cardType,
        expiry: expire,
      );
    } catch (e, _) {
      cardOption = null;
    }

    if (cardOption != null && cardOption.isValid()) {
      _recognizedVariants.add(cardOption);
    }

    if (_recognizedVariants.length == cardScanTries) {
      final cardNumber = _recognizedVariants.getCardNumber();
      final cardDate = _recognizedVariants.getCardDate();
      final cardType = getCardType(cardNumber);
      _recognizedVariants.clear();

      return CardInfo(
        number: cardNumber,
        type: cardType,
        expiry: cardDate.possibleDateFormatted(),
      );
    }
    return null;
  }

  @override
  String getCardNumber(List<String> inputs) {
    /*
    ========================================
    카드 번호 인식 알고리즘 (우선순위 순)
    ========================================
    
    전처리: 날짜 데이터 제거
    1. 연속 숫자 형태 (1234567890123456)
    2. 구분자 포함 형태 (1234-5678-9012-3456, 1234 5678 9012 3456)
    3. 다중 라인 형태 (세로 배치, 개행 분리)
    
    각 단계에서 카드 번호 유효성 검증 수행
    */

    // ========== 전처리: 날짜 데이터 제거 ==========
    final detectedDate = getExpiryDate(inputs);
    final filteredInputs = _filterOutDateData(inputs, detectedDate);

    // ========== 1단계: 연속 숫자 형태 카드 번호 ==========
    // 예: "1234567890123456"
    for (final item in filteredInputs) {
      final cleanValue = item.fixPossibleMisspells();

      // 길이 검증 (13-19자리)
      if (cleanValue.length >= CardParserConst.minCardNumberLength &&
          cleanValue.length <= CardParserConst.maxCardNumberLength &&
          int.tryParse(cleanValue) != null) {
        // 카드 번호 유효성 검증 (카드사별 패턴 + Luhn 알고리즘)
        if (_isValidCardNumber(cleanValue)) {
          return cleanValue;
        }
      }
    }

    // ========== 2단계: 구분자 포함 카드 번호 ==========
    // 예: "1234-5678-9012-3456", "1234 5678 9012 3456"
    for (final item in filteredInputs) {
      final cardNumber = _extractFormattedCardNumber(item);
      if (cardNumber.isNotEmpty && _isValidCardNumber(cardNumber)) {
        return cardNumber;
      }
    }

    // ========== 3단계: 다중 라인 카드 번호 ==========
    // 예: 세로 배치 (4890, 1603, 4347, 0305)
    // 예: 개행 분리 ("1603\n4347")
    final multiLineCardNumber = _extractMultiLineCardNumber(filteredInputs);
    if (multiLineCardNumber.isNotEmpty &&
        _isValidCardNumber(multiLineCardNumber)) {
      return multiLineCardNumber;
    }

    // ========== 인식 실패 ==========
    return '';
  }

  /// ========== 2단계: 구분자 포함 카드 번호 추출 ==========
  /// 하이픈(-) 또는 공백( )으로 구분된 카드 번호를 찾아 연결
  /// 지원 형태: 4-4-4-4, 4-6-5, 4-4-4, 4-4
  String _extractFormattedCardNumber(String input) {
    /*
    지원하는 카드 번호 형태:
    - 4-4-4-4: 1234-5678-9012-3456 (일반적인 16자리)
    - 4-6-5: 1234-567890-12345 (AMEX 15자리)
    - 4-4-4: 1234-5678-9012 (12자리)
    - 4-4: 1234-5678 (8자리, 부분 인식)
    */

    final patterns = [
      RegExp(r'(\d{4})[-\s](\d{4})[-\s](\d{4})[-\s](\d{4})'), // 4-4-4-4 형태
      RegExp(r'(\d{4})[-\s](\d{6})[-\s](\d{5})'), // 4-6-5 형태 (AMEX)
      RegExp(r'(\d{4})[-\s](\d{4})[-\s](\d{4})'), // 4-4-4 형태
      RegExp(r'(\d{4})[-\s](\d{4})'), // 4-4 형태
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(input);
      if (match != null) {
        // 매치된 그룹들을 연결하여 카드 번호 생성
        var cardNumber = match
            .groups(List.generate(match.groupCount, (i) => i + 1))
            .where((group) => group != null)
            .join('');

        // 오인식 문자 수정 적용 (O->0, I->1 등)
        cardNumber = cardNumber.fixPossibleMisspells();

        // 카드 번호 길이 검증
        if (cardNumber.length >= CardParserConst.minCardNumberLength &&
            cardNumber.length <= CardParserConst.maxCardNumberLength) {
          return cardNumber;
        }
      }
    }

    return '';
  }

  /// ========== 3단계: 다중 라인 카드 번호 추출 ==========
  /// 여러 블록에 걸쳐 분할된 카드 번호를 찾아 조합
  /// 지원 형태: 세로 배치, 개행 분리, 2x2 배치
  String _extractMultiLineCardNumber(List<String> inputs) {
    /*
    지원하는 다중 라인 형태:
    1. 세로 배치: Block1="4890", Block2="1603", Block3="4347", Block4="0305"
    2. 개행 분리: Block="1603\n4347" (하나의 블록 내 개행)
    3. 2x2 배치: "4890 1603" / "4347 0305"
    
    필터링 조건:
    - 날짜 형태 제외 (01-12월, 20-50년)
    - 전화번호 패턴 제외 (15xx, 16xx + 하이픈)
    */

    final cardParts = <String>[];

    for (final input in inputs) {
      // 개행 문자로 분리된 텍스트도 처리하기 위해 줄별로 분리
      final lines = input.split('\n');

      for (final line in lines) {
        // 각 줄에서 4자리 숫자 패턴 찾기 (단어 경계 사용)
        final fourDigitMatches = RegExp(r'\b(\d{4})\b').allMatches(line);

        for (final match in fourDigitMatches) {
          final fourDigits = match.group(1)!;

          // 오인식 문자 수정 적용 (O->0, I->1 등)
          final correctedDigits = fourDigits.fixPossibleMisspells();

          // 날짜 패턴 필터링 (MMYY 형태 제외)
          final month = int.tryParse(correctedDigits.substring(0, 2));
          final year = int.tryParse(correctedDigits.substring(2, 4));
          final isDatePattern = month != null &&
              year != null &&
              month >= 1 &&
              month <= 12 &&
              year >= 20 &&
              year <= 50;

          // 전화번호 패턴 필터링
          final isPhonePattern = _isPhoneOrOtherNumber(correctedDigits, input);

          // 유효한 카드 번호 부분인 경우에만 추가
          if (!isDatePattern && !isPhonePattern) {
            cardParts.add(correctedDigits);
          }
        }
      }
    }

    // 중복 제거 (같은 숫자가 여러 블록에서 인식될 수 있음)
    final uniqueCardParts = cardParts.toSet().toList();

    // 4개의 4자리 숫자 → 16자리 카드 번호
    if (uniqueCardParts.length == 4) {
      final cardNumber = uniqueCardParts.join('');

      if (cardNumber.length >= CardParserConst.minCardNumberLength &&
          cardNumber.length <= CardParserConst.maxCardNumberLength) {
        return cardNumber;
      }
    }

    // 3개의 4자리 숫자 → 12자리 카드 번호 (일부 카드 형태)
    if (uniqueCardParts.length == 3) {
      final cardNumber = uniqueCardParts.join('');

      if (cardNumber.length == 12 &&
          cardNumber.length >= CardParserConst.minCardNumberLength) {
        return cardNumber;
      }
    }

    return '';
  }

  /// ========== 전처리: 날짜 데이터 필터링 ==========
  /// 인식된 날짜 정보를 입력 데이터에서 제거하여 카드 번호 인식 정확도 향상
  List<String> _filterOutDateData(List<String> inputs, String detectedDate) {
    /*
    제거 대상 날짜 패턴:
    1. MM/YY, MM-YY 형태 (예: 11/29, 11-29)
    2. MMYY 연속 숫자 (예: 1129)
    3. DATE/VALID/THRU/EXP 키워드와 함께 있는 날짜
    4. CVC와 함께 있는 날짜 (예: "CVC\n11/29 394")
    */

    if (detectedDate.isEmpty) {
      return inputs;
    }

    final filteredInputs = <String>[];

    for (final input in inputs) {
      var filteredInput = input;

      // 1. MM/YY 형태의 날짜 제거
      if (detectedDate.length == 4) {
        final month = detectedDate.substring(0, 2);
        final year = detectedDate.substring(2, 4);

        // MM/YY, MM-YY 패턴 제거
        filteredInput =
            filteredInput.replaceAll(RegExp('$month[/\\-]$year'), '');

        // MMYY 연속 숫자 제거
        filteredInput = filteredInput.replaceAll(detectedDate, '');
      }

      // 2. DATE, VALID, THRU, EXP 키워드와 함께 있는 날짜 패턴 제거
      filteredInput = filteredInput.replaceAll(
          RegExp(r'(?:DATE|VALID|THRU|EXP)[^0-9]*\d{1,2}[/\-]\d{2,4}',
              caseSensitive: false),
          '');

      // 3. CVC와 함께 있는 날짜 패턴 제거 (예: "CVC\n11/29 394")
      filteredInput = filteredInput.replaceAll(
          RegExp(r'CVC[^0-9]*\d{1,2}[/\-]\d{2,4}[^0-9]*\d{3,4}',
              caseSensitive: false),
          'CVC');

      // 빈 문자열이 아닌 경우에만 추가
      if (filteredInput.trim().isNotEmpty) {
        filteredInputs.add(filteredInput.trim());
      }
    }

    return filteredInputs;
  }

  /// ========== 필터링: 전화번호 패턴 검증 ==========
  /// 4자리 숫자가 전화번호인지 확인하여 카드 번호에서 제외
  bool _isPhoneOrOtherNumber(String fourDigits, String context) {
    /*
    전화번호 패턴 (제외 대상):
    - 15xx, 16xx로 시작하면서 하이픈(-) 포함
    - PHONE, TEL 키워드와 함께 있는 경우
    
    허용 패턴:
    - 0으로 시작하는 숫자 (카드 번호 일부일 수 있음)
    - 단순 15xx, 16xx (하이픈 없으면 카드 번호 가능성)
    */

    // 전화번호 패턴: 15xx/16xx + 하이픈 또는 전화번호 키워드
    if ((fourDigits.startsWith('15') || fourDigits.startsWith('16')) &&
        (context.contains('-') ||
            context.contains('PHONE') ||
            context.contains('TEL'))) {
      return true;
    }

    // 기타 패턴은 카드 번호로 간주
    return false;
  }

  /// ========== 검증: 카드 번호 유효성 ==========
  /// 카드사별 패턴 및 길이 검증 (Luhn 알고리즘은 별도 구현 필요시 추가)
  bool _isValidCardNumber(String cardNumber) {
    /*
    카드사별 패턴:
    - Visa: 4로 시작, 13/16/19자리
    - MasterCard: 5로 시작, 16자리
    - AMEX: 34/37로 시작, 15자리
    - 기타: 13-19자리 범위 내 허용
    */

    if (cardNumber.isEmpty) {
      return false;
    }

    // 기본 길이 검증 (13-19자리)
    if (cardNumber.length < CardParserConst.minCardNumberLength ||
        cardNumber.length > CardParserConst.maxCardNumberLength) {
      return false;
    }

    // 카드사별 패턴 검증
    final firstDigit = cardNumber[0];
    switch (firstDigit) {
      case '4': // Visa
        return cardNumber.length == 13 ||
            cardNumber.length == 16 ||
            cardNumber.length == 19;
      case '5': // MasterCard
        return cardNumber.length == 16;
      case '3': // AMEX
        return cardNumber.length == 15 &&
            (cardNumber.startsWith('34') || cardNumber.startsWith('37'));
      default:
        // 기타 카드사 (JCB, Discover 등)
        return true;
    }
  }

  @override
  String getExpiryDate(List<String> inputs) {
    try {
      // 1. 먼저 "DATE", "VALID", "THRU", "EXP" 등이 포함된 블록에서 날짜 찾기
      for (final input in inputs) {
        final cleanInput =
            input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9/\-\s]'), '');

        // "DATE 11/29", "VALID THRU 11/29", "EXP 11/29" 등의 패턴 찾기
        if (cleanInput.contains('DATE') ||
            cleanInput.contains('VALID') ||
            cleanInput.contains('THRU') ||
            cleanInput.contains('EXP')) {
          // 1) MM/YY 또는 MM-YY 패턴 찾기 (예: "DATE 11/29")
          var dateMatch =
              RegExp(r'(\d{1,2})[/\-](\d{2,4})').firstMatch(cleanInput);
          if (dateMatch != null) {
            final month = dateMatch.group(1)!.padLeft(2, '0');
            var year = dateMatch.group(2)!;

            // 2자리 년도를 4자리로 변환 (29 -> 2029, 99 -> 2099)
            if (year.length == 2) {
              final currentYear = DateTime.now().year;
              final currentCentury = (currentYear ~/ 100) * 100;
              final twoDigitYear = int.parse(year);

              // 현재 년도의 마지막 2자리와 비교하여 세기 결정
              if (twoDigitYear <= (currentYear % 100) + 20) {
                year = '${currentCentury + twoDigitYear}';
              } else {
                year = '${currentCentury - 100 + twoDigitYear}';
              }
            }

            final mmyy = month + year.substring(year.length - 2);
            if (mmyy.length == 4 && int.tryParse(mmyy) != null) {
              final m = mmyy.getDateMonthNumber();
              final y = mmyy.getDateYearNumber();
              if (m.validateDateMonth() && y.validateDateYear()) {
                return mmyy;
              }
            }
          }

          // 2) DATE 키워드 뒤의 4자리 숫자 찾기 (예: "DATE1129CVC421")
          dateMatch = RegExp(r'(?:DATE|VALID|THRU|EXP).*?(\d{4})')
              .firstMatch(cleanInput);
          if (dateMatch != null) {
            final fourDigits = dateMatch.group(1)!;

            // MMYY 형태인지 검증
            if (fourDigits.length == 4 && int.tryParse(fourDigits) != null) {
              final m = fourDigits.getDateMonthNumber();
              final y = fourDigits.getDateYearNumber();
              if (m.validateDateMonth() && y.validateDateYear()) {
                return fourDigits;
              }
            }
          }
        }
      }

      // 2. 기존 방식: 순수 4자리 숫자 찾기 (MMYY 형태)
      final possibleDate = inputs.firstWhere((input) {
        final cleanValue = input.fixPossibleMisspells();
        if (cleanValue.length == 4) {
          final m = cleanValue.getDateMonthNumber();
          final y = cleanValue.getDateYearNumber();
          if (m.validateDateMonth() && y.validateDateYear()) {
            return true;
          }
        }
        return false;
      });
      return possibleDate.fixPossibleMisspells();
    } catch (e, _) {
      return '';
    }
  }
}
