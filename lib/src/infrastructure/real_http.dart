import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/http.dart';

/// Sends a request over the network.
///
/// A status the caller did not want is not an error here. It comes back as [HttpAnswer.status], and
/// what it means is the step's business — a `404` is a failure to one step and the answer another
/// one was checking for. What does throw is a request that could not be sent at all, and a request
/// that ran past its deadline.
final class RealHttp implements Http {
  /// Creates the network port a real run is given.
  const RealHttp();

  @override
  Future<HttpAnswer> send(HttpRequest request) async {
    final Duration? timeout = request.timeout;
    final HttpClient client = HttpClient();
    // Two deadlines from the same value. The client's own timeout covers opening the connection,
    // which is the part that hangs when the address answers nothing at all; the one on the whole
    // exchange covers a server that connects and then never finishes its answer.
    if (timeout != null) {
      client.connectionTimeout = timeout;
    }
    // Only when the request itself asked. The callback is what dart:io offers in place of a flag,
    // and returning true from it accepts the certificate the check rejected — so it is installed
    // for that one exchange and for no other, which is the whole of the guarantee the field makes.
    if (request.acceptsAnyCertificate) {
      client.badCertificateCallback = (X509Certificate certificate, String host, int port) => true;
    }
    // The URL is still parsed below and still supplies the request path and the Host header; only
    // where the connection goes changes. The port number passed to startConnect is meaningless for
    // a unix socket and is not what selects it — the address's type is.
    final String? socketPath = request.socketPath;
    if (socketPath != null) {
      client.connectionFactory = (Uri url, String? proxyHost, int? proxyPort) =>
          Socket.startConnect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    }

    final Stopwatch watch = Stopwatch()..start();
    try {
      final Future<HttpAnswer> exchange = _exchange(client, request, watch);
      if (timeout == null) {
        return await exchange;
      }
      try {
        return await exchange.timeout(timeout);
      } on TimeoutException {
        // The exchange itself is abandoned, and closing the client below makes it fail. Silencing
        // it here keeps that failure from surfacing later as an error nobody is waiting for.
        exchange.ignore();
        rethrow;
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpAnswer> _exchange(HttpClient client, HttpRequest request, Stopwatch watch) async {
    final HttpClientRequest sending = await client.openUrl(request.method, Uri.parse(request.url));
    for (final MapEntry<String, String> header in request.headers.entries) {
      sending.headers.set(header.key, header.value);
    }
    final String? body = request.body;
    if (body != null) {
      sending.add(utf8.encode(body));
    }

    final HttpClientResponse response = await sending.close();
    final String text = await response.transform(_decoder).join();
    watch.stop();

    return HttpAnswer(
      status: response.statusCode,
      body: text,
      headers: _headersOf(response),
      elapsed: watch.elapsed,
    );
  }

  /// Malformed bytes become the replacement character instead of throwing, for the same reason they
  /// do in a command's output: the answer arrived, and one bad byte in it is not worth losing it.
  static const Utf8Decoder _decoder = Utf8Decoder(allowMalformed: true);

  Map<String, String> _headersOf(HttpClientResponse response) {
    final Map<String, String> headers = <String, String>{};
    // A header may be sent more than once. The values are joined by comma, which is what the header
    // syntax means by repeating one, so a caller reading the map is not handed only the last.
    response.headers.forEach((String name, List<String> values) {
      headers[name] = values.join(', ');
    });
    return headers;
  }
}
