import 'package:ml_card_scanner/src/parser/card_parser_const.dart';

class CardInfo {
  final String number;
  final String type;
  final String expiry;

  const CardInfo({
    required this.number,
    required this.type,
    required this.expiry,
  });

  factory CardInfo.fromJson(Map<String, dynamic> json) => CardInfo(
        number: json['number'],
        type: json['type'],
        expiry: json['expiry'],
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        'type': type,
        'expiry': expiry,
      };

  bool isValid() =>
      number.isNotEmpty &&
      number.length >= CardParserConst.minCardNumberLength &&
      number.length <= CardParserConst.maxCardNumberLength;

  @override
  String toString() {
    return 'Card Info\nnumber: $number\ntype: $type\nexpiry: $expiry';
  }

  String numberFormatted() {
    if (number.isEmpty ||
        number.length < CardParserConst.minCardNumberLength ||
        number.length > CardParserConst.maxCardNumberLength) {
      return '';
    }

    final buffer = StringBuffer();

    // AMEX 카드 (15자리): 4-6-5 형태
    if (number.length == 15 && number.startsWith('3')) {
      buffer.write('${number.substring(0, 4)} ');
      buffer.write('${number.substring(4, 10)} ');
      buffer.write('${number.substring(10, 15)}');
    }
    // 일반 카드 (13-14자리, 16-19자리): 4자리씩 구분
    else {
      for (int i = 0; i < number.length; i += 4) {
        final endIndex = (i + 4 <= number.length) ? i + 4 : number.length;
        final sub = number.substring(i, endIndex);
        buffer.write('$sub');
        if (endIndex < number.length) {
          buffer.write(' ');
        }
      }
    }

    return buffer.toString();
  }
}
