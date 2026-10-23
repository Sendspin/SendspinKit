struct PCMFlowDiagnostics: Sendable {
    var writtenFrames: Int64 = 0
    var correctionDrops: Int64 = 0
    var missingFrames: Int64 = 0
    var reanchors: Int64 = 0
    var clearedFrames: Int64 = 0
    var ringFrames: Int64 = 0
    var writes: Int64 = 0
    var lastWriteUs: Int64 = 0
    var maximumWriteGapUs: Int64 = 0
    var deliveryLeadUs: Int64 = 0

    var summary: String {
        "ring=\(ringFrames)f written=\(writtenFrames)f writes=\(writes)"
            + " correctionDrops=\(correctionDrops)f missing=\(missingFrames)f"
            + " reanchors=\(reanchors) cleared=\(clearedFrames)f"
            + " maxWriteGap=\(maximumWriteGapUs)us deliveryLead=\(deliveryLeadUs)us"
    }
}
