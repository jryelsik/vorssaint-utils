// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum PeripheralBatteryKind: String, Comparable {
    case keyboard, mouse, trackpad, audio, device

    var menuLabel: String {
        switch self {
        case .keyboard: return "KBD"
        case .mouse: return "MOU"
        case .trackpad: return "TRK"
        case .audio: return "AUD"
        case .device: return "PER"
        }
    }

    static func < (lhs: PeripheralBatteryKind, rhs: PeripheralBatteryKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PeripheralBatteryDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let percent: Int
    let kind: PeripheralBatteryKind
}

struct BluetoothBatteryReading: Equatable {
    let id: String
    let name: String
    let percent: Int
}

enum PeripheralBatterySupport {
    static let percentKeys = [
        "BatteryPercent",
        "BatteryPercentRemaining",
        "BatteryLevel",
        "Battery Level",
        "Battery",
    ]

    static func percent(from value: Any?) -> Int? {
        let raw: Double?
        switch value {
        case let number as NSNumber:
            raw = number.doubleValue
        case let int as Int:
            raw = Double(int)
        case let double as Double:
            raw = double
        case let float as Float:
            raw = Double(float)
        case let string as String:
            let cleaned = string
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            raw = Double(cleaned)
        default:
            raw = nil
        }
        guard let raw, raw.isFinite else { return nil }
        let rounded = Int(raw.rounded())
        guard (0...100).contains(rounded) else { return nil }
        return rounded
    }

    static func percent(in properties: [String: Any]) -> Int? {
        for key in percentKeys {
            if let percent = percent(from: properties[key]) {
                return percent
            }
        }
        return nil
    }

    static func bool(from value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y"].contains(normalized)
        default:
            return false
        }
    }

    static func int(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let int as Int:
            return int
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func string(from value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func name(in properties: [String: Any]) -> String? {
        for key in ["Product", "ProductName", "DeviceName", "IOProviderClass"] {
            if let name = string(from: properties[key]) {
                return name
            }
        }
        return nil
    }

    static func isBuiltIn(_ properties: [String: Any]) -> Bool {
        for key in ["Built-In", "BuiltIn", "Builtin", "built-in"] {
            if bool(from: properties[key]) {
                return true
            }
        }
        return false
    }

    static func usagePairs(from value: Any?) -> [[String: Any]] {
        guard let pairs = value as? [Any] else { return [] }
        return pairs.compactMap { pair in
            if let dict = pair as? [String: Any] {
                return dict
            }
            if let dict = pair as? NSDictionary {
                return dict as? [String: Any]
            }
            return nil
        }
    }

    static func kind(product: String,
                     minorType: String? = nil,
                     primaryUsagePage: Int?,
                     primaryUsage: Int?,
                     usagePairs: [[String: Any]]) -> PeripheralBatteryKind {
        let normalized = [product, minorType]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if normalized.contains("keyboard") { return .keyboard }
        if normalized.contains("mouse") { return .mouse }
        if normalized.contains("trackpad") || normalized.contains("track pad") { return .trackpad }
        if normalized.contains("airpods")
            || normalized.contains("headphone")
            || normalized.contains("headset")
            || normalized.contains("buds") {
            return .audio
        }

        var usages: [(page: Int, usage: Int)] = []
        if let primaryUsagePage, let primaryUsage {
            usages.append((primaryUsagePage, primaryUsage))
        }
        for pair in usagePairs {
            let page = int(from: pair["DeviceUsagePage"])
                ?? int(from: pair["PrimaryUsagePage"])
                ?? int(from: pair["UsagePage"])
            let usage = int(from: pair["DeviceUsage"])
                ?? int(from: pair["PrimaryUsage"])
                ?? int(from: pair["Usage"])
            if let page, let usage {
                usages.append((page, usage))
            }
        }

        if usages.contains(where: { $0.page == 1 && $0.usage == 2 }) {
            return .mouse
        }
        if usages.contains(where: { ($0.page == 1 && $0.usage == 6) || $0.page == 7 }) {
            return .keyboard
        }
        if usages.contains(where: { $0.page == 13 && $0.usage == 5 }) {
            return .trackpad
        }
        return .device
    }

    static func shouldInclude(name: String?, isBuiltIn: Bool, percent: Int?) -> Bool {
        guard let name, !name.isEmpty, percent != nil else { return false }
        return !isBuiltIn
    }

    static func bluetoothDevices(fromSystemProfilerJSON data: Data) -> [PeripheralBatteryDevice] {
        var devices: [PeripheralBatteryDevice] = []
        for (name, properties) in connectedBluetoothEntries(from: data) {
            let minorType = string(from: properties["device_minorType"])
            let kind = kind(product: name,
                            minorType: minorType,
                            primaryUsagePage: nil,
                            primaryUsage: nil,
                            usagePairs: [])
            let address = string(from: properties["device_address"]) ?? name.lowercased()
            let idPrefix = "Bluetooth:\(address)"

            let left = percent(from: properties["device_batteryLevelLeft"])
            let right = percent(from: properties["device_batteryLevelRight"])
            let caseLevel = percent(from: properties["device_batteryLevelCase"])
            let main = percent(from: properties["device_batteryLevelMain"])
                ?? percent(from: properties["device_batteryLevel"])

            var addedComponents = false
            if let left {
                devices.append(PeripheralBatteryDevice(id: "\(idPrefix):left",
                                                       name: "\(name) (Left)",
                                                       percent: left,
                                                       kind: kind))
                addedComponents = true
            }
            if let right {
                devices.append(PeripheralBatteryDevice(id: "\(idPrefix):right",
                                                       name: "\(name) (Right)",
                                                       percent: right,
                                                       kind: kind))
                addedComponents = true
            }
            if let caseLevel {
                devices.append(PeripheralBatteryDevice(id: "\(idPrefix):case",
                                                       name: "\(name) (Case)",
                                                       percent: caseLevel,
                                                       kind: kind))
                addedComponents = true
            }
            if !addedComponents, let main {
                devices.append(PeripheralBatteryDevice(id: idPrefix,
                                                       name: name,
                                                       percent: main,
                                                       kind: kind))
            } else if !addedComponents, let fallback = bluetoothPercent(in: properties) {
                devices.append(PeripheralBatteryDevice(id: idPrefix,
                                                       name: name,
                                                       percent: fallback,
                                                       kind: kind))
            }
        }
        return sorted(devices)
    }

    static func bluetoothKindsByName(fromSystemProfilerJSON data: Data) -> [String: PeripheralBatteryKind] {
        var result: [String: PeripheralBatteryKind] = [:]
        for (name, properties) in connectedBluetoothEntries(from: data) {
            let minorType = string(from: properties["device_minorType"])
            let k = kind(product: name,
                         minorType: minorType,
                         primaryUsagePage: nil,
                         primaryUsage: nil,
                         usagePairs: [])
            result[normalizedBluetoothName(name)] = k
            result[normalizedBluetoothName("\(name) (left)")] = k
            result[normalizedBluetoothName("\(name) (right)")] = k
            result[normalizedBluetoothName("\(name) (case)")] = k
        }
        return result
    }

    static func bluetoothNamesByAddress(fromSystemProfilerJSON data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for (name, properties) in connectedBluetoothEntries(from: data) {
            if let address = string(from: properties["device_address"]) {
                result[normalizedAddress(address)] = name
            }
        }
        return result
    }

    static func normalizedAddress(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":")
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .lowercased()
    }

    static func mergingBluetoothReadings(_ readings: [BluetoothBatteryReading],
                                         into devices: [PeripheralBatteryDevice],
                                         knownKinds: [String: PeripheralBatteryKind]) -> [PeripheralBatteryDevice] {
        var result = devices
        var seenIDs = Set(devices.map(\.id))
        var seenNames = Set(devices.map { normalizedBluetoothName($0.name) })

        for reading in readings {
            let normalizedName = normalizedBluetoothName(reading.name)
            let id = "BluetoothGATT:\(reading.id)"
            guard !normalizedName.isEmpty,
                  (0...100).contains(reading.percent),
                  seenIDs.insert(id).inserted,
                  seenNames.insert(normalizedName).inserted else {
                continue
            }
            let kind = knownKinds[normalizedName]
                ?? kind(product: reading.name,
                        primaryUsagePage: nil,
                        primaryUsage: nil,
                        usagePairs: [])
            result.append(PeripheralBatteryDevice(id: id,
                                                  name: reading.name,
                                                  percent: reading.percent,
                                                  kind: kind))
        }
        return sorted(result)
    }

    private static func connectedBluetoothEntries(from data: Data) -> [(String, [String: Any])] {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [Any] else {
            return []
        }

        var notConnectedNames = Set<String>()
        for controllerValue in controllers {
            guard let controller = dictionary(from: controllerValue),
                  let notConnected = controller["device_not_connected"] as? [Any] else {
                continue
            }
            for entryValue in notConnected {
                guard let entry = dictionary(from: entryValue) else { continue }
                for (name, _) in entry {
                    notConnectedNames.insert(normalizedBluetoothName(name))
                }
            }
        }

        var entries: [(String, [String: Any])] = []
        for controllerValue in controllers {
            guard let controller = dictionary(from: controllerValue),
                  let connected = controller["device_connected"] as? [Any] else {
                continue
            }
            for entryValue in connected {
                guard let entry = dictionary(from: entryValue) else { continue }
                for (name, propertiesValue) in entry {
                    guard let properties = dictionary(from: propertiesValue) else { continue }
                    let normalizedName = normalizedBluetoothName(name)
                    if notConnectedNames.contains(normalizedName) {
                        continue
                    }
                    if let services = string(from: properties["device_services"]) {
                        let hasAudio = services.contains("A2DP")
                            || services.contains("HFP")
                            || services.contains("AVRCP")
                            || services.contains("SCO")
                            || services.contains("LEA")
                            || services.contains("AAC")
                        if !hasAudio && services.contains("BLE") {
                            let minorType = string(from: properties["device_minorType"])
                            let k = kind(product: name,
                                         minorType: minorType,
                                         primaryUsagePage: nil,
                                         primaryUsage: nil,
                                         usagePairs: [])
                            if k == .audio {
                                continue
                            }
                        }
                    }
                    entries.append((name, properties))
                }
            }
        }
        return entries
    }

    static func normalizedBluetoothName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func bluetoothPercent(in properties: [String: Any]) -> Int? {
        for key in ["device_batteryLevelMain", "device_batteryLevel"] {
            if let percent = percent(from: properties[key]) {
                return percent
            }
        }

        let partKeys = [
            "device_batteryLevelLeft",
            "device_batteryLevelRight",
            "device_batteryLevelCase",
        ]
        var values = partKeys.compactMap { percent(from: properties[$0]) }
        let knownKeys = Set(partKeys + ["device_batteryLevelMain", "device_batteryLevel"])
        values += properties
            .filter { key, _ in key.hasPrefix("device_batteryLevel") && !knownKeys.contains(key) }
            .compactMap { percent(from: $0.value) }
        return values.min()
    }

    private static func dictionary(from value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }

    static func sorted(_ devices: [PeripheralBatteryDevice]) -> [PeripheralBatteryDevice] {
        devices.sorted {
            if $0.percent != $1.percent { return $0.percent < $1.percent }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func isCaseDevice(_ device: PeripheralBatteryDevice) -> Bool {
        let lower = device.name.lowercased()
        return lower.contains("(case)") || lower.hasSuffix(" case")
    }

    static func isLeftEarbud(_ device: PeripheralBatteryDevice) -> Bool {
        guard device.kind == .audio else { return false }
        let lower = device.name.lowercased()
        return lower.contains("(left)") || lower.hasSuffix(" left") || device.id.hasSuffix(":left")
    }

    static func isRightEarbud(_ device: PeripheralBatteryDevice) -> Bool {
        guard device.kind == .audio else { return false }
        let lower = device.name.lowercased()
        return lower.contains("(right)") || lower.hasSuffix(" right") || device.id.hasSuffix(":right")
    }

    static func earbudBaseIdentifier(_ device: PeripheralBatteryDevice) -> String {
        if device.id.hasSuffix(":left") {
            return String(device.id.dropLast(5))
        }
        if device.id.hasSuffix(":right") {
            return String(device.id.dropLast(6))
        }
        let lower = device.name.lowercased()
        if let range = lower.range(of: " (left)", options: .backwards) {
            return String(lower[..<range.lowerBound])
        }
        if let range = lower.range(of: " (right)", options: .backwards) {
            return String(lower[..<range.lowerBound])
        }
        return lower
    }

    static func airPodsProComponents(for devices: [PeripheralBatteryDevice]) -> (left: PeripheralBatteryDevice, right: PeripheralBatteryDevice)? {
        let lefts = devices.filter { isLeftEarbud($0) }
        let rights = devices.filter { isRightEarbud($0) }
        guard !lefts.isEmpty && !rights.isEmpty else { return nil }

        for left in lefts {
            let leftBase = earbudBaseIdentifier(left)
            if let right = rights.first(where: { earbudBaseIdentifier($0) == leftBase }) {
                return (left, right)
            }
        }
        return nil
    }

    static func devicesForMenuBar(_ devices: [PeripheralBatteryDevice]) -> [PeripheralBatteryDevice] {
        let audioDevices = devices.filter { $0.kind == .audio }
        let nonCases = audioDevices.filter { !isCaseDevice($0) }
        let candidates = nonCases.isEmpty ? audioDevices : nonCases
        return sorted(candidates)
    }

    static func menuBarMetric(for devices: [PeripheralBatteryDevice]) -> (label: String, value: String)? {
        let devices = devicesForMenuBar(devices)
        guard let first = devices.first else { return nil }
        let extra = devices.count > 1 ? "+\(min(9, devices.count - 1))" : ""
        return (first.kind.menuLabel, "\(first.percent)%\(extra)")
    }
}

enum PeripheralBatteryRefreshPolicy {
    static func shouldStartBluetoothRefresh(now: TimeInterval,
                                            lastStartedAt: TimeInterval,
                                            lastFinishedAt: TimeInterval,
                                            isRunning: Bool,
                                            interval: TimeInterval) -> Bool {
        guard !isRunning else { return false }
        let lastAttempt = max(lastStartedAt, lastFinishedAt)
        return now - lastAttempt >= interval
    }
}
