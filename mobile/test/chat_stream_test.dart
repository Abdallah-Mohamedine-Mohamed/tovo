import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/core/api.dart';

class StreamClient extends http.BaseClient {
  StreamClient(this.stream);
  final Stream<List<int>> stream;
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    expect(request.headers['accept'], 'application/x-ndjson');
    return http.StreamedResponse(
      stream,
      200,
      headers: {'content-type': 'application/x-ndjson'},
    );
  }
}

void main() {
  test(
    'montre les résultats avant la fin et reconstruit le texte accentué',
    () async {
      final controller = StreamController<List<int>>();
      final api = TovoApi(
        client: StreamClient(controller.stream),
        tokenProvider: () => null,
      );
      final events = <Map<String, dynamic>>[];
      var done = false;
      final pending = api.chat({'text': 'poulet'}, onEvent: events.add).then((
        value,
      ) {
        done = true;
        return value;
      });
      controller.add(utf8.encode('{"type":"results","components":[]}\n'));
      await Future<void>.delayed(Duration.zero);
      expect(events.single['type'], 'results');
      expect(done, isFalse);
      final bytes = utf8.encode(
        '{"type":"text","text":"Voilà"}\n{"type":"done","status":200,"content":"Voilà","components":[],"conversation_id":"one"}\n',
      );
      for (final byte in bytes) {
        controller.add([byte]);
      }
      await controller.close();
      final response = await pending;
      expect(response.ok, isTrue);
      expect(response.content, 'Voilà');
      expect(response.raw['conversation_id'], 'one');
    },
  );

  test('une coupure de flux ne rejoue pas le message', () async {
    final client = StreamClient(
      Stream.value(utf8.encode('{"type":"text","text":"Un"}\n')),
    );
    final response = await TovoApi(
      client: client,
      tokenProvider: () => null,
    ).chat({}, onEvent: (_) {});
    expect(response.ok, isFalse);
    expect(client.calls, 1);
  });

  test('accepte un ancien serveur JSON et ses erreurs', () async {
    final api = TovoApi(
      tokenProvider: () => null,
      client: MockClient(
        (_) async => http.Response(
          '{"content":"Bonjour","components":[]}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    expect((await api.chat({}, onEvent: (_) {})).content, 'Bonjour');
    final failure = TovoApi(
      tokenProvider: () => null,
      client: MockClient(
        (_) async => http.Response(
          '{"error":"Indisponible"}',
          503,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    expect((await failure.chat({}, onEvent: (_) {})).statusCode, 503);
  });
}
