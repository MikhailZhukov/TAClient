//
//  Item.swift
//  iTubeArchivist
//
//  Created by Mikhail Zhukov on 13.02.2026.
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
