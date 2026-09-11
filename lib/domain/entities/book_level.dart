/// One price level in the order book.
///
/// A level either exists or it does not — there is no "empty level". An
/// illiquid strike may have nothing resting on a side at all (§3.5 trap 5),
/// and that case is represented by a null [BookLevel] rather than by a level
/// with a zero price. A sentinel would render as "₹0.00", which reads as a
/// real quote at zero rather than as an absent one.
final class BookLevel {
  const BookLevel({
    required this.price,
    required this.quantity,
    required this.orderCount,
  });

  /// Rupees. The broker sends integer paise; the ÷100 happens in the decoder.
  final double price;

  /// Contracts. **Not** scaled — §3.5 trap 1 scales prices only.
  final int quantity;

  final int orderCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookLevel &&
          other.price == price &&
          other.quantity == quantity &&
          other.orderCount == orderCount;

  @override
  int get hashCode => Object.hash(price, quantity, orderCount);

  @override
  String toString() => 'BookLevel($price x $quantity)';
}
