//
//  Item.swift
//  simStock3
//
//  Created by peiyu on 2025/12/14.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
