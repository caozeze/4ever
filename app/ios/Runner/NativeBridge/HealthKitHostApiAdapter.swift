import Flutter
import Foundation
import HealthKit
import UIKit

final class HealthKitHostApiAdapter: NSObject {
  private let healthStore = HKHealthStore()

  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(
      name: "com.gemmalocal.native/health_data",
      binaryMessenger: messenger
    ).setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(HKHealthStore.isHealthDataAvailable())
    case "requestAllReadPermissions":
      requestAllReadPermissions(result: result)
    case "openAppSettings":
      openAppSettings(result: result)
    case "readAggregates":
      readAggregates(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestAllReadPermissions(result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      NSLog("[AgentTrace] event=health_permission_result status=unavailable")
      result(false)
      return
    }

    let readTypes = HealthKitTypeRegistry.allReadTypes()
    let groupNames = HealthKitTypeRegistry.groupNames.joined(separator: ",")
    NSLog("[AgentTrace] event=health_permission_request metric_names=%@ type_count=%d", groupNames, readTypes.count)
    healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { status, _ in
      NSLog("[AgentTrace] event=health_permission_request_status status=%@ metric_names=%@", self.requestStatusName(status), groupNames)
    }
    healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
      DispatchQueue.main.async {
        if let error {
          NSLog("[AgentTrace] event=health_permission_result status=permission_denied metric_names=%@", groupNames)
          result(nativeFlutterError(.nativePermissionDenied, message: error.localizedDescription))
        } else {
          NSLog("[AgentTrace] event=health_permission_result status=%@ metric_names=%@", success ? "ok" : "permission_denied", groupNames)
          result(success)
        }
      }
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    }
  }

  private func readAggregates(_ arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(nativeFlutterError(.modelUnsupportedDevice, message: "HealthKit is not available on this device."))
      return
    }
    guard let payload = arguments as? [String: Any],
          let metricNames = payload["metric_types"] as? [String],
          let startMillis = millisValue(payload["start_time_millis"]),
          let endMillis = millisValue(payload["end_time_millis"]),
          endMillis > startMillis else {
      result(nativeFlutterError(.unknown, message: "Invalid HealthKit aggregate request."))
      return
    }
    let readMode = payload["read_mode"] as? String ?? "aggregate"

    let descriptors = metricNames.uniqueSorted().compactMap(SummaryDescriptor.forMetric)
    guard descriptors.count == Set(metricNames).count else {
      let unsupported = metricNames.filter { SummaryDescriptor.forMetric($0) == nil }
      result(nativeFlutterError(.unknown, message: "Unsupported Apple Health metrics: \(unsupported.joined(separator: ", "))"))
      return
    }

    let startDate = Date(timeIntervalSince1970: TimeInterval(startMillis) / 1000.0)
    let endDate = Date(timeIntervalSince1970: TimeInterval(endMillis) / 1000.0)
    let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
    let windowDays = max(1, Int(ceil(endDate.timeIntervalSince(startDate) / 86_400.0)))
    NSLog("[AgentTrace] event=health_aggregate_read_start metric_names=%@ window_days=%d", descriptors.map(\.metric).joined(separator: ","), windowDays)

    let group = DispatchGroup()
    let lock = NSLock()
    var output = [[String: Any]]()
    for descriptor in descriptors {
      group.enter()
      let completion: ([String: Any]?, FlutterError?) -> Void = { aggregate, error in
        defer { group.leave() }
        lock.lock()
        defer { lock.unlock() }
        if let error {
          NSLog("[AgentTrace] event=health_aggregate_read_finish metric_names=%@ status=read_failed reason=read_failed window_days=%d error_code=%@ error_detail=%@", descriptor.metric, windowDays, error.code, error.message ?? "")
          return
        }
        if let aggregate {
          output.append(aggregate)
          NSLog("[AgentTrace] event=health_aggregate_read_finish metric_names=%@ status=ok sample_count=%d window_days=%d", descriptor.metric, aggregate["sample_count"] as? Int ?? 0, windowDays)
        } else {
          NSLog("[AgentTrace] event=health_aggregate_read_finish metric_names=%@ status=no_data reason=permission_or_no_visible_data sample_count=0 window_days=%d", descriptor.metric, windowDays)
        }
      }
      if readMode == "latest" {
        readLatestAggregate(descriptor, predicate: predicate, startDate: startDate, endDate: endDate, completion: completion)
      } else {
        readAggregate(descriptor, predicate: predicate, startDate: startDate, endDate: endDate, completion: completion)
      }
    }
    group.notify(queue: .main) { result(output) }
  }

  private func readAggregate(
    _ descriptor: SummaryDescriptor,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    switch descriptor.kind {
    case .quantity:
      readQuantity(descriptor, predicate: predicate, completion: completion)
    case .latestQuantity:
      readLatestQuantity(descriptor, endDate: endDate, completion: completion)
    case .categoryDuration:
      readCategoryDuration(descriptor, predicate: predicate, startDate: startDate, endDate: endDate, completion: completion)
    case .sleep:
      readSleep(descriptor, predicate: predicate, startDate: startDate, endDate: endDate, completion: completion)
    case .workout:
      readWorkout(descriptor, predicate: predicate, startDate: startDate, endDate: endDate, completion: completion)
    }
  }

  private func readLatestAggregate(
    _ descriptor: SummaryDescriptor,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    switch descriptor.kind {
    case .quantity, .latestQuantity:
      readLatestQuantity(descriptor, endDate: endDate, completion: completion)
    case .categoryDuration, .sleep, .workout:
      completion(nil, nativeFlutterError(.unknown, message: "Latest mode is unsupported for Apple Health metric: \(descriptor.metric)"))
    }
  }

  private func readQuantity(
    _ descriptor: SummaryDescriptor,
    predicate: NSPredicate,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let quantityType = HealthKitTypeRegistry.quantityType(descriptor.identifier) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health quantity: \(descriptor.metric)"))
      return
    }
    let options: HKStatisticsOptions = descriptor.isCumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
    let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: options) { _, statistics, error in
      if let error {
        completion(nil, self.flutterErrorIfNeeded(error))
        return
      }
      if descriptor.isCumulative {
        guard let quantity = statistics?.sumQuantity() else {
          completion(nil, nil)
          return
        }
        self.finishValue(descriptor, value: quantity.doubleValue(for: descriptor.unit), sampleCount: 1, completion: completion)
      } else {
        guard let average = statistics?.averageQuantity() else {
          completion(nil, nil)
          return
        }
        var payload = self.basePayload(descriptor, sampleCount: 1)
        payload["average"] = average.doubleValue(for: descriptor.unit)
        if let min = statistics?.minimumQuantity() { payload["min"] = min.doubleValue(for: descriptor.unit) }
        if let max = statistics?.maximumQuantity() { payload["max"] = max.doubleValue(for: descriptor.unit) }
        completion(payload, nil)
      }
    }
    healthStore.execute(query)
  }

  private func readLatestQuantity(
    _ descriptor: SummaryDescriptor,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let quantityType = HealthKitTypeRegistry.quantityType(descriptor.identifier) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health quantity: \(descriptor.metric)"))
      return
    }
    let predicate = HKQuery.predicateForSamples(withStart: nil, end: endDate, options: [])
    let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
    let query = HKSampleQuery(sampleType: quantityType, predicate: predicate, limit: 1, sortDescriptors: sort) { _, samples, error in
      if let error {
        completion(nil, self.flutterErrorIfNeeded(error))
        return
      }
      guard let sample = samples?.first as? HKQuantitySample else {
        completion(nil, nil)
        return
      }
      self.finishValue(
        descriptor,
        value: sample.quantity.doubleValue(for: descriptor.unit),
        sampleCount: 1,
        sampleEndDate: sample.endDate,
        completion: completion
      )
    }
    healthStore.execute(query)
  }

  private func readCategoryDuration(
    _ descriptor: SummaryDescriptor,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let categoryType = HealthKitTypeRegistry.categoryType(descriptor.identifier) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health category: \(descriptor.metric)"))
      return
    }
    let query = HKSampleQuery(sampleType: categoryType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
      if let error {
        completion(nil, self.flutterErrorIfNeeded(error))
        return
      }
      let intervals = (samples ?? []).compactMap { sample -> (Date, Date)? in
        guard let sample = sample as? HKCategorySample else { return nil }
        return self.clippedInterval(sample, startDate: startDate, endDate: endDate)
      }
      self.finishValue(descriptor, value: self.mergedDurationHours(intervals) * 60.0, sampleCount: intervals.count, completion: completion)
    }
    healthStore.execute(query)
  }

  private func readSleep(
    _ descriptor: SummaryDescriptor,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      completion(nil, nativeFlutterError(.unknown, message: "Unsupported Apple Health category: \(descriptor.metric)"))
      return
    }
    let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
    let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
      if let error {
        completion(nil, self.flutterErrorIfNeeded(error))
        return
      }
      let intervals = (samples ?? []).compactMap { sample -> (Date, Date)? in
        guard let sample = sample as? HKCategorySample, self.isAsleep(sample.value) else { return nil }
        return self.clippedInterval(sample, startDate: startDate, endDate: endDate)
      }
      self.finishValue(descriptor, value: self.mergedDurationHours(intervals), sampleCount: intervals.count, completion: completion)
    }
    healthStore.execute(query)
  }

  private func readWorkout(
    _ descriptor: SummaryDescriptor,
    predicate: NSPredicate,
    startDate: Date,
    endDate: Date,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
      if let error {
        completion(nil, self.flutterErrorIfNeeded(error))
        return
      }
      let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
      let minutes = workouts.reduce(0.0) { total, workout in
        let start = max(workout.startDate, startDate)
        let end = min(workout.endDate, endDate)
        return end > start ? total + end.timeIntervalSince(start) / 60.0 : total
      }
      self.finishValue(descriptor, value: minutes, sampleCount: workouts.count, completion: completion)
    }
    healthStore.execute(query)
  }

  private func finishValue(
    _ descriptor: SummaryDescriptor,
    value: Double,
    sampleCount: Int,
    sampleEndDate: Date? = nil,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    guard sampleCount > 0, value > 0 else {
      completion(nil, nil)
      return
    }
    var payload = basePayload(descriptor, sampleCount: sampleCount)
    payload["value"] = value
    if let sampleEndDate {
      payload["sample_end_time_millis"] = Int64(sampleEndDate.timeIntervalSince1970 * 1000.0)
    }
    completion(payload, nil)
  }

  private func basePayload(_ descriptor: SummaryDescriptor, sampleCount: Int) -> [String: Any] {
    [
      "type": descriptor.metric,
      "unit": descriptor.unitName,
      "sample_count": sampleCount
    ]
  }

  private func clippedInterval(_ sample: HKSample, startDate: Date, endDate: Date) -> (Date, Date)? {
    let start = max(sample.startDate, startDate)
    let end = min(sample.endDate, endDate)
    return end > start ? (start, end) : nil
  }

  private func isAsleep(_ value: Int) -> Bool {
    if value == HKCategoryValueSleepAnalysis.asleep.rawValue { return true }
    if #available(iOS 16.0, *) {
      return value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
        || value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        || value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
        || value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
    }
    return false
  }

  private func mergedDurationHours(_ intervals: [(Date, Date)]) -> Double {
    var merged = [(Date, Date)]()
    for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
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
    return merged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600.0
  }

  private func flutterErrorIfNeeded(_ error: Error) -> FlutterError? {
    isNoDataError(error) ? nil : nativeFlutterError(.modelRuntimeInternal, message: errorDescription(error))
  }

  private func isNoDataError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == HKError.errorDomain && nsError.code == HKError.Code.errorNoData.rawValue
  }

  private func errorDescription(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
  }

  private func requestStatusName(_ status: HKAuthorizationRequestStatus) -> String {
    switch status {
    case .shouldRequest:
      return "should_request"
    case .unnecessary:
      return "unnecessary"
    case .unknown:
      return "unknown"
    @unknown default:
      return "unknown"
    }
  }

  private func millisValue(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? Int64 { return value }
    return nil
  }
}

private enum SummaryKind {
  case quantity
  case latestQuantity
  case categoryDuration
  case sleep
  case workout
}

private struct SummaryDescriptor {
  let metric: String
  let identifier: String
  let unit: HKUnit
  let unitName: String
  let kind: SummaryKind
  let isCumulative: Bool

  static func forMetric(_ metric: String) -> SummaryDescriptor? {
    descriptors[metric]
  }

  private static let descriptors: [String: SummaryDescriptor] = [
    quantity("steps", "HKQuantityTypeIdentifierStepCount", .count(), "count", true),
    quantity("activeEnergy", "HKQuantityTypeIdentifierActiveEnergyBurned", .kilocalorie(), "kcal", true),
    quantity("basalEnergy", "HKQuantityTypeIdentifierBasalEnergyBurned", .kilocalorie(), "kcal", true),
    quantity("exerciseTime", "HKQuantityTypeIdentifierAppleExerciseTime", .minute(), "minute", true),
    quantity("standTime", "HKQuantityTypeIdentifierAppleStandTime", .minute(), "minute", true),
    quantity("distanceWalkingRunning", "HKQuantityTypeIdentifierDistanceWalkingRunning", .meter(), "m", true),
    quantity("flightsClimbed", "HKQuantityTypeIdentifierFlightsClimbed", .count(), "count", true),
    quantity("heartRate", "HKQuantityTypeIdentifierHeartRate", HKUnit.count().unitDivided(by: .minute()), "bpm", false),
    quantity("restingHeartRate", "HKQuantityTypeIdentifierRestingHeartRate", HKUnit.count().unitDivided(by: .minute()), "bpm", false),
    quantity("walkingHeartRateAverage", "HKQuantityTypeIdentifierWalkingHeartRateAverage", HKUnit.count().unitDivided(by: .minute()), "bpm", false),
    quantity("hrv", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", HKUnit.secondUnit(with: .milli), "ms", false),
    SummaryDescriptor(metric: "weight", identifier: "HKQuantityTypeIdentifierBodyMass", unit: HKUnit.gramUnit(with: .kilo), unitName: "kg", kind: .latestQuantity, isCumulative: false),
    SummaryDescriptor(metric: "mindfulMinutes", identifier: "HKCategoryTypeIdentifierMindfulSession", unit: .minute(), unitName: "minute", kind: .categoryDuration, isCumulative: true),
    SummaryDescriptor(metric: "sleepSession", identifier: "HKCategoryTypeIdentifierSleepAnalysis", unit: HKUnit.hour(), unitName: "hour", kind: .sleep, isCumulative: true),
    SummaryDescriptor(metric: "workoutSession", identifier: "HKWorkoutTypeIdentifier", unit: .minute(), unitName: "minute", kind: .workout, isCumulative: true)
  ].reduce(into: [:]) { $0[$1.metric] = $1 }

  private static func quantity(
    _ metric: String,
    _ identifier: String,
    _ unit: HKUnit,
    _ unitName: String,
    _ isCumulative: Bool
  ) -> SummaryDescriptor {
    SummaryDescriptor(metric: metric, identifier: identifier, unit: unit, unitName: unitName, kind: .quantity, isCumulative: isCumulative)
  }
}

private enum HealthKitTypeRegistry {
  static let groupNames = [
    "activity", "sleep", "heart", "workouts", "body",
    "mindfulness", "nutrition", "respiratory", "environment"
  ]

  private static let quantityIdentifiers = [
    "HKQuantityTypeIdentifierStepCount",
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierDistanceCycling",
    "HKQuantityTypeIdentifierDistanceSwimming",
    "HKQuantityTypeIdentifierSwimmingStrokeCount",
    "HKQuantityTypeIdentifierFlightsClimbed",
    "HKQuantityTypeIdentifierPushCount",
    "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierBasalEnergyBurned",
    "HKQuantityTypeIdentifierAppleExerciseTime",
    "HKQuantityTypeIdentifierAppleStandTime",
    "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierRestingHeartRate",
    "HKQuantityTypeIdentifierWalkingHeartRateAverage",
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    "HKQuantityTypeIdentifierVO2Max",
    "HKQuantityTypeIdentifierOxygenSaturation",
    "HKQuantityTypeIdentifierRespiratoryRate",
    "HKQuantityTypeIdentifierBodyMass",
    "HKQuantityTypeIdentifierBodyMassIndex",
    "HKQuantityTypeIdentifierBodyFatPercentage",
    "HKQuantityTypeIdentifierLeanBodyMass",
    "HKQuantityTypeIdentifierHeight",
    "HKQuantityTypeIdentifierWaistCircumference",
    "HKQuantityTypeIdentifierDietaryEnergyConsumed",
    "HKQuantityTypeIdentifierDietaryWater",
    "HKQuantityTypeIdentifierDietaryCaffeine",
    "HKQuantityTypeIdentifierDietaryProtein",
    "HKQuantityTypeIdentifierDietaryCarbohydrates",
    "HKQuantityTypeIdentifierDietaryFatTotal",
    "HKQuantityTypeIdentifierDietarySugar",
    "HKQuantityTypeIdentifierDietaryFiber",
    "HKQuantityTypeIdentifierDietarySodium",
    "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
    "HKQuantityTypeIdentifierHeadphoneAudioExposure"
  ]

  private static let categoryIdentifiers = [
    "HKCategoryTypeIdentifierSleepAnalysis",
    "HKCategoryTypeIdentifierMindfulSession",
    "HKCategoryTypeIdentifierAppleStandHour",
    "HKCategoryTypeIdentifierHighHeartRateEvent",
    "HKCategoryTypeIdentifierLowHeartRateEvent",
    "HKCategoryTypeIdentifierIrregularHeartRhythmEvent"
  ]

  static func allReadTypes() -> Set<HKObjectType> {
    var types: Set<HKObjectType> = [HKObjectType.workoutType()]
    quantityIdentifiers.compactMap(quantityType).forEach { types.insert($0) }
    categoryIdentifiers.compactMap(categoryType).forEach { types.insert($0) }
    return types
  }

  static func quantityType(_ identifier: String) -> HKQuantityType? {
    HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
  }

  static func categoryType(_ identifier: String) -> HKCategoryType? {
    HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
  }
}

private extension Array where Element == String {
  func uniqueSorted() -> [String] {
    Array(Set(self)).sorted()
  }
}
