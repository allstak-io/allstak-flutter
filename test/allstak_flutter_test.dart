import 'package:flutter_test/flutter_test.dart';
import 'package:allstak_flutter/allstak_flutter.dart';

void main() {
  test('AllStakConfig defaults to api.allstak.sa', () {
    const config = AllStakConfig(apiKey: 'ask_test');
    expect(config.host, 'https://api.allstak.sa');
    expect(config.apiKey, 'ask_test');
    expect(config.service, 'flutter');
  });

  test('AllStakConfig respects overrides', () {
    const config = AllStakConfig(
      apiKey: 'ask_test',
      host: 'http://localhost:8080',
      environment: 'test',
      release: 'v1.2.3',
    );
    expect(config.host, 'http://localhost:8080');
    expect(config.environment, 'test');
    expect(config.release, 'v1.2.3');
  });
}
