import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

/// The shapes a declared value may be held to, and what each of them refuses.
///
/// Every case here is a value somebody could really write. A shape check earns nothing by refusing
/// nonsense; what it is for is the value that looks right and is not.
void main() {
  group('hostname', () {
    test('a name of two labels or more is one', () {
      expect(ValueShape.hostname.holds('example.com'), isTrue);
      expect(ValueShape.hostname.holds('m1.example.com'), isTrue);
      expect(ValueShape.hostname.holds('a-b.c-d.example.com'), isTrue);
    });

    test('capitals are a hostname, because the standard says a name is case-insensitive', () {
      expect(ValueShape.hostname.holds('M1.Example.COM'), isTrue);
    });

    test('a single label is not one, because nothing outside a machine resolves it', () {
      expect(ValueShape.hostname.holds('localhost'), isFalse);
      expect(ValueShape.hostname.holds('example'), isFalse);
    });

    test('a label that begins or ends with a hyphen is not one', () {
      // A pattern that admits a leading or a trailing hyphen admits `-.-` outright — a check that
      // accepts that reads as a guarantee it does not give.
      expect(ValueShape.hostname.holds('-.-'), isFalse);
      expect(ValueShape.hostname.holds('-bad.example.com'), isFalse);
      expect(ValueShape.hostname.holds('bad-.example.com'), isFalse);
    });

    test('a last label of digits is not one, because that is an address written oddly', () {
      expect(ValueShape.hostname.holds('1.2'), isFalse);
      expect(ValueShape.hostname.holds('10.0.0.1'), isFalse);
    });

    test('a space, an at sign or a slash is not part of a name', () {
      expect(ValueShape.hostname.holds('two words.example.com'), isFalse);
      expect(ValueShape.hostname.holds('a@example.com'), isFalse);
      expect(ValueShape.hostname.holds('example.com/path'), isFalse);
    });
  });

  group('mailbox', () {
    test('a local part, an at sign and a resolvable domain is one', () {
      expect(ValueShape.mailbox.holds('somebody@example.com'), isTrue);
      expect(ValueShape.mailbox.holds('first.last+tag@mail.example.com'), isTrue);
    });

    test('a space anywhere is not a mailbox', () {
      // The LOCAL part is where a space slips through a loosely anchored pattern, so both halves
      // are probed.
      expect(ValueShape.mailbox.holds('two words@example.com'), isFalse);
      expect(ValueShape.mailbox.holds('somebody@exa mple.com'), isFalse);
    });

    test('an empty half is not a mailbox', () {
      expect(ValueShape.mailbox.holds('@example.com'), isFalse);
      expect(ValueShape.mailbox.holds('somebody@'), isFalse);
    });

    test('a domain that is not a hostname is not a mailbox', () {
      expect(ValueShape.mailbox.holds('somebody@localhost'), isFalse);
      expect(ValueShape.mailbox.holds('somebody@-.-'), isFalse);
    });
  });

  group('the set of shapes', () {
    test('a name is looked up, and an unknown one answers null rather than throwing', () {
      // Null is what the LOADER needs: it refuses a program file naming a shape nothing implements,
      // and that refusal reads better than a stack trace. Everything past the loader holds a shape
      // rather than a name, so the question cannot be asked again later.
      expect(ValueShape.named('hostname'), ValueShape.hostname);
      expect(ValueShape.named('mailbox'), ValueShape.mailbox);
      expect(ValueShape.named('Hostname'), isNull);
      expect(ValueShape.named('ipv4'), isNull);
    });

    test('the names are the enum, so a refusal that lists them cannot go stale', () {
      expect(ValueShape.allWritten, <String>['hostname', 'mailbox']);
      expect(ValueShape.allWritten.length, ValueShape.values.length);
    });
  });
}
