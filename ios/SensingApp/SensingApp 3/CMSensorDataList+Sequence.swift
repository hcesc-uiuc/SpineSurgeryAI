//
//  CMSensorDataList+Sequence.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//

import CoreMotion

extension CMSensorDataList: Sequence {
    public typealias Iterator = NSFastEnumerationIterator

    public func makeIterator() -> NSFastEnumerationIterator {
        return NSFastEnumerationIterator(self)
    }
}
