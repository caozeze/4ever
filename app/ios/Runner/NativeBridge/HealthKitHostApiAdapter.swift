import Flutter
import Foundation
import HealthKit
import UIKit

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
    case "openAppSettings":
      openAppSettings(result: result)
    case "readAggregates":
      readAggregates(call.arguments, result: result)
    case "readSamples":
      readSamples(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestReadPermissions(_ arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      NSLog("[AgentTrace] event=health_permission_result status=unavailable")
      result(false)
      return
    }

    let metricTypes = arguments as? [String] ?? []
    NSLog("[AgentTrace] event=health_permission_request metric_names=%@", metricTypes.joined(separator: ","))
    let unsupported = metricTypes.filter { healthKitType(for: $0) == nil }
    guard unsupported.isEmpty else {
      NSLog("[AgentTrace] event=health_permission_result status=invalid_request metric_names=%@", unsupported.joined(separator: ","))
      result(nativeFlutterError(.unknown, message: "Unsupported Apple Health metrics: \(unsupported.joined(separator: ", "))"))
      return
    }

    let readTypes = Set(metricTypes.compactMap(healthKitType(for:)))

    healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
      if let error {
        DispatchQueue.main.async {
          NSLog("[AgentTrace] event=health_permission_result status=permission_denied metric_names=%@", metricTypes.joined(separator: ","))
          result(nativeFlutterError(.nativePermissionDenied, message: error.localizedDescription))
        }
        return
      }
      DispatchQueue.main.async {
        NSLog("[AgentTrace] event=health_permission_result status=%@ metric_names=%@", success ? "ok" : "permission_denied", metricTypes.joined(separator: ","))
        result(success)
      }
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
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
    NSLog("[AgentTrace] event=health_samples_read_start metric_names=%@", metricTypes.joined(separator: ","))
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
        NSLog("[AgentTrace] event=health_samples_read_finish status=read_failed metric_names=%@", metricTypes.joined(separator: ","))
        result(firstError)
        return
      }
      let sorted = output.sorted {
        let left = $0["start_time_millis"] as? Int64 ?? 0
        let right = $1["start_time_millis"] as? Int64 ?? 0
        return left < right
      }
      NSLog("[AgentTrace] event=health_samples_read_finish status=ok metric_names=%@ sample_count=%d", metricTypes.joined(separator: ","), sorted.count)
      result(sorted)
    }
  }

  private func readAggregates(_ arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(nativeFlutterError(.modelUnsupportedDevice, message: "HealthKit is not available on this device."))
      return
    }
    guard let payload = arguments as? [String: Any],
          let metricTypes = payload["metric_types"] as? [String],
          let startMillis = millisValue(payload["start_time_millis"]),
          let endMillis = millisValue(payload["end_time_millis"]) else {
      result(nativeFlutterError(.unknown, message: "Invalid HealthKit aggregate request."))
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
      options: [.strictStartDate]
    )
    let uniqueMetricTypes = Array(Set(metricTypes)).sorted()
    NSLog("[AgentTrace] event=health_aggregate_read_start metric_names=%@", uniqueMetricTypes.joined(separator: ","))

    let group = DispatchGroup()
    let lock = NSLock()
    var output = [[String: Any]]()

    for metricType in uniqueMetricTypes {
      group.enter()
      readAggregate(
        metricType: metricType,
        predicate: predicate,
        startDate: startDate,
        endDate: endDate
      ) { aggregate, error in
        defer { group.leave() }
        if let error {
          NSLog(
            "[AgentTrace] event=health_aggregate_read_finish metric_names=%@ status=read_failed error_code=%@ error_detail=%@",
            metricType,
            error.code,
            error.message ?? ""
          )
          return
        }
        lock.lock()
        if let aggregate {
          output.append(aggregate)
          let sampleCount = aggregate["sample_count"] as? Int ?? 0
          NSLog("[AgentTrace] event=health_aggregate_read_finish metric_names=%@ status=ok sample_count=%d", metricType, sampleCount)
        } else {
          NSLog("[AgentTrace] event=health_aggregate_read_finish metric_names=%@ status=no_data sample_count=0", metricType)
        }
        lock.unlock()
      }
    }

    group.notify(queue: .main) {
      result(output)
    }
  }

  private func readAggregate(
    metricType: String,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    switch metricType {
    case "steps":
      readCumulativeQuantityAggregate(
        metricType: metricType,
        identifier: .stepCount,
        unit: .count(),
        unitName: "count",
        predicate: predicate,
        completion: completion
      )
    case "activeEnergy":
      readCumulativeQuantityAggregate(
        metricType: metricType,
        identifier: .activeEnergyBurned,
        unit: .kilocalorie(),
        unitName: "kcal",
        predicate: predicate,
        completion: completion
      )
    case "heartRate":
      readDiscreteQuantityAggregate(
        metricType: metricType,
        identifier: .heartRate,
        unit: HKUnit.count().unitDivided(by: .minute()),
        unitName: "bpm",
        predicate: predicate,
        completion: completion
      )
    case "hrv":
      readDiscreteQuantityAggregate(
        metricType: metricType,
        identifier: .heartRateVariabilitySDNN,
        unit: HKUnit.secondUnit(with: .milli),
        unitName: "ms",
        predicate: predicate,
        completion: completion
      )
    case "sleepSession":
      readSleepAggregate(
        metricType: metricType,
        predicate: predicate,
        startDate: startDate,
        endDate: endDate,
        completion: completion
      )
    default:
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health metric: \(metricType)"))
    }
  }

  private func readCumulativeQuantityAggregate(
    metricType: String,
    identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    unitName: String,
    predicate: NSPredicate,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health quantity: \(metricType)"))
      return
    }
    let query = HKStatisticsQuery(
      quantityType: quantityType,
      quantitySamplePredicate: predicate,
      options: .cumulativeSum
    ) { _, statistics, error in
      if let error {
        if self.isNoDataError(error) {
          completion(nil, nil)
          return
        }
        completion(nil, nativeFlutterError(.modelRuntimeInternal, message: self.errorDescription(error)))
        return
      }
      guard let quantity = statistics?.sumQuantity() else {
        completion(nil, nil)
        return
      }
      let value = quantity.doubleValue(for: unit)
      guard value > 0 else {
        completion(nil, nil)
        return
      }
      completion([
        "type": metricType,
        "value": value,
        "unit": unitName,
        "sample_count": 1
      ], nil)
    }
    healthStore.execute(query)
  }

  private func readDiscreteQuantityAggregate(
    metricType: String,
    identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    unitName: String,
    predicate: NSPredicate,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health quantity: \(metricType)"))
      return
    }
    let query = HKStatisticsQuery(
      quantityType: quantityType,
      quantitySamplePredicate: predicate,
      options: [.discreteAverage, .discreteMin, .discreteMax]
    ) { _, statistics, error in
      if let error {
        if self.isNoDataError(error) {
          completion(nil, nil)
          return
        }
        completion(nil, nativeFlutterError(.modelRuntimeInternal, message: self.errorDescription(error)))
        return
      }
      guard let average = statistics?.averageQuantity() else {
        completion(nil, nil)
        return
      }
      var payload: [String: Any] = [
        "type": metricType,
        "average": average.doubleValue(for: unit),
        "unit": unitName,
        "sample_count": 1
      ]
      if let min = statistics?.minimumQuantity() {
        payload["min"] = min.doubleValue(for: unit)
      }
      if let max = statistics?.maximumQuantity() {
        payload["max"] = max.doubleValue(for: unit)
      }
      completion(payload, nil)
    }
    healthStore.execute(query)
  }

  private func readSleepAggregate(
    metricType: String,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health category: \(metricType)"))
      return
    }
    let sortDescriptors = [
      NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
    ]
    let query = HKSampleQuery(
      sampleType: sleepType,
      predicate: predicate,
      limit: HKObjectQueryNoLimit,
      sortDescriptors: sortDescriptors
    ) { [weak self] _, samples, error in
      if let error {
        if self?.isNoDataError(error) == true {
          completion(nil, nil)
          return
        }
        completion(nil, nativeFlutterError(.modelRuntimeInternal, message: self?.errorDescription(error) ?? "unknown#0"))
        return
      }
      let asleepIntervals = (samples ?? [])
        .compactMap { $0 as? HKCategorySample }
        .filter { self?.isAsleepSleepAnalysisValue($0.value) == true }
        .compactMap { sample -> (Date, Date)? in
          let start = max(sample.startDate, startDate)
          let end = min(sample.endDate, endDate)
          return end > start ? (start, end) : nil
        }
      let hours = self?.mergedDurationHours(asleepIntervals) ?? 0
      guard hours > 0 else {
        completion(nil, nil)
        return
      }
      completion([
        "type": metricType,
        "value": hours,
        "unit": "hour",
        "sample_count": asleepIntervals.count
      ], nil)
    }
    healthStore.execute(query)
  }

  private func isAsleepSleepAnalysisValue(_ value: Int) -> Bool {
    if value == HKCategoryValueSleepAnalysis.asleep.rawValue {
      return true
    }
    if #available(iOS 16.0, *) {
      return value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
        || value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        || value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
        || value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
    }
    return false
  }

  private func mergedDurationHours(_ intervals: [(Date, Date)]) -> Double {
    let sorted = intervals.sorted { left, right in
      left.0 < right.0
    }
    var merged = [(Date, Date)]()
    for interval in sorted {
      guard let last = merged.last else {
        merged.append(interval)
        continue
      }
      if interval.0 <= last.1 {
        merged[merged.count - 1] = (last.0, max(last.1, interval.1))
      } else {
        merged.append(interval)
      }
    }
    let seconds = merged.reduce(0.0) { total, interval in
      total + interval.1.timeIntervalSince(interval.0)
    }
    return seconds / 3600.0
  }

  private func errorDescription(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
  }

  private func isNoDataError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == HKError.errorDomain
      && nsError.code == HKError.Code.errorNoData.rawValue
  }

  private func healthKitType(for metricType: String) -> HKObjectType? {
    switch metricType {
    case "steps":
      return HKObjectType.quantityType(forIdentifier: .stepCount)
    case "heartRate":
      return HKObjectType.quantityType(forIdentifier: .heartRate)
    case "hrv":
      return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    case "sleepSession":
      return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    case "activeEnergy":
      return HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
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
    case "hrv":
      return HKUnit.secondUnit(with: .milli)
    case "activeEnergy":
      return .kilocalorie()
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
    case "hrv":
      return "ms"
    case "activeEnergy":
      return "kcal"
    default:
      return ""
    }
  }
}
