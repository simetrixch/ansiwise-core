import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

void main() {
  group('RequestRefused says what the far side said', () {
    // A status names WHICH door was shut and never why. The far side had already answered the
    // question the reader is about to ask, in one sentence, and a message that drops it leaves them
    // guessing at the one thing that was known. Quoting is safe HERE and only here: the body is
    // redacted before it reaches this failure, which is exactly why AnswerMissing beside it carries
    // no body at all.
    test('carries the answer into the sentence an operator reads', () {
      final RequestRefused refused = RequestRefused(
        method: 'POST',
        url: 'https://idp.example.com/api/v3/core/groups/x/add_user/',
        status: 400,
        body: '{"pk":["This field is required."]}',
      );
      expect(refused.toString(), contains('This field is required.'));
      expect(refused.toString(), contains('400'));
      expect(refused.toString(), contains('POST'));
    });

    test('says an empty body is empty rather than trailing a colon into nothing', () {
      final RequestRefused refused = RequestRefused(
        method: 'GET',
        url: 'https://x.example/y',
        status: 503,
        body: '   ',
      );
      expect(refused.toString(), contains('empty'));
      expect(refused.toString().trimRight(), isNot(endsWith(':')));
    });

    test('a body too long to read is cut and says it was cut', () {
      final String long = 'x' * 5000;
      final RequestRefused refused = RequestRefused(
        method: 'PUT',
        url: 'https://x.example/y',
        status: 500,
        body: long,
      );
      expect(refused.toString().length, lessThan(1000));
      expect(refused.toString(), contains('5000'));
    });
  });
}
