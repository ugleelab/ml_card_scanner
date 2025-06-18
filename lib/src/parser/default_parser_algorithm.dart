import 'package:flutter/foundation.dart';
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
      //debugPrint('getCardNumber: $item => $cleanValue');
      if (cleanValue.length == CardParserConst.cardNumberLength &&
          int.tryParse(cleanValue) != null) {
        return cleanValue;
      }
    }
    return '';
  }

  @override
  String getExpiryDate(List<String> inputs) {
    if (kDebugMode) {
      debugPrint('🗓️ Parsing expiry date from inputs: $inputs');
    }

    try {
      // 1. 먼저 "DATE", "VALID", "THRU", "EXP" 등이 포함된 블록에서 날짜 찾기
      for (final input in inputs) {
        final cleanInput =
            input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9/\-\s]'), '');

        if (kDebugMode) {
          debugPrint('   Checking input: "$input" -> cleaned: "$cleanInput"');
        }

        // "DATE 11/29", "VALID THRU 11/29", "EXP 11/29" 등의 패턴 찾기
        if (cleanInput.contains('DATE') ||
            cleanInput.contains('VALID') ||
            cleanInput.contains('THRU') ||
            cleanInput.contains('EXP')) {
          if (kDebugMode) {
            debugPrint('   ✅ Found date keyword in: "$cleanInput"');
          }

          // 1) MM/YY 또는 MM-YY 패턴 찾기 (예: "DATE 11/29")
          var dateMatch =
              RegExp(r'(\d{1,2})[/\-](\d{2,4})').firstMatch(cleanInput);
          if (dateMatch != null) {
            final month = dateMatch.group(1)!.padLeft(2, '0');
            var year = dateMatch.group(2)!;

            if (kDebugMode) {
              debugPrint(
                  '   🎯 Found date pattern with separator: ${dateMatch.group(0)} (month: $month, year: $year)');
            }

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

              if (kDebugMode) {
                debugPrint('   📅 Converted 2-digit year to 4-digit: $year');
              }
            }

            final mmyy = month + year.substring(year.length - 2);
            if (kDebugMode) {
              debugPrint('   🔄 Generated MMYY format: $mmyy');
            }

            if (mmyy.length == 4 && int.tryParse(mmyy) != null) {
              final m = mmyy.getDateMonthNumber();
              final y = mmyy.getDateYearNumber();
              if (m.validateDateMonth() && y.validateDateYear()) {
                if (kDebugMode) {
                  debugPrint(
                      '   ✅ Valid date found: $mmyy (month: $m, year: $y)');
                }
                return mmyy;
              } else {
                if (kDebugMode) {
                  debugPrint('   ❌ Invalid date: $mmyy (month: $m, year: $y)');
                }
              }
            }
          }

          // 2) DATE 키워드 뒤의 4자리 숫자 찾기 (예: "DATE1129CVC421")
          dateMatch = RegExp(r'(?:DATE|VALID|THRU|EXP).*?(\d{4})')
              .firstMatch(cleanInput);
          if (dateMatch != null) {
            final fourDigits = dateMatch.group(1)!;

            if (kDebugMode) {
              debugPrint(
                  '   🎯 Found 4-digit pattern after keyword: $fourDigits');
            }

            // MMYY 형태인지 검증
            if (fourDigits.length == 4 && int.tryParse(fourDigits) != null) {
              final m = fourDigits.getDateMonthNumber();
              final y = fourDigits.getDateYearNumber();
              if (m.validateDateMonth() && y.validateDateYear()) {
                if (kDebugMode) {
                  debugPrint(
                      '   ✅ Valid MMYY date found: $fourDigits (month: $m, year: $y)');
                }
                return fourDigits;
              } else {
                if (kDebugMode) {
                  debugPrint(
                      '   ❌ Invalid MMYY date: $fourDigits (month: $m, year: $y)');
                }
              }
            }
          }
        }
      }

      if (kDebugMode) {
        debugPrint('   📍 No date keywords found, trying 4-digit pattern...');
      }

      // 2. 기존 방식: 순수 4자리 숫자 찾기 (MMYY 형태)
      final possibleDate = inputs.firstWhere((input) {
        final cleanValue = input.fixPossibleMisspells();
        if (kDebugMode) {
          debugPrint('   Checking 4-digit pattern: "$input" -> "$cleanValue"');
        }
        if (cleanValue.length == 4) {
          final m = cleanValue.getDateMonthNumber();
          final y = cleanValue.getDateYearNumber();
          if (m.validateDateMonth() && y.validateDateYear()) {
            if (kDebugMode) {
              debugPrint('   ✅ Valid 4-digit date: $cleanValue');
            }
            return true;
          }
        }
        return false;
      });
      return possibleDate.fixPossibleMisspells();
    } catch (e, _) {
      if (kDebugMode) {
        debugPrint('   ❌ No valid expiry date found');
      }
      return '';
    }
  }
}
