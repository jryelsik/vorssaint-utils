// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreBluetooth
import IOBluetooth
import IOKit

final class PeripheralBatterySampler {
    private let lock = NSLock()
    private let bluetoothQueue = DispatchQueue(label: "com.vorssaint.peripheral-battery.bluetooth", qos: .utility)
    private var cachedDevices: [PeripheralBatteryDevice] = []
    private var cachedAt: TimeInterval = 0
    private var cachedBluetoothDevices: [PeripheralBatteryDevice] = []
    private var cachedNamesByAddress: [String: String] = [:]
    private var bluetoothStartedAt: TimeInterval = -.greatestFiniteMagnitude
    private var bluetoothFinishedAt: TimeInterval = -.greatestFiniteMagnitude
    private var bluetoothRefreshRunning = false
    private var bluetoothBatteryRead: BluetoothBatteryRead?
    private let fastCacheInterval: TimeInterval = 15
    private let bluetoothCacheInterval: TimeInterval = 30

    func sample(now: TimeInterval) -> [PeripheralBatteryDevice] {
        startBluetoothRefreshIfNeeded(now: now)

        lock.lock()
        if now - cachedAt < fastCacheInterval {
            let devices = cachedDevices
            lock.unlock()
            return devices
        }
        let names = cachedNamesByAddress
        let bluetoothDevices = cachedBluetoothDevices
        lock.unlock()

        let disconnectedPaired = Self.readDisconnectedPairedNames()
        let filteredBluetooth = bluetoothDevices.filter { dev in
            let baseIdentifier = PeripheralBatterySupport.earbudBaseIdentifier(dev)
            if disconnectedPaired.contains(baseIdentifier) { return false }
            let normalizedName = PeripheralBatterySupport.normalizedBluetoothName(dev.name)
            if disconnectedPaired.contains(normalizedName) { return false }
            return true
        }

        let devices = Self.uniqueDevices(from: Self.readFastDevices(knownNamesByAddress: names) + filteredBluetooth)

        lock.lock()
        cachedDevices = devices
        cachedAt = now
        lock.unlock()

        return devices
    }

    private func startBluetoothRefreshIfNeeded(now: TimeInterval) {
        lock.lock()
        guard PeripheralBatteryRefreshPolicy.shouldStartBluetoothRefresh(
            now: now,
            lastStartedAt: bluetoothStartedAt,
            lastFinishedAt: bluetoothFinishedAt,
            isRunning: bluetoothRefreshRunning,
            interval: bluetoothCacheInterval
        ) else {
            lock.unlock()
            return
        }
        bluetoothRefreshRunning = true
        bluetoothStartedAt = now
        lock.unlock()

        bluetoothQueue.async { [weak self] in
            guard let self else { return }
            let profilerData = Self.readBluetoothSystemProfilerData()
            let profilerDevices = PeripheralBatterySupport.bluetoothDevices(
                fromSystemProfilerJSON: profilerData
            )
            let knownKinds = PeripheralBatterySupport.bluetoothKindsByName(
                fromSystemProfilerJSON: profilerData
            )
            let knownNames = PeripheralBatterySupport.bluetoothNamesByAddress(
                fromSystemProfilerJSON: profilerData
            )
            let batteryRead = BluetoothBatteryRead(queue: bluetoothQueue) { [weak self] readings in
                guard let self else { return }
                let devices = PeripheralBatterySupport.mergingBluetoothReadings(
                    readings,
                    into: profilerDevices,
                    knownKinds: knownKinds
                )
                finishBluetoothRefresh(with: devices, namesByAddress: knownNames)
                bluetoothBatteryRead = nil
            }
            bluetoothBatteryRead = batteryRead
            batteryRead.start()
        }
    }

    private func finishBluetoothRefresh(with devices: [PeripheralBatteryDevice],
                                        namesByAddress: [String: String]) {
        lock.lock()
        cachedBluetoothDevices = devices
        cachedNamesByAddress = namesByAddress
        bluetoothFinishedAt = ProcessInfo.processInfo.systemUptime
        bluetoothRefreshRunning = false
        cachedAt = -.greatestFiniteMagnitude
        lock.unlock()
    }

    private static func readFastDevices(knownNamesByAddress: [String: String] = [:]) -> [PeripheralBatteryDevice] {
        let devices = readMatchingServices(named: "AppleDeviceManagementHIDEventService")
            + readMatchingServices(named: "IOHIDDevice")
            + readIOBluetoothDevices(knownNamesByAddress: knownNamesByAddress)
        return uniqueDevices(from: devices)
    }

    private static func readIOBluetoothDevices(knownNamesByAddress: [String: String]) -> [PeripheralBatteryDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }
        var devices: [PeripheralBatteryDevice] = []
        for device in paired {
            guard device.isConnected() else { continue }
            let rawAddress = device.addressString ?? ""
            let normalizedAddr = PeripheralBatterySupport.normalizedAddress(rawAddress)
            let baseName = knownNamesByAddress[normalizedAddr]
                ?? (device.nameOrAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseName.isEmpty else { continue }
            let idPrefix = "IOBluetooth:\(normalizedAddr.isEmpty ? baseName.lowercased() : normalizedAddr)"

            let single = readBatteryPercent(from: device, selectorName: "batteryPercentSingle")
            let left = readBatteryPercent(from: device, selectorName: "batteryPercentLeft")
            let right = readBatteryPercent(from: device, selectorName: "batteryPercentRight")
            let devCase = readBatteryPercent(from: device, selectorName: "batteryPercentCase")
            let combined = readBatteryPercent(from: device, selectorName: "batteryPercentCombined")

            let kind = PeripheralBatterySupport.kind(product: baseName,
                                                    primaryUsagePage: nil,
                                                    primaryUsage: nil,
                                                    usagePairs: [])

            var addedComponents = false
            if let left {
                devices.append(PeripheralBatteryDevice(id: "\(idPrefix):left",
                                                       name: "\(baseName) (Left)",
                                                       percent: left,
                                                       kind: kind))
                addedComponents = true
            }
            if let right {
                devices.append(PeripheralBatteryDevice(id: "\(idPrefix):right",
                                                       name: "\(baseName) (Right)",
                                                       percent: right,
                                                       kind: kind))
                addedComponents = true
            }
            if let devCase {
                devices.append(PeripheralBatteryDevice(id: "\(idPrefix):case",
                                                       name: "\(baseName) (Case)",
                                                       percent: devCase,
                                                       kind: kind))
                addedComponents = true
            }
            if !addedComponents, let percent = single ?? combined {
                devices.append(PeripheralBatteryDevice(id: idPrefix,
                                                       name: baseName,
                                                       percent: percent,
                                                       kind: kind))
            }
        }
        return devices
    }

    private typealias BatteryPercentGetter = @convention(c) (AnyObject, Selector) -> UInt8

    private static func readBatteryPercent(from device: AnyObject, selectorName: String) -> Int? {
        let sel = Selector((selectorName))
        guard device.responds(to: sel),
              let method = class_getInstanceMethod(type(of: device), sel) else {
            return nil
        }
        let imp = method_getImplementation(method)
        let getter = unsafeBitCast(imp, to: BatteryPercentGetter.self)
        let percent = Int(getter(device, sel))
        guard (0...100).contains(percent), percent > 0 else { return nil }
        return percent
    }

    private static func readBluetoothSystemProfilerData(timeout: TimeInterval = 10) -> Data {
        let result = BoundedProcessRunner.run(
            "/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json", "-detailLevel", "basic"],
            timeout: timeout, maxOutputBytes: 4 * 1024 * 1024)
        return result.status == 0 ? result.output : Data()
    }

    private static func readMatchingServices(named className: String) -> [PeripheralBatteryDevice] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [PeripheralBatteryDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let properties = properties(for: service),
               let device = device(from: properties, service: service) {
                devices.append(device)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }

    private static func properties(for service: io_object_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let unmanaged else {
            return nil
        }
        let properties = unmanaged.takeRetainedValue() as NSDictionary
        return properties as? [String: Any]
    }

    private static func device(from properties: [String: Any],
                               service: io_object_t) -> PeripheralBatteryDevice? {
        let name = PeripheralBatterySupport.name(in: properties)
        let percent = PeripheralBatterySupport.percent(in: properties)
        let builtIn = PeripheralBatterySupport.isBuiltIn(properties)
        guard PeripheralBatterySupport.shouldInclude(name: name, isBuiltIn: builtIn, percent: percent),
              let name,
              let percent else {
            return nil
        }
        let primaryUsagePage = PeripheralBatterySupport.int(from: properties["PrimaryUsagePage"])
            ?? PeripheralBatterySupport.int(from: properties["DeviceUsagePage"])
        let primaryUsage = PeripheralBatterySupport.int(from: properties["PrimaryUsage"])
            ?? PeripheralBatterySupport.int(from: properties["DeviceUsage"])
        let pairs = PeripheralBatterySupport.usagePairs(from: properties["DeviceUsagePairs"])
        let kind = PeripheralBatterySupport.kind(product: name,
                                                 primaryUsagePage: primaryUsagePage,
                                                 primaryUsage: primaryUsage,
                                                 usagePairs: pairs)
        return PeripheralBatteryDevice(id: deviceID(from: properties, service: service, fallbackName: name),
                                       name: name,
                                       percent: percent,
                                       kind: kind)
    }

    private static func deviceID(from properties: [String: Any],
                                 service: io_object_t,
                                 fallbackName: String) -> String {
        for key in ["SerialNumber", "DeviceAddress", "LocationID", "ProductID", "VendorID"] {
            if let value = PeripheralBatterySupport.string(from: properties[key]) {
                return "\(key):\(value)"
            }
            if let value = PeripheralBatterySupport.int(from: properties[key]) {
                return "\(key):\(value)"
            }
        }
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS, entryID != 0 {
            return "registry:\(entryID)"
        }
        return "name:\(fallbackName.lowercased())"
    }

    private static func readDisconnectedPairedNames() -> Set<String> {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }
        var disconnected = Set<String>()
        for device in paired {
            guard !device.isConnected() else { continue }
            if let name = device.nameOrAddress {
                disconnected.insert(PeripheralBatterySupport.normalizedBluetoothName(name))
            }
            if let addr = device.addressString {
                disconnected.insert(PeripheralBatterySupport.normalizedAddress(addr))
            }
        }
        return disconnected
    }

    private static func uniqueDevices(from devices: [PeripheralBatteryDevice]) -> [PeripheralBatteryDevice] {
        var seenNames = Set<String>()
        var result: [PeripheralBatteryDevice] = []
        for device in devices {
            let key = "\(device.name.lowercased())|\(device.kind.rawValue)"
            guard seenNames.insert(key).inserted else { continue }
            result.append(device)
        }
        return PeripheralBatterySupport.sorted(result)
    }
}

private final class BluetoothBatteryRead: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private let queue: DispatchQueue
    private let completion: ([BluetoothBatteryReading]) -> Void
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pending = Set<UUID>()
    private var readings: [BluetoothBatteryReading] = []
    private var didRetrieve = false
    private var finished = false
    private var timeout: DispatchWorkItem?

    init(queue: DispatchQueue, completion: @escaping ([BluetoothBatteryReading]) -> Void) {
        self.queue = queue
        self.completion = completion
    }

    func start() {
        central = CBCentralManager(delegate: self,
                                   queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finished else { return }
        switch central.state {
        case .poweredOn:
            guard !didRetrieve else { return }
            didRetrieve = true
            let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
            guard !connected.isEmpty else {
                finish()
                return
            }
            for peripheral in connected {
                peripherals[peripheral.identifier] = peripheral
                pending.insert(peripheral.identifier)
                peripheral.delegate = self
                central.connect(peripheral)
            }
        case .unknown, .resetting:
            break
        case .unsupported, .unauthorized, .poweredOff:
            finish()
        @unknown default:
            finish()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard pending.contains(peripheral.identifier) else { return }
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        complete(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        complete(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
            complete(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else {
            complete(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        defer { complete(peripheral) }
        guard error == nil,
              characteristic.uuid == Self.batteryLevel,
              let data = characteristic.value,
              data.count == 1,
              let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return
        }
        let percent = Int(data[data.startIndex])
        guard percent <= 100 else { return }
        readings.append(BluetoothBatteryReading(id: peripheral.identifier.uuidString,
                                                name: name,
                                                percent: percent))
    }

    private func complete(_ peripheral: CBPeripheral) {
        guard pending.remove(peripheral.identifier) != nil else { return }
        central?.cancelPeripheralConnection(peripheral)
        peripherals[peripheral.identifier] = nil
        if pending.isEmpty {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        for peripheral in peripherals.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
        pending.removeAll()
        central = nil
        completion(readings)
    }
}
