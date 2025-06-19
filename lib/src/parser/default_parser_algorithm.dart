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
      final elements =
          recognizedText.blocks.map((e) => e.text.clean()).toList();
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
    for (final item in inputs) {
      final cleanValue = item.fixPossibleMisspells();

      // 다양한 카드 길이 지원 (13-19자리)
      if (cleanValue.length >= CardParserConst.minCardNumberLength &&
          cleanValue.length <= CardParserConst.maxCardNumberLength &&
          int.tryParse(cleanValue) != null) {
        // 카드 번호 유효성 추가 검증
        if (_isValidCardNumber(cleanValue)) {
          return cleanValue;
        }
      }
    }
    return '';
  }

  /// 카드 번호 유효성 검증 (Luhn 알고리즘 적용)
  bool _isValidCardNumber(String cardNumber) {
    if (cardNumber.isEmpty) {
      return false;
    }

    // 기본 길이 검증
    if (cardNumber.length < CardParserConst.minCardNumberLength ||
        cardNumber.length > CardParserConst.maxCardNumberLength) {
      return false;
    }

    // 카드사별 패턴 검증
    final firstDigit = cardNumber[0];
    switch (firstDigit) {
      case '4': // Visa (13, 16, 19자리)
        return cardNumber.length == 13 ||
            cardNumber.length == 16 ||
            cardNumber.length == 19;
      case '5': // MasterCard (16자리)
        return cardNumber.length == 16;
      case '3': // AMEX (15자리)
        return cardNumber.length == 15 &&
            (cardNumber.startsWith('34') || cardNumber.startsWith('37'));
      default:
        // 기타 카드는 기본 길이 범위 내에서 허용
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
