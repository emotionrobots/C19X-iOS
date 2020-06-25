//
//  Controller.swift
//  C19X
//
//  Created by Freddy Choi on 23/05/2020.
//  Copyright © 2020 C19X. All rights reserved.
//

import Foundation
import CoreBluetooth
import os

/**
 Controller for encapsulating all application data and logic.
 */
protocol Controller {
    var settings: Settings { get }
    var transceiver: Transceiver? { get }

    /// Delegates for receiving application events.
    var delegates: [ControllerDelegate] { get set }
    
    /**
     Reset all application data.
     */
    func reset(registration: Bool, contacts: Bool)
    
    /**
     Notify controller that app has entered foreground mode.
     */
    func foreground(_ source: String)
    
    /**
     Notify controller that app has entered background mode.
     */
    func background(_ source: String)
    
    /**
     Synchronise device data with server data.
     */
    func synchronise(_ immediately: Bool)
    
    /**
     Set health status, locally and remotely.
     */
    func status(_ setTo: Status)
    
    /**
     Export contacts.
     */
    func export()
}

enum ControllerState: String {
    case foreground, background
}

class ConcreteController : NSObject, Controller, ReceiverDelegate {
    private let log = OSLog(subsystem: "org.c19x.logic", category: "Controller")
    var delegates: [ControllerDelegate] = []

    private let database: Database = ConcreteDatabase()
    private let network: Network = ConcreteNetwork(Settings.shared)
    private let riskAnalysis: RiskAnalysis = ConcreteRiskAnalysis()
    let settings = Settings.shared
    var transceiver: Transceiver?
    
    override init() {
        os_log("init", log: self.log, type: .debug)
        if settings.registrationState() == .registering {
            settings.registrationState(.unregistered)
        }
    }
    
    func reset(registration: Bool = true, contacts: Bool = true) {
        os_log("reset (registration=%s,contacts=%s)", log: self.log, type: .debug, registration.description, contacts.description)
        if registration {
            settings.reset()
        }
        if contacts {
            database.remove(Date().advanced(by: TimeInterval.day))
        }
        if !contacts && !registration {
            simulateCrash(after: 5)
        }
    }
    
    func simulateCrash(after: Double) {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + after) {
            os_log("simulateCrash (after=%s)", log: self.log, type: .fault, after.description)
            // CRASH
            if ([0][1] == 1) {
                exit(0)
            }
            exit(1)
        }
    }
    
    func foreground(_ source: String) {
        os_log("foreground (source=%s)", log: self.log, type: .debug, source)
        checkRegistration()
        initialiseTransceiver()
        applySettings()
        synchronise()
        delegates.forEach{ $0.controller(.foreground) }
    }
    
    func background(_ source: String) {
        os_log("background (source=%s)", log: self.log, type: .debug, source)
        delegates.forEach{ $0.controller(.background) }
    }
    
    func synchronise(_ immmediately: Bool = false) {
        os_log("synchronise (immediately=%s)", log: self.log, type: .debug, immmediately.description)
        synchroniseTime(immmediately)
        synchroniseStatus()
        synchroniseMessage(immmediately)
        synchroniseSettings(immmediately)
        synchroniseInfectionData(immmediately)
    }
    
    func status(_ setTo: Status) {
        let (from, _, _) = settings.status()
        os_log("Set status (from=%s,to=%s)", log: self.log, type: .debug, from.description, setTo.description)
        // Set status locally
        let _ = settings.status(setTo)
        applySettings()
        // Set status remotely
        synchroniseStatus()
    }
    
    /**
     Register device if required.
     */
    private func checkRegistration() {
        os_log("Registration (state=%s)", log: self.log, type: .debug, settings.registrationState().rawValue)
        guard settings.registrationState() == .unregistered else {
            return
        }
        os_log("Registration required", log: self.log, type: .debug)
        settings.registrationState(.registering)
        network.getRegistration { serialNumber, sharedSecret, error in
            guard let serialNumber = serialNumber, let sharedSecret = sharedSecret, error == nil else {
                self.settings.registrationState(.unregistered)
                os_log("Registration failed (error=%s)", log: self.log, type: .fault, String(describing: error))
                return
            }
            guard let success = self.settings.registration(serialNumber: serialNumber, sharedSecret: sharedSecret), success else {
                self.settings.registrationState(.unregistered)
                os_log("Registration failed (error=secureStorageFailed)", log: self.log, type: .fault)
                return
            }
            os_log("Registration successful (serialNumber=%s)", log: self.log, type: .debug, serialNumber.description)
            self.delegates.forEach { $0.registration(serialNumber)}
            
            // Tasks after registration
            self.initialiseTransceiver()
            self.synchroniseStatus()
            self.synchroniseMessage()
        }
    }
    
    /**
     Initialise transceiver.
     */
    private func initialiseTransceiver() {
        guard transceiver == nil else {
            return
        }
        os_log("Initialise transceiver", log: self.log, type: .debug)
        guard let (serialNumber, sharedSecret) = settings.registration() else {
            os_log("Initialise transceiver failed (error=unregistered)", log: self.log, type: .fault)
            return
        }
        transceiver = ConcreteTransceiver(sharedSecret, codeUpdateAfter: 120)
        transceiver?.append(self)
        os_log("Initialise transceiver successful (serialNumber=%s)", log: self.log, type: .debug, serialNumber.description)
        delegates.forEach { $0.transceiver(self.transceiver!) }
    }

    /**
     Synchronise time with server (once a day)
     */
    private func synchroniseTime(_ immediately: Bool = false) {
        let (_,timestamp) = settings.timeDelta()
        guard immediately || oncePerDay(timestamp) else {
            os_log("Synchronise time deferred (timestamp=%s)", log: self.log, type: .debug, timestamp.description)
            return
        }
        os_log("Synchronise time", log: self.log, type: .debug)
        network.synchroniseTime() { timeDelta, error  in
            guard let timeDelta = timeDelta, error == nil else {
                os_log("Synchronise time failed (error=%s)", log: self.log, type: .fault, String(describing: error))
                return
            }
            os_log("Synchronise time successful", log: self.log, type: .debug)
            self.settings.timeDelta(timeDelta)
        }
    }
    
    /**
     Synchronise status with server
     */
    private func synchroniseStatus() {
        let (local,timestamp,remoteTimestamp) = settings.status()
        let pattern = settings.pattern()
        guard timestamp != Date.distantPast else {
            // Only share authorised status data
            return
        }
        guard remoteTimestamp < timestamp else {
            // Synchronised already
            return
        }
        os_log("Synchronise status", log: self.log, type: .debug)
        guard let (serialNumber, sharedSecret) = settings.registration() else {
            os_log("Synchronise status failed (error=unregistered)", log: self.log, type: .fault)
            return
        }
        network.postStatus(local, pattern: pattern, serialNumber: serialNumber, sharedSecret: sharedSecret) { status, error in
            guard error == nil else {
                os_log("Synchronise status failed (error=%s)", log: self.log, type: .fault, String(describing: error))
                return
            }
            guard let remote = status, remote == local else {
                os_log("Synchronise status failed (error=mismatch)", log: self.log, type: .fault)
                return
            }
            os_log("Synchronise status successful (remote=%s)", log: self.log, type: .debug, remote.description)
            self.settings.statusDidUpdateAtServer()
        }
    }
    
    /**
     Synchronise personal message with server (once a day)
     */
    private func synchroniseMessage(_ immediately: Bool = false) {
        let (_, timestamp) = settings.message()
        guard immediately || oncePerDay(timestamp) else {
            os_log("Synchronise message deferred (timestamp=%s)", log: self.log, type: .debug, timestamp.description)
            return
        }
        os_log("Synchronise message", log: self.log, type: .debug)
        guard let (serialNumber, sharedSecret) = settings.registration() else {
            os_log("Synchronise message failed (error=unregistered)", log: self.log, type: .fault)
            return
        }
        network.getMessage(serialNumber: serialNumber, sharedSecret: sharedSecret) { message, error in
            guard let message = message, error == nil else {
                os_log("Synchronise message failed (error=%s)", log: self.log, type: .fault, String(describing: error))
                return
            }
            guard let _ = self.settings.message(message) else {
                os_log("Synchronise message failed (error=secureStorageFailed)", log: self.log, type: .fault)
                return
            }
            os_log("Synchronise message successful", log: self.log, type: .debug)
            self.delegates.forEach { $0.message(message) }
        }
    }

    /**
     Synchronise settings with server (once a day)
     */
    private func synchroniseSettings(_ immediately: Bool = false) {
        let (_, timestamp) = settings.get()
        guard immediately || oncePerDay(timestamp) else {
            os_log("Synchronise settings deferred (timestamp=%s)", log: self.log, type: .debug, timestamp.description)
            return
        }
        os_log("Synchronise settings", log: self.log, type: .debug)
        network.getSettings() { serverSettings, error  in
            guard let serverSettings = serverSettings, error == nil else {
                os_log("Synchronise settings failed (error=%s)", log: self.log, type: .fault, String(describing: error))
                return
            }
            self.settings.set(serverSettings)
            os_log("Synchronise settings successful", log: self.log, type: .debug)
            self.applySettings()
        }
    }
    
    /**
     Synchronise infection data with server (once a day)
     */
    private func synchroniseInfectionData(_ immediately: Bool = false) {
        let (_, timestamp) = settings.infectionData()
        guard immediately || oncePerDay(timestamp) else {
            os_log("Synchronise infection data deferred (timestamp=%s)", log: self.log, type: .debug, timestamp.description)
            return
        }
        os_log("Synchronise infection data", log: self.log, type: .debug)
        network.getInfectionData() { infectionData, error  in
            guard let infectionData = infectionData, error == nil else {
                os_log("Synchronise infection data failed (error=%s)", log: self.log, type: .fault, String(describing: error))
                return
            }
            self.settings.infectionData(infectionData)
            os_log("Synchronise infection data successful", log: self.log, type: .debug)
            self.applySettings()
        }
    }
    
    /**
     Tests whether daily update should be executed.
     */
    func oncePerDay(_ lastUpdate: Date, now: Date = Date()) -> Bool {
        // Must update if over one day has elapsed
        if (lastUpdate.timeIntervalSince(now) > TimeInterval.day) {
            return true
        }
        // Otherwise update overnight only
        let (windowStart, windowEnd) = (0, 6)
        let hour = Calendar.current.component(Calendar.Component.hour, from: now)
        guard hour >= windowStart && hour < windowEnd else {
            return false
        }
        // Ensure update wasn't completely recently
        let window = TimeInterval((windowEnd - windowStart) * 60 * 60)
        let elapsed = abs(lastUpdate.timeIntervalSince(now))
        guard elapsed > window else {
            return false
        }
        return true
    }
    
    /**
     Apply current settings now.
     */
    private func applySettings() {
        // Enforce retention period
        let removeBefore = Date().addingTimeInterval(-settings.retentionPeriod())
        database.remove(removeBefore)
        settings.contacts(database.contacts.count, lastUpdate: database.contacts.last?.time)
        delegates.forEach { $0.database(database.contacts) }
        
        // Conduct risk analysis
        riskAnalysis.advice(contacts: database.contacts, settings: settings) { advice, contactStatus, exposureOverTime, exposureProximity in
            let _ = self.settings.advice(advice)
            let _ = self.settings.contacts(contactStatus)
            let pattern = ContactPattern(exposureProximity.description.replacingOccurrences(of: " ", with: ""))
            let _ = self.settings.pattern(pattern)
            self.delegates.forEach { $0.advice(advice, contactStatus) }
        }
    }
    
    func export() {
        do {
            let fileURL = try FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("contacts.csv")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var string = "timestamp,rssi\n"
            database.contacts.forEach() { contact in
                guard let time = contact.time else {
                    return
                }
                let timestamp = dateFormatter.string(from: time)
                let row = timestamp + "," + contact.rssi.description + "\n"
                string.append(row)
            }
            try string.write(to: fileURL, atomically: true, encoding: .utf8)
            os_log("export", log: log, type: .debug)
        } catch {
            os_log("Failed to export contacts to storage (error=%s)", log: log, type: .fault, String(describing: error))
        }
    }
    
    // MARK:- ReceiverDelegate
    
    func receiver(didDetect: BeaconCode, rssi: RSSI) {
        database.insert(time: Date(), code: didDetect, rssi: rssi)
        let timestamp = settings.contacts(database.contacts.count)
        os_log("Contact logged (code=%s,rssi=%s,count=%d,timestamp=%s)", log: log, type: .debug, didDetect.description, rssi.description, database.contacts.count, timestamp.description)
        delegates.forEach { $0.transceiver(timestamp) }
    }
    
    func receiver(didUpdateState: CBManagerState) {
        os_log("Bluetooth state updated (state=%s)", log: log, type: .debug, didUpdateState.description)
        delegates.forEach { $0.transceiver(didUpdateState)}
    }
}

protocol ControllerDelegate {
    func controller(_ didUpdateState: ControllerState)
    
    func registration(_ serialNumber: SerialNumber)
    
    func transceiver(_ initialised: Transceiver)
    
    func transceiver(_ didUpdateState: CBManagerState)
    
    func transceiver(_ didDetectContactAt: Date)
    
    func message(_ didUpdateTo: Message)
    
    func database(_ didUpdateContacts: [Contact])
    
    func advice(_ didUpdateTo: Advice, _ contactStatus: Status)
}
