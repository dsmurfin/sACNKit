//
//  sACNMerger.swift
//
//  Copyright (c) 2023 Daniel Murfin
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// sACN Merger
///
/// Provides merging of DMX512-A NULL start code (0x00) data.
/// It also supports per-address priority start code (0xdd) merging.
///
/// When asked to calculate the merge the following buffers are updated:
///
/// - Merged levels (the winning level), using HTP where equal priorities exists.
/// - Winners: An identifier for the winning source.
///
/// Important: All calls to this class should be performed on the same `DispatchQueue`.
public class sACNMerger {
    
    /// The unique identifer for this merger (this matches the sACN universe it merges).
    private (set) var id: UInt16
    
    /// The (512) merged levels.
    ///
    /// Any 'unsourced' slot is set to 0.
    private (set) var levels: [UInt8]
    
    /// The (512) per-address priorities for each winning slot.
    ///
    /// Winning priorities are always tracked here, even if not using per-address priority.
    private var perAddressPriorities: [UInt8]
    
    /// The (512) identifiers (or `nil` if there is no winner) of the winning `MergerSource`s for the merge on a each slot.
    ///
    /// Winning owners are always tracked here.
    private (set) var winners: [UUID?]

    /// Whether per-address priority packets should be transmitted.
    ///
    /// This is used if the result of the merge needs to be sent over sACN, otherwise set to `nil`.
    private var perAddressPrioritiesActive: Bool?
    
    /// The universe priority that should be transmitted.
    ///
    /// This is used if the result of the merge needs to be sent over sACN, otherwise set to `nil`.
    private var universePriority: UInt8?
    
    /// The maximum number of sources this merger will listen to.
    ///
    /// To allow unlimited sources set this to `nil`.
    private var sourceLimit: Int?
    
    /// The sources added to this merger.
    private var sources: [UUID: MergerSource]

    /// Initializes a new merger with optional configuration.
    ///
    /// Configuration provides options used when the result of the merge will be output over sACN,
    /// and for limits on the number of sources. If these are not required configuration does not need
    /// to be provided.
    ///
    /// - Parameters:
    ///    - config: The `MergerConfig` to be used to configure the merger.
    ///    
    public init(id: UInt16, config: sACNMergerConfig? = nil) {
        self.id = id
        self.levels = Array(repeating: 0, count: DMX.addressCount)
        self.perAddressPriorities = Array(repeating: 0, count: DMX.addressCount)
        self.winners = Array(repeating: nil, count: DMX.addressCount)
        if let config {
            self.perAddressPrioritiesActive = config.transmitPerAddressPriorities
            self.universePriority = config.universePriority
            self.sourceLimit = config.sourceLimit
        }
        self.sources = [:]
    }
    
    // MARK: Add / Remove
    
    /// Adds a new source to the merger, if the maximum number of sources hasn't been reached.
    ///
    /// - Parameters:
    ///    - sourceId: A unique identifier of the source (this is most likely the sACN Source CID).
    ///
    /// - Throws: A `MergerError` if adding the source fails.
    ///
    /// - Returns: A unique identifier for the source which is used to access the source data later.
    ///
    public func addSource(identified sourceId: UUID) throws {
        if let sourceLimit, sources.count >= sourceLimit {
            throw sACNMergerError.sourceLimitReached
        }
        guard sources[sourceId] == nil else { throw sACNMergerError.sourceExistsWithIdentifier(sourceId) }
        let source = MergerSource(id: sourceId)
        sources[sourceId] = source
    }
    
    /// Removes the source from the merger.
    ///
    /// This causes the merger to recalculate its output.
    ///
    /// - Parameters:
    ///    - sourceId: The unique identifier of the source which should be removed.
    ///    - mergerId: The unique identifier of the merger from which the source should be removed.
    ///
    /// - Throws: A `MergerError` if removing the source fails.
    ///
    public func removeSource(identified sourceId: UUID) throws {
        guard let source = sources[sourceId] else { throw sACNMergerError.noSourceWithIdentifier(sourceId) }
        
        // merge the source with unsourced priorities to remove this source from the merge output
        source.addressPriorities = Array(repeating: 0, count: DMX.addressCount)
        for index in 0..<DMX.addressCount {
            mergeNewPriority(using: source, at: index)
        }
        
        // also update universe priority and per-address priority active outputs if needed
        if let perAddressPrioritiesActive, perAddressPrioritiesActive && !source.usingUniversePriority {
            source.usingUniversePriority = true
            recalculatePerAddressPrioritiesActive()
        }
        if let universePriority, source.universePriority >= universePriority {
            source.universePriority = 0
            recalculateUniversePriority()
        }
        
        // now that output no longer refers to this source, remove it
        sources.removeValue(forKey: sourceId)
    }
    
    // MARK: Update
    
    /// Updates the levels for a source.
    ///
    /// This causes the merger to recalculate its output. The source will only be included in the merge
    /// if it has a priority for that slot, otherwise the level is saved for when a priority is provided.
    ///
    /// If `newLevelsCount` is less than 512, the remaining levels will be set to 0.
    ///
    /// - Parameters:
    ///    - sourceId: The unique identifier of the source which should be updated.
    ///    - newLevels: The (512) new NULL start code (0x00) levels.
    ///    - newLevelsCount: The number of levels in `newLevels` which are valid. If less than 512, remaining levels will be set to 0.
    ///
    /// - Throws: A `MergerError` if updating the source fails.
    ///
    public func updateLevelsForSource(identified sourceId: UUID, newLevels: [UInt8], newLevelsCount: Int) throws {
        guard let source = sources[sourceId] else { throw sACNMergerError.noSourceWithIdentifier(sourceId) }
        
        // levels count must be valid and there must be levels
        guard newLevelsCount > 0 && newLevelsCount <= DMX.addressCount && newLevels.count == newLevelsCount else { throw sACNMergerError.invalidLevelCount }
        
        let oldLevelsCount = source.levelCount
        source.levelCount = newLevelsCount
        
        if newLevelsCount != oldLevelsCount || (newLevels.prefix(newLevelsCount) != source.levels.prefix(newLevelsCount)) {
            if sources.count == 1 {
                updateLevelsSingleSource(using: source, newLevels: newLevels, oldLevelsCount: oldLevelsCount, newLevelsCount: newLevelsCount)
            } else {
                updateLevelsMultiSource(using: source, newLevels: newLevels, oldLevelsCount: oldLevelsCount, newLevelsCount: newLevelsCount)
            }
        }
    }
    
    /// Updates the per-address priorities for a source.
    ///
    /// This causes the merger to recalculate its output. The source will only be included in the merge
    /// if it has a priority for that slot.
    ///
    /// If `newPrioritiesCount` is less than 512, the remaining priorities will be set to 0 (unsourced). To
    /// remove per-address priority for this source and revert to universe priority, call `removePAP`.
    ///
    /// - Parameters:
    ///    - sourceId: The unique identifier of the source which should be updated.
    ///    - newPriorities: The (512) new per-address priority start code (0xdd) levels.
    ///    - newPrioritiesCount: The number of priorities in `newPriorities` which are valid. If less than 512, remaining priorities will be set to 0 (unsourced).
    ///
    /// - Throws: A `MergerError` if updating the source fails.
    ///
    public func updatePAPForSource(identified sourceId: UUID, newPriorities: [UInt8], newPrioritiesCount: Int) throws {
        guard let source = sources[sourceId] else { throw sACNMergerError.noSourceWithIdentifier(sourceId) }
        
        // priorities count must be valid and there must be priorities
        guard newPrioritiesCount > 0 && newPrioritiesCount <= DMX.addressCount && newPriorities.count == newPrioritiesCount else { throw sACNMergerError.invalidLevelCount }
        
        let oldPerAddressPrioritiesCount = source.perAddressPriorityCount
        source.perAddressPriorityCount = newPrioritiesCount
        
        if newPrioritiesCount != oldPerAddressPrioritiesCount || (newPriorities.prefix(newPrioritiesCount) != source.addressPriorities.prefix(newPrioritiesCount)) {
            source.usingUniversePriority = false
            if perAddressPrioritiesActive != nil {
                perAddressPrioritiesActive = true
            }
            if sources.count == 1 {
                updatePAPSingleSource(using: source, newPriorities: newPriorities, oldPrioritiesCount: oldPerAddressPrioritiesCount, newPrioritiesCount: newPrioritiesCount)
            } else {
                updatePAPMultiSource(using: source, newPriorities: newPriorities, oldPrioritiesCount: oldPerAddressPrioritiesCount, newPrioritiesCount: newPrioritiesCount)
            }
        }
    }
    
    /// Updates the universe priority for a source.
    ///
    /// This causes the merger to recalculate its output. The source will only be included in the merge if it has priority for that slot.
    ///
    /// If this source has per-address priorities set via `updatePAP`, this will have no effect until `removePAP` has
    /// been called. If this source does not have per-address priorities, then the universe priority is converted to per-address
    /// priority for each slot, which is then used for the merge, therefore a universe priority of 0 will be converted to 1.
    ///
    /// - Parameters:
    ///    - sourceId: The unique identifier of the source which should be updated.
    ///    - priority: The new universe priority.
    ///
    /// - Throws: A `MergerError` if updating the source fails.
    ///
    public func updateUniversePriorityForSource(identified sourceId: UUID, priority: UInt8) throws {
        guard let source = sources[sourceId] else { throw sACNMergerError.noSourceWithIdentifier(sourceId) }
        
        // only continue if the universe priority is different or uninitialized
        guard universePriority != source.universePriority || source.universePriorityUninitialized else { return }
        source.universePriorityUninitialized = false
        
        // is this the curent universe priority output?
        let wasMax: Bool = {
            if let universePriority, source.universePriority >= universePriority {
                return true
            }
            return false
        }()
        
        let singleSource = sources.count == 1
        
        // update the universe priority for the source
        source.universePriority = priority
        
        // if there are no per-address priorities
        if source.usingUniversePriority {
            let perAddressPriority = priority == 0 ? 1 : priority
            
            if singleSource {
                updateUniversePrioritySingleSource(using: source, newPriority: perAddressPriority)
            } else {
                updateUniversePriorityMultiSource(using: source, newPriority: perAddressPriority)
            }
        }
        
        // also update the universe priority output if needed
        if let universePriority {
            if singleSource || priority >= universePriority {
                self.universePriority = priority
            } else if wasMax {
                // this used to be the output, but may not be anymore, so recalculate
                recalculateUniversePriority()
            }
        }
    }
    
    /// Removes the per-address priorities for a source.
    ///
    /// This causes the merger to recalculate its output. The source will only be included in the merge
    /// if it has a priority for that slot.
    ///
    /// Per-address priority start code (0xdd) data can time out in the same way as NULL start code (0x00)
    /// level data. This provides a method to immediately turn off this data for a source.
    ///
    /// - Parameters:
    ///    - sourceId: The unique identifier of the source which should be updated.
    ///
    /// - Throws: A `MergerError` if updating the source fails.
    ///
    public func removePAP(forSourceIdentified sourceId: UUID) throws {
        guard let source = sources[sourceId] else { throw sACNMergerError.noSourceWithIdentifier(sourceId) }
        
        // mark the source as using universe priority
        let papWasActive = !source.usingUniversePriority
        source.usingUniversePriority = true
        
        // merge the levels again (this time using universe priority)
        source.addressPriorities.replaceSubrange(0..<DMX.addressCount, with: repeatElement(source.universePriority == 0 ? 1 : source.universePriority, count: DMX.addressCount))        
        for slot in 0..<DMX.addressCount {
            mergeNewPriority(using: source, at: slot)
        }
        
        // update the per-address priority active output if needed
        if perAddressPrioritiesActive != nil && papWasActive {
            recalculatePerAddressPrioritiesActive()
        }
    }
    
    // MARK: Access
    
    /// Returns an optional source for the identifier provided.
    ///
    /// - Parameters:
    ///    - id: The identifier of the source.
    ///
    /// - Returns: An optional `MergerSource`.
    func source(identified id: UUID) -> MergerSource? {
        return sources[id]
    }
    
    // MARK: - Private
    
    /// Copies new levels into the source and the outputs.
    ///
    /// Assumes all parameters are valid and there is only one source.
    ///
    /// - Parameters:
    ///    - source: The source which should be updated.
    ///    - newLevels: The new (512) levels for this source.
    ///    - oldLevelsCount: The number of levels which were previously valid.
    ///    - newLevelsCount: The number of levels in `newLevels` which are valid.
    ///
    private func updateLevelsSingleSource(using source: MergerSource, newLevels: [UInt8], oldLevelsCount: Int, newLevelsCount: Int) {
        // replace the levels for this source
        source.levels.replaceSubrange(0..<newLevelsCount, with: newLevels)
        
        // replace the merge levels
        for slot in 0..<newLevelsCount where perAddressPriorities[slot] > 0 {
            levels[slot] = newLevels[slot]
        }
        
        // if there are less levels than last time, make the rest 0
        if oldLevelsCount > newLevelsCount {
            source.levels.replaceSubrange(newLevelsCount..<oldLevelsCount, with: Array(repeating: 0, count: oldLevelsCount-newLevelsCount))
            levels.replaceSubrange(newLevelsCount..<oldLevelsCount, with: Array(repeating: 0, count: oldLevelsCount-newLevelsCount))
        }
    }
    
    /// Updates the source levels and recalculates outputs.
    ///
    /// Assumes all parameters are valid and there are multiple sources.
    ///
    /// - Parameters:
    ///    - source: The source which should be updated.
    ///    - newLevels: The new (512) levels for this source.
    ///    - oldLevelsCount: The number of levels which were previously valid.
    ///    - newLevelsCount: The number of levels in `newLevels` which are valid.
    ///
    private func updateLevelsMultiSource(using source: MergerSource, newLevels: [UInt8], oldLevelsCount: Int, newLevelsCount: Int) {
        // replace the levels for this source
        source.levels.replaceSubrange(0..<newLevelsCount, with: newLevels)
        
        // merge levels
        for slot in 0..<newLevelsCount {
            mergeNewLevel(using: source, at: slot)
        }
        
        // if there are less levels than last time, merge to new levels
        if oldLevelsCount > newLevelsCount {
            source.levels.replaceSubrange(newLevelsCount..<oldLevelsCount, with: Array(repeating: 0, count: oldLevelsCount-newLevelsCount))
            for slot in newLevelsCount..<oldLevelsCount {
                mergeNewLevel(using: source, at: slot)
            }
        }
    }
    
    /// Copies new per-address priorities into the source and the outputs.
    ///
    /// Also updates winner and outputs.
    ///
    /// Assumes all parameters are valid and there is only one source.
    ///
    /// - Parameters:
    ///    - source: The source which should be updated.
    ///    - newPriorities: The new (512) priorities for this source.
    ///    - oldPrioritiesCount: The number of priorities which were previously valid.
    ///    - newPrioritiesCount: The number of priorities in `newPriorities` which are valid.
    ///
    private func updatePAPSingleSource(using source: MergerSource, newPriorities: [UInt8], oldPrioritiesCount: Int, newPrioritiesCount: Int) {
        // replace the priorities for this source and merge
        source.addressPriorities.replaceSubrange(0..<newPrioritiesCount, with: newPriorities)
        perAddressPriorities.replaceSubrange(0..<newPrioritiesCount, with: newPriorities)

        // replace the merge levels
        for slot in 0..<newPrioritiesCount {
            if newPriorities[slot] == 0 {
                levels[slot] = 0
                winners[slot] = nil
            } else {
                levels[slot] = source.levels[slot]
                winners[slot] = source.id
            }
        }

        // if there are less priorities than last time, make the rest 0
        if oldPrioritiesCount > newPrioritiesCount {
            source.addressPriorities.replaceSubrange(newPrioritiesCount..<oldPrioritiesCount, with: Array(repeating: 0, count: oldPrioritiesCount-newPrioritiesCount))
            perAddressPriorities.replaceSubrange(newPrioritiesCount..<oldPrioritiesCount, with: Array(repeating: 0, count: oldPrioritiesCount-newPrioritiesCount))
            
            for slot in newPrioritiesCount..<oldPrioritiesCount {
                levels[slot] = 0
                winners[slot] = nil
            }
        }
    }
    
    /// Updates the source per-address priorities and recalculates outputs.
    ///
    /// Assumes all parameters are valid and there are multiple sources.
    ///
    /// - Parameters:
    ///    - source: The source which should be updated.
    ///    - newPriorities: The new (512) priorities for this source.
    ///    - oldPrioritiesCount: The number of priorities which were previously valid.
    ///    - newPrioritiesCount: The number of priorities in `newPriorities` which are valid.
    ///
    private func updatePAPMultiSource(using source: MergerSource, newPriorities: [UInt8], oldPrioritiesCount: Int, newPrioritiesCount: Int) {
        // replace the priorities for this source
        source.addressPriorities.replaceSubrange(0..<newPrioritiesCount, with: newPriorities)

        // replace the merge priorities
        for slot in 0..<newPrioritiesCount {
            mergeNewPriority(using: source, at: slot)
        }

        // if there are less priorities than last time, make the rest 0
        if oldPrioritiesCount > newPrioritiesCount {
            source.addressPriorities.replaceSubrange(newPrioritiesCount..<oldPrioritiesCount, with: Array(repeating: 0, count: oldPrioritiesCount-newPrioritiesCount))
            
            for slot in newPrioritiesCount..<oldPrioritiesCount {
                mergeNewPriority(using: source, at: slot)
            }
        }
    }
    
    /// Copies the new universe priority (converted to per-address priorities) into the source and the outputs.
    ///
    /// Also updates winner and outputs.
    ///
    /// Assumes all parameters are valid, there is only one source and universe priority changed.
    ///
    /// - Parameters:
    ///    - source: The source which should be updated.
    ///    - newPriority: The new universe priority for this source.
    ///
    private func updateUniversePrioritySingleSource(using source: MergerSource, newPriority: UInt8) {
        // replace the priorities for this source and merge
        for slot in 0..<DMX.addressCount {
            source.addressPriorities[slot] = newPriority
            perAddressPriorities[slot] = newPriority
            winners[slot] = source.id
        }
        
        levels.replaceSubrange(0..<DMX.addressCount, with: source.levels)
    }
    
    /// Updates the source universe priority (converted to per-address priorities) and recalculates outputs.
    ///
    /// Assumes all parameters are valid, there are multiple sources and universe priority changed.
    ///
    /// - Parameters:
    ///    - source: The source which should be updated.
    ///    - newPriority: The new universe priority for this source.
    ///
    private func updateUniversePriorityMultiSource(using source: MergerSource, newPriority: UInt8) {
        // at this point universe priority is know to have changed, so update and merge
        source.addressPriorities.replaceSubrange(0..<DMX.addressCount, with: repeatElement(newPriority, count: DMX.addressCount))
        for slot in 0..<DMX.addressCount {
            mergeNewPriority(using: source, at: slot)
        }
    }
    
    // MARK: Merge Slot
    
    /// Merges a source's new level on a slot.
    ///
    /// This assumes the priority has not changed since the last merge.
    ///
    /// - Parameters:
    ///    - source: The source to be modified.
    ///    - slot: The slot for which to calculate new values.
    ///
    private func mergeNewLevel(using source: MergerSource, at slot: Int) {
        // perform an HTP merge when source priority is non-zero and equal to the winning priority
        guard source.addressPriorities[slot] > 0 && source.addressPriorities[slot] == perAddressPriorities[slot] else { return }

        if source.levels[slot] > levels[slot] {
            // take ownership if source level is greater than current level
            levels[slot] = source.levels[slot]
            winners[slot] = source.id
        } else if source.id == winners[slot] && source.levels[slot] < levels[slot] {
            // this source is the current winner and its level decreased check for a new winner
            recalculateWinningLevel(using: source, at: slot)
        }
    }

    /// Merges a source's new priority on a slot.
    ///
    /// This assumes the level has not changed since the last merge.
    ///
    /// - Parameters:
    ///    - source: The source to be modified.
    ///    - slot: The slot for which to calculate new values.
    ///
    private func mergeNewPriority(using source: MergerSource, at slot: Int) {
        if source.addressPriorities[slot] > perAddressPriorities[slot] {
            // take ownership if source priority is greater than the current priority
            levels[slot] = source.levels[slot]
            winners[slot] = source.id
            perAddressPriorities[slot] = source.addressPriorities[slot]
        } else if source.id != winners[slot] {
            // if this source is not the current winner but has the same priority
            // take ownership if it has a higher level
            if source.addressPriorities[slot] > 0 && source.addressPriorities[slot] == perAddressPriorities[slot] && source.levels[slot] > levels[slot] {
                levels[slot] = source.levels[slot]
                winners[slot] = source.id
                perAddressPriorities[slot] = source.addressPriorities[slot]
            }
        } else if source.addressPriorities[slot] < perAddressPriorities[slot] {
            // if this source is the current winner and its priority has decreased
            // check for a new owner
            recalculateWinningPriority(using: source, at: slot)
        }
    }
    
    // MARK: Recalculate
    
    /// Recalculates the winning level for a slot.
    ///
    /// This assumes the priority has not changed since the last merge.
    ///
    /// - Parameters:
    ///    - source: The source to use as the initial winner.
    ///    - slot: The slot for which to calculate new values.
    ///
    private func recalculateWinningLevel(using source: MergerSource, at slot: Int) {
        // make this source the winner
        levels[slot] = source.levels[slot]
        
        // check if any other sources beat the current source
        for otherSource in sources.values where otherSource.id != source.id {
            let candidateLevel = otherSource.levels[slot]
            if otherSource.addressPriorities[slot] == perAddressPriorities[slot] && candidateLevel > levels[slot] {
                levels[slot] = candidateLevel
                winners[slot] = otherSource.id
            }
        }
    }
    
    /// Recalculates the winning priority for a slot.
    ///
    /// This assumes the level has not changed since the last merge.
    ///
    /// - Parameters:
    ///    - source: The source to use as the initial winner.
    ///    - slot: The slot for which to calculate new values.
    ///
    private func recalculateWinningPriority(using source: MergerSource, at slot: Int) {
        // make this source the winner
        perAddressPriorities[slot] = source.addressPriorities[slot]
        
        // when unsourced (priority 0) set the level to 0 and no winner
        if source.addressPriorities[slot] == 0 {
            levels[slot] = 0
            winners[slot] = nil
        }
        
        // check if any other source beat the current source
        for otherSource in sources.values where otherSource.id != source.id {
            if otherSource.addressPriorities[slot] > perAddressPriorities[slot] || (otherSource.addressPriorities[slot] == perAddressPriorities[slot] && otherSource.levels[slot] > levels[slot]) {
                levels[slot] = otherSource.levels[slot]
                winners[slot] = otherSource.id
                perAddressPriorities[slot] = otherSource.addressPriorities[slot]
            }
        }
    }
    
    /// Recalculates the value of per-address priorities active.
    ///
    /// This should only be called after first checking whether `perAddressPrioritiesActive` is not `nil`.
    private func recalculatePerAddressPrioritiesActive() {
        perAddressPrioritiesActive = sources.contains(where: { !$0.value.usingUniversePriority })
    }
    
    /// Recalculates the value of universe priority.
    ///
    /// This should only be called after first checking whether `universePriority` is not `nil`.
    private func recalculateUniversePriority() {
        universePriority = sources.max { a, b in a.value.universePriority < b.value.universePriority }?.value.universePriority ?? 0
    }
    
}

/// Merger Config
///
/// Optionally used for initial configuration of a merger.
public struct sACNMergerConfig {
    
    /// Whether per-address priority packets should be transmitted.
    ///
    /// This is used if the result of the merge needs to be sent over sACN, otherwise set to `nil`.
    public var transmitPerAddressPriorities: Bool?
    
    /// The universe priority that should be transmitted.
    ///
    /// This is used if the result of the merge needs to be sent over sACN, otherwise set to `nil`.
    public var universePriority: UInt8?
    
    /// The maximum number of sources this merger will listen to.
    ///
    /// To allow unlimited sources set this to `nil`.
    public var sourceLimit: Int?
    
}

/// Merger Error
/// 
public enum sACNMergerError: Error {
    
    /// There is already a merger with the universe requested.
    case mergerExistsWithUniverse(_ universe: UInt16)
    
    /// No merger was found with this universe.
    case noMergerWithUniverse(_ universe: UInt16)
    
    // MARK: Source
    
    /// There is already a merger source with the identifier requested.
    case sourceExistsWithIdentifier(_ id: UUID)
    
    /// No merger source was found with this identifer.
    case noSourceWithIdentifier(_ id: UUID)
    
    /// There are already the maximum specified number of sources for this merger.
    case sourceLimitReached
    
    /// The level count provided is invalid or no levels were provided.
    case invalidLevelCount
    
}
