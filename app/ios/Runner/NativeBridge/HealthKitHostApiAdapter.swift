import Flutter
import Foundation
import HealthKit

final class HealthKitHostApiAdapter: NSObject {
  private let healthStore = HKHealthStore()

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.gemmalocal.native/health_data",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(HKHealthStore.isHealthDataAvailable())
    case "requestReadPermissions":
      requestReadPermissions(call.arguments, result: result)
    case "readSamples":
      readSamples(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestReadPermissions(_ arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(false)
      return
    }

    let metricTypes = arguments as? [String] ?? []
    let unsupported = metricTypes.filter { healthKitType(for: $0) == nil }
    guard unsupported.isEmpty else {
      result(nativeFlutterError(.unknown, message: "Unsupported Apple Health metrics: \(unsupported.joined(separator: ", "))"))
      return
    }

    let readTypes = Set(metricTypes.compactMap(healthKitType(for:)))

    healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
      if let error {
        DispatchQueue.main.async {
          result(nativeFlutterError(.nativePermissionDenied, message: error.localizedDescription))
        }
        return
      }
      DispatchQueue.main.async {
        result(success)
      }
    }
  }

  private func readSamples(_ arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(nativeFlutterError(.modelUnsupportedDevice, message: "HealthKit is not available on this device."))
      return
    }
    guard let payload = arguments as? [String: Any],
          let metricTypes = payload["metric_types"] as? [String],
          let startMillis = millisValue(payload["start_time_millis"]),
          let endMillis = millisValue(payload["end_time_millis"]) else {
      result(nativeFlutterError(.unknown, message: "Invalid HealthKit sample request."))
      return
    }

    let unsupported = metricTypes.filter { healthKitType(for: $0) == nil }
    guard unsupported.isEmpty else {
      result(nativeFlutterError(.unknown, message: "Unsupported Apple Health metrics: \(unsupported.joined(separator: ", "))"))
      return
    }
    guard endMillis > startMillis else {
      result(nativeFlutterError(.unknown, message: "End time must be after start time."))
      return
    }

    let startDate = Date(timeIntervalSince1970: TimeInterval(startMillis) / 1000.0)
    let endDate = Date(timeIntervalSince1970: TimeInterval(endMillis) / 1000.0)
    let predicate = HKQuery.predicateForSamples(
      withStart: startDate,
      end: endDate,
      options: []
    )
    let sortDescriptors = [
      NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
    ]
    let group = DispatchGroup()
    let lock = NSLock()
    var output = [[String: Any]]()
    var firstError: FlutterError?

    for metricType in Set(metricTypes) {
      guard let sampleType = healthKitType(for: metricType) as? HKSampleType else {
        continue
      }
      group.enter()
      let query = HKSampleQuery(
        sampleType: sampleType,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: sortDescriptors
      ) { [weak self] _, samples, error in
        defer { group.leave() }
        if let error {
          lock.lock()
          if firstError == nil {
            firstError = nativeFlutterError(.modelRuntimeInternal, message: error.localizedDescription)
          }
          lock.unlock()
          return
        }
        let mapped = (samples ?? []).compactMap { sample in
          self?.mapSample(sample, metricType: metricType)
        }
        lock.lock()
        output.append(contentsOf: mapped)
        lock.unlock()
      }
      healthStore.execute(query)
    }

    group.notify(queue: .main) {
      if let firstError {
        result(firstError)
        return
      }
      let sorted = output.sorted {
        let left = $0["start_time_millis"] as? Int64 ?? 0
        let right = $1["start_time_millis"] as? Int64 ?? 0
        return left < right
      }
      result(sorted)
    }
  }

  private func healthKitType(for metricType: String) -> HKObjectType? {
    switch metricType {
    case "steps":
      return HKObjectType.quantityType(forIdentifier: .stepCount)
    case "heartRate":
      return HKObjectType.quantityType(forIdentifier: .heartRate)
    case "sleepSession":
      return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    default:
      return nil
    }
  }

  private func millisValue(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber {
      return number.int64Value
    }
    if let value = value as? Int {
      return Int64(value)
    }
    if let value = value as? Int64 {
      return value
    }
    return nil
  }

  private func mapSample(_ sample: HKSample, metricType: String) -> [String: Any]? {
    if let sample = sample as? HKQuantitySample {
      return mapQuantitySample(sample, metricType: metricType)
    }
    if let sample = sample as? HKCategorySample {
      return mapCategorySample(sample, metricType: metricType)
    }
    return nil
  }

  private func mapQuantitySample(_ sample: HKQuantitySample, metricType: String) -> [String: Any]? {
    guard let unit = quantityUnit(for: metricType) else {
      return nil
    }
    let value = sample.quantity.doubleValue(for: unit)
    return baseSampleMap(
      sample,
      metricType: metricType,
      numericValue: value,
      unit: unitName(for: metricType)
    )
  }

  private func mapCategorySample(_ sample: HKCategorySample, metricType: String) -> [String: Any]? {
    let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
    guard metricType == "sleepSession" else {
      return nil
    }
    return baseSampleMap(
      sample,
      metricType: metricType,
      numericValue: durationSeconds / 3600.0,
      unit: "hour"
    )
  }

  private func baseSampleMap(
    _ sample: HKSample,
    metricType: String,
    numericValue: Double?,
    unit: String
  ) -> [String: Any] {
    var payload: [String: Any] = [
      "type": metricType,
      "unit": unit,
      "start_time_millis": Int64(sample.startDate.timeIntervalSince1970 * 1000),
      "end_time_millis": Int64(sample.endDate.timeIntervalSince1970 * 1000)
    ]
    if let numericValue {
      payload["numeric_value"] = numericValue
    }
    return payload
  }

  private func quantityUnit(for metricType: String) -> HKUnit? {
    switch metricType {
    case "steps":
      return .count()
    case "heartRate":
      return HKUnit.count().unitDivided(by: .minute())
    default:
      return nil
    }
  }

  private func unitName(for metricType: String) -> String {
    switch metricType {
    case "steps":
      return "count"
    case "heartRate":
      return "bpm"
    default:
      return ""
    }
  }
}
