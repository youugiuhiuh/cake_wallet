import 'dart:math';

/// Deterministic seed helper so a plan can be rebuilt / audited from a task id.
int seedFromString(String s) {
  var hash = 0;
  for (final c in s.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return hash;
}

/// Splits [total] into [parts] random positive fractions that sum exactly to
/// [total] (minor units). Works for arbitrarily large BigInt amounts.
List<BigInt> splitAmount(BigInt total, int parts, Random rng) {
  if (parts <= 0 || total <= BigInt.zero) return const [];
  if (parts == 1) return [total];

  final cuts = <BigInt>[];
  for (var i = 0; i < parts - 1; i++) {
    cuts.add(_randomBelow(total, rng));
  }
  cuts.sort();

  final result = <BigInt>[];
  var previous = BigInt.zero;
  for (final cut in cuts) {
    final slice = cut - previous;
    result.add(slice <= BigInt.zero ? BigInt.one : slice);
    previous = cut;
  }
  final tail = total - previous;
  result.add(tail <= BigInt.zero ? BigInt.one : tail);

  // Rebalance so the sum is exactly `total`.
  var diff = result.fold(BigInt.zero, (a, b) => a + b) - total;
  var idx = 0;
  final guard = result.length * 8;
  while (diff != BigInt.zero && idx < guard) {
    final i = idx % result.length;
    if (diff > BigInt.zero && result[i] > BigInt.one) {
      result[i] -= BigInt.one;
      diff -= BigInt.one;
    } else if (diff < BigInt.zero) {
      result[i] += BigInt.one;
      diff += BigInt.one;
    }
    idx++;
  }

  return result;
}

/// A uniform random BigInt in [0, bound).
BigInt _randomBelow(BigInt bound, Random rng) {
  if (bound <= BigInt.zero) return BigInt.zero;
  // 32 random bits at a time is plenty and avoids nextInt range issues.
  var value = BigInt.zero;
  final chunks = (bound.bitLength / 32).ceil();
  for (var i = 0; i < chunks; i++) {
    value = (value << 32) | BigInt.from(rng.nextInt(0xFFFFFFFF));
  }
  return value % bound;
}

/// Generates [count] increasing random delays (in seconds) inside a window of
/// [windowSeconds], leaving room for settlement after the last hop.
List<int> randomDelays(int windowSeconds, int count, Random rng, {double spread = 0.85}) {
  if (count <= 0) return const [];
  final usable = max(1, (windowSeconds * spread).floor());
  final raw = <int>[];
  for (var i = 0; i < count; i++) {
    raw.add(rng.nextInt(usable));
  }
  raw.sort();
  return raw;
}
