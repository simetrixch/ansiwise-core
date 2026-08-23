/// What a certificate the client cannot verify costs, and the one way a request may go on anyway.
///
///   dart test test/infrastructure/accepts_any_certificate_test.dart
///
/// TWO CASES THAT FAIL IN OPPOSITE DIRECTIONS, which is the point of holding them together. Take
/// the check away and the first goes red; make the exception unconditional and the second one has
/// nothing left to prove, because every request would already be accepting anything. Neither can be
/// satisfied by the other, so no single edit makes both green without the behaviour being right.
///
/// THE SERVER IS REAL AND SO IS THE REFUSAL. It listens on loopback with a self-signed certificate,
/// and what rejects it is the TLS handshake itself rather than anything this framework wrote. That
/// is deliberate: the defect this guards against is an installation waiting out its whole window in
/// front of a service that is running and answering, and it appears only when a real client meets a
/// real certificate.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'self_signed_localhost.dart';

void main() {
  group('a certificate the client cannot verify', () {
    late io.HttpServer server;
    late String address;

    setUp(() async {
      final io.SecurityContext context = io.SecurityContext()
        ..useCertificateChainBytes(utf8.encode(selfSignedCertificate))
        ..usePrivateKeyBytes(utf8.encode(selfSignedKey));
      server = await io.HttpServer.bindSecure(io.InternetAddress.loopbackIPv4, 0, context);
      address = 'https://localhost:${server.port}/v1/sys/init';
      server.listen((io.HttpRequest request) {
        request.response
          ..headers.contentType = io.ContentType.json
          ..write('{"initialized": false}');
        unawaited(request.response.close());
      });
    });

    tearDown(() async => server.close(force: true));

    test('ends the exchange, and the reason says what could not be established', () async {
      await expectLater(
        const RealHttp().send(HttpRequest('GET', address)),
        throwsA(isA<io.HandshakeException>()),
        reason:
            'a request that said nothing about certificates must not accept one it cannot verify — '
            'the whole meaning of the default is that the address is who it claims to be',
      );
    });

    test('is accepted where the request asked for it, and the answer comes back whole', () async {
      final HttpAnswer answer = await const RealHttp().send(
        HttpRequest('GET', address, acceptsAnyCertificate: true),
      );

      expect(answer.status, 200);
      expect(
        answer.body,
        contains('"initialized"'),
        reason:
            'accepting the certificate gives up the proof of WHO answered and nothing else: the '
            'body is read exactly as it would be over a verified connection, because that body is '
            'the only thing a readiness wait was ever asking for',
      );
    });
  });
}
