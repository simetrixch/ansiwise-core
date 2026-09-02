import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

/// Address-range arithmetic, and the one thing it must never do: answer when it cannot tell.
void main() {
  group('what counts as a range', () {
    test('a dotted quad, a slash and a prefix of 0 to 32', () {
      expect(isCidr('10.0.0.0/8'), isTrue);
      expect(isCidr('0.0.0.0/0'), isTrue);
      expect(isCidr('192.168.1.1/32'), isTrue);
    });

    test('anything else is not one', () {
      expect(isCidr('10.0.0.0'), isFalse, reason: 'no prefix');
      expect(isCidr('10.0.0.0/33'), isFalse, reason: 'prefix above 32');
      expect(isCidr('10.0.0.256/8'), isFalse, reason: 'an octet above 255');
      expect(isCidr('10.0.0.01/8'), isFalse, reason: 'a leading zero is another notation');
      expect(isCidr(''), isFalse);
    });
  });

  group('overlap', () {
    test('two ranges sharing an address overlap, in both directions', () {
      expect(cidrOverlap('10.0.0.0/8', '10.1.0.0/16'), isTrue);
      expect(cidrOverlap('10.1.0.0/16', '10.0.0.0/8'), isTrue);
    });

    test('two ranges sharing none do not', () {
      expect(cidrOverlap('10.0.0.0/8', '192.168.0.0/16'), isFalse);
    });

    test('everything overlaps the whole space, where the mask is nothing', () {
      // A 32-bit implementation overflows here and answers the opposite.
      expect(cidrOverlap('0.0.0.0/0', '10.0.0.0/8'), isTrue);
      expect(cidrOverlap('10.0.0.0/8', '0.0.0.0/0'), isTrue);
    });

    test('an address inside a range is contained by it', () {
      expect(cidrContains('10.0.0.0/8', '10.5.6.7'), isTrue);
      expect(cidrContains('10.0.0.0/8', '11.5.6.7'), isFalse);
    });
  });

  group('a range that cannot be read', () {
    // THIS is what the group above is for. Answering "no overlap" for anything it cannot parse lets
    // a step refusing a range that collides with the machine's own network pass on a typo — and the
    // record then shows a check that had run and found nothing.
    test('refuses rather than reporting no overlap, and names the value it could not read', () {
      expect(
        () => cidrOverlap('10.0.0.0/8', 'not-a-range'),
        throwsA(
          isA<FormatException>().having(
            (FormatException refused) => refused.source,
            'the unreadable value',
            'not-a-range',
          ),
        ),
      );
    });

    test('refuses whichever side is unreadable, not only the second', () {
      expect(
        () => cidrOverlap('nonsense', '10.0.0.0/8'),
        throwsA(
          isA<FormatException>().having(
            (FormatException refused) => refused.source,
            'the unreadable value',
            'nonsense',
          ),
        ),
      );
    });

    test('containment refuses on an address that is not one', () {
      // The caller that made this matter reads pod addresses off a cluster and asks whether each is
      // inside the range. An answer of "not inside" for an address nobody could read is a decision
      // made about a value nothing understood.
      expect(() => cidrContains('10.0.0.0/8', 'pending'), throwsA(isA<FormatException>()));
    });

    test('the innocent neighbour: a readable pair still answers', () {
      // Without this, a refusal on everything would pass the three tests above and be just as wrong.
      expect(cidrContains('10.0.0.0/8', '10.0.0.1'), isTrue);
    });
  });
}
