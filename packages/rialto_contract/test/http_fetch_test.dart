import 'dart:convert';
import 'dart:io';

import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

/// The network fetch of remote sources, against a server on the loopback interface.
void main() {
  final fetch = RemoteSources.fetch;
  final fetchBounded = RemoteSources.fetchBounded;
  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://${server.address.host}:${server.port}');
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/ok':
          response.write('{"openapi": "3.1.0"}');
        case '/missing':
          response.statusCode = HttpStatus.notFound;
          response.write('not here');
        case '/to-http':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '/ok');
        case '/no-location':
          response.statusCode = HttpStatus.movedPermanently;
        case '/large':
          response.headers.contentLength = 1000;
          response.add(List.filled(1000, 32));
        case '/chunked':
          response.bufferOutput = false;
          for (var i = 0; i < 10; i++) {
            response.add(List.filled(100, 32));
            await response.flush();
          }
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('reads the body of a 200 response', () async {
    expect(utf8.decode(await fetch(base.resolve('/ok'))), '{"openapi": "3.1.0"}');
    expect(await fetchBounded(base.resolve('/ok'), 100), hasLength(20));
  });

  test('fails on another status', () async {
    await expectLater(
      fetch(base.resolve('/missing')),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', 'HTTP 404')),
    );
  });

  test('never follows a redirect to http, and fails on a redirect without a location (K4.4)', () async {
    await expectLater(
      fetch(base.resolve('/to-http')),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('does not use https'))),
    );
    await expectLater(
      fetch(base.resolve('/no-location')),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('without a location'))),
    );
  });

  test('a bounded fetch fails on a body longer than its limit, by Content-Length or as it arrives', () async {
    await expectLater(
      fetchBounded(base.resolve('/large'), 999),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('Content-Length 1000'))),
    );
    await expectLater(
      fetchBounded(base.resolve('/chunked'), 250),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', 'larger than 250 bytes')),
    );
    expect(await fetchBounded(base.resolve('/chunked'), 1000), hasLength(1000));
    expect(await fetch(base.resolve('/large')), hasLength(1000));
  });
}
