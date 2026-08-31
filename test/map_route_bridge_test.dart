// map_route_bridge_test.dart
//
// SPEC-451 — the Flutter half of the `map_delegate_route` shared fixture.
//
// A thin wrapper FORWARDS, so the only thing this side can prove is that what it forwards is the
// shape the native decoder accepts. That is not a small claim: the map route crosses the channel as
// an untyped map, so a renamed key here compiles, ships, and silently leaves every Flutter host's
// map on its authored route with no error anywhere.
//
// The expected shape is READ FROM THE FIXTURE the iOS and Android runners drive, not restated here.
// An expectation copied into this file could be "fixed" to match a regression without either native
// noticing — which is the whole failure mode the shared fixtures exist to prevent.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

void main() {
  final fixtureFile = File(
    '../sdk-shared-fixtures/config_overrides/map_delegate_route.fixture.json',
  );

  test('MapRoute.toMap() is exactly the bridge shape the native decoder reads', () {
    expect(fixtureFile.existsSync(), isTrue,
        reason: 'shared fixture missing — the bridge contract has nothing to be pinned against');
    final fixture = jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    final expected = (fixture['setup']['session_data']['host_map_routes']
        as Map<String, dynamic>)['delivery_map'] as Map<String, dynamic>;

    final built = MapRoute(
      polyline: expected['polyline'] as String,
      stops: (expected['stops'] as List)
          .map((s) => MapRouteStop(
                lat: (s['lat'] as num).toDouble(),
                lng: (s['lng'] as num).toDouble(),
                title: s['title'] as String?,
              ))
          .toList(),
    ).toMap();

    expect(built, equals(expected));
  });

  test('an empty route sends nothing rather than nulls', () {
    // The native decoder treats "neither a line nor a place" as no route at all and keeps the
    // authored one, which is the right outcome for a routing call that came back empty. Sending
    // explicit nulls would decode as a route with no geometry and blank the map.
    expect(const MapRoute().toMap(), isEmpty);
    expect(const MapRoute(polyline: '').toMap(), isEmpty);
  });

  test('a stop without a title omits the key instead of sending null', () {
    expect(const MapRouteStop(lat: 1.5, lng: 2.5).toMap(), equals({'lat': 1.5, 'lng': 2.5}));
  });
}
