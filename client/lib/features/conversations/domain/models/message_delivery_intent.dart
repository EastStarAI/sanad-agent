enum MessageDeliveryIntent {
  auto,
  queue;

  String get wireValue => name;
}
