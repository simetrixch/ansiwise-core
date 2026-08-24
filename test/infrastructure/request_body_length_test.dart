/// What a request body is sent AS, and why the encoding is not a detail of the transport.
///
///   dart test test/infrastructure/request_body_length_test.dart
///
/// A client that has not stated how long a body is sends it with `transfer-encoding: chunked`. Some
/// servers read that and some do not, and one that does not sees an EMPTY body — which it answers
/// as a request missing the fields it requires. Nothing in that answer mentions an encoding, so what
/// an operator reads is a refusal about the thing they were trying to do.
///
/// MEASURED, on one identity provider reached through this platform's own ingress: the same address,
/// the same credential and the same eight bytes answered 204 with a length and 400 chunked. It had
/// gone unnoticed for as long as it existed because the other tools this framework drives do read a
/// chunked body — so exactly one of them failed, and it looked like that tool's own refusal.
///
/// THE SERVER HERE IS REAL AND SO IS ITS REFUSAL. It reads the request the way the far side reads
/// it, and refuses a chunked body the way that provider does. Nothing in this file inspects the
/// client: what is asserted is what ARRIVED.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

void main() {
  late io.HttpServer server;
  late String address;
  late List<String> received;
  late List<String?> lengths;
  late List<String?> encodings;

  setUp(() async {
    received = <String>[];
    lengths = <String?>[];
    encodings = <String?>[];
    server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}/api/v3/core/groups/x/add_user/';
    server.listen((io.HttpRequest request) async {
      final String body = await utf8.decoder.bind(request).join();
      received.add(body);
      lengths.add(request.headers.value('content-length'));
      encodings.add(request.headers.value('transfer-encoding'));
      // The far side, as it really behaves: a body it was told the length of is read, and one it
      // was not is refused with a message about the fields it did not find.
      if (request.headers.value('content-length') == null) {
        request.response
          ..statusCode = 400
          ..write('{"pk":["This field is required."]}');
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  test('a body is sent with its length, so a server that reads no chunked body reads it', () async {
    final HttpAnswer answer = await const RealHttp().send(
      HttpRequest(
        'POST',
        address,
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{'pk': 6}),
        timeout: const Duration(seconds: 5),
      ),
    );

    expect(answer.status, 204, reason: 'the far side found the fields it requires');
    expect(received.single, '{"pk":6}');
    expect(lengths.single, '8', reason: 'the length is stated, and it is the length of the bytes');
    expect(
      encodings.single,
      isNull,
      reason: 'a body whose length is known is not chunked, and a server may read either',
    );
  });

  test('a body of characters outside ASCII states the length in BYTES, not in characters', () async {
    // The half a length taken from the string would get wrong. A refusal composed by the far side
    // is read by a person, so these values travel, and a length two bytes short truncates the body
    // into something that no longer parses — which the server reports as malformed input.
    const String text = 'für';
    final HttpAnswer answer = await const RealHttp().send(
      HttpRequest(
        'POST',
        address,
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{'name': text}),
        timeout: const Duration(seconds: 5),
      ),
    );

    expect(answer.status, 204);
    expect(jsonDecode(received.single), <String, Object?>{'name': text});
    expect(lengths.single, '${utf8.encode(jsonEncode(<String, Object?>{'name': text})).length}');
  });

  test('a request carrying no body states no length at all', () async {
    // THE INNOCENT CASE. A length of zero on a request that has no body is a different claim from
    // no length, and some servers treat the two differently — so a fix for the case above must not
    // start stating one where there is nothing to state.
    await const RealHttp().send(HttpRequest('GET', address, timeout: const Duration(seconds: 5)));

    expect(received.single, isEmpty);
    expect(lengths.single, isNull);
  });
}
