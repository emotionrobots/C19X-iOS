//
//  Codes.swift
//  C19X
//
//  Created by Freddy Choi on 23/03/2020.
//  Copyright © 2020 C19X. All rights reserved.
//

import Foundation
import CryptoKit
import BigInt
import os

/**
 Day codes are derived from a shared secret that has been agreed with the central server on registration.
 Given a shared secret, a sequence of forward secure codes is created by recursively hashing (SHA)
 the hash of the shared secret, and taking the modulo of each hash value in reverse order as a long value
 code. It is cryptographically challenging to predict the next code given the previous codes. Each day
 is allocated a day code up to a finite number of days for simplicity.
 */
protocol DayCodes {
    func day() -> Day?
    func get() -> DayCode?
    func get(_ day: Day) -> DayCode?
}

typealias SharedSecret = Data
typealias DayCode = Int64
typealias Day = UInt

class ConcreteDayCodes : DayCodes {
    private let log = OSLog(subsystem: "org.c19x.beacon", category: "DayCodes")
    private let epoch = UInt64(ISO8601DateFormatter().date(from: "2020-01-01T00:00:00+0000")!.timeIntervalSince1970)
    private var values:[DayCode]
    
    init(_ sharedSecret: SharedSecret) {
        let days = 365 * 10
        let range = BigInt(DayCode.max)
        os_log("Generating forward secure day codes (days=%d,range=%s)", log: log, type: .debug, days, range.description)
        var hash = SHA256.hash(data: sharedSecret)
        values = [DayCode](repeating: 0, count: days)
        for i in (0 ... (days - 1)).reversed() {
            let hashData = Data(hash)
            let value = BigInt(hashData)
            values[i] = DayCode(value % range)
            hash = SHA256.hash(data: hashData)
        }
        os_log("Generated forward secure day codes (days=%d,range=%s)", log: log, type: .debug, days, range.description)
    }
    
    func day() -> Day? {
        let now = UInt64(NSDate().timeIntervalSince1970)
        let (today,_) = (now - epoch).dividedReportingOverflow(by: UInt64(24 * 60 * 60))
        let day = Day(today)
        guard day >= 0, day < values.count else {
            os_log("Day out of range", log: log, type: .fault)
            return nil
        }
        return day
    }
    
    func get() -> DayCode? {
        guard let day = day() else {
            os_log("Day out of range", log: log, type: .fault)
            return nil
        }
        return values[Int(day)]
    }
    
    func get(_ day: Day) -> DayCode? {
        guard day >= 0, day < values.count else {
            os_log("Day out of range", log: log, type: .fault)
            return nil
        }
        return values[Int(day)]
    }
}
