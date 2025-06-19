class CardParserConst {
  static const int cardNumberLength = 16;
  static const int cardDateLength = 4;
  static const int cardScanTriesCount = 3;

  // 다양한 카드 길이 지원
  static const int minCardNumberLength = 13;
  static const int maxCardNumberLength = 19;

  static const String cardVisa = 'Visa';
  static const String cardMasterCard = 'MasterCard';
  static const String cardAmex = 'American Express';
  static const String cardUnknown = 'Unknown';

  static const String cardVisaParam = '4';
  static const String cardMasterCardParam = '5';
  static const String cardAmexParam = '3';

  const CardParserConst._();
}
