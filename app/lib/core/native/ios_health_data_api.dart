import 'package:flutter/services.dart';

import 'native_channel_names.dart';

class IosHealthDataApi {
  IosHealthDataApi({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ?? const MethodChannel(NativeChannelNames.healthData);

  final MethodChannel _methodChannel;

  Future<bool> isAvailable() async {
    return await _methodChannel.invokeMethod<bool>('isAvailable') ?? false;
  }

  Future<bool> requestReadPermissions(List<String> metricTypes) async {
    return await _methodChannel.invokeMethod<bool>(
          'requestReadPermissions',
          metricTypes,
        ) ??
        false;
  }

  Future<bool> openAppSettings() async {
    return await _methodChannel.invokeMethod<bool>('openAppSettings') ?? false;
  }

  Future<List<Map<String, Object?>>> readSamples({
    required List<String> metricTypes,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final result = await _methodChannel
        .invokeListMethod<Object?>('readSamples', <String, Object?>{
          'metric_types': metricTypes,
          'start_time_millis': startTime.millisecondsSinceEpoch,
          'end_time_millis': endTime.millisecondsSinceEpoch,
        });

    return (result ?? <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> item) => Map<String, Object?>.from(item))
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> readAggregates({
    required List<String> metricTypes,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final result = await _methodChannel
        .invokeListMethod<Object?>('readAggregates', <String, Object?>{
          'metric_types': metricTypes,
          'start_time_millis': startTime.millisecondsSinceEpoch,
          'end_time_millis': endTime.millisecondsSinceEpoch,
        });

    return (result ?? <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> item) => Map<String, Object?>.from(item))
        .toList(growable: false);
  }
}
