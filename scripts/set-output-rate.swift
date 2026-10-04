#!/usr/bin/env swift
// ABOUTME: Changes the default output device's nominal sample rate for route-change tests.
// ABOUTME: Validates supported rates and prints the previous rate for restoration.

import CoreAudio
import Foundation

struct RateError: Error, CustomStringConvertible {
    let description: String
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw RateError(description: "\(operation) failed: OSStatus \(status)")
    }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func readRate(_ device: AudioDeviceID) throws -> Float64 {
    var property = address(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &rate), "Read nominal rate")
    return rate
}

do {
    guard CommandLine.arguments.count == 2,
          let requested = Float64(CommandLine.arguments[1]), requested.isFinite, requested > 0
    else {
        throw RateError(description: "Usage: set-output-rate.swift <hz>")
    }
    var defaultOutput = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try check(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, 0, nil, &size, &device),
        "Resolve default output"
    )
    guard device != kAudioObjectUnknown else { throw RateError(description: "No default output device") }
    let previous = try readRate(device)
    var available = address(kAudioDevicePropertyAvailableNominalSampleRates)
    var rangesSize: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &available, 0, nil, &rangesSize), "Read supported rates size")
    var ranges = [AudioValueRange](
        repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
        count: Int(rangesSize) / MemoryLayout<AudioValueRange>.stride
    )
    try ranges.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { throw RateError(description: "No supported rates reported") }
        try check(AudioObjectGetPropertyData(device, &available, 0, nil, &rangesSize, base), "Read supported rates")
    }
    guard ranges.contains(where: { requested >= $0.mMinimum && requested <= $0.mMaximum }) else {
        let supported = ranges.map { "\($0.mMinimum)...\($0.mMaximum)" }.joined(separator: ", ")
        throw RateError(description: "Requested rate \(requested) is unsupported; previous=\(previous); supported=\(supported)")
    }
    var nominal = address(kAudioDevicePropertyNominalSampleRate)
    var rate = requested
    try check(AudioObjectSetPropertyData(device, &nominal, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate), "Set nominal rate")
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var observed = try readRate(device)
    while observed != requested, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
        observed = try readRate(device)
    }
    guard observed == requested else {
        throw RateError(description: "Rate readback timed out: previous=\(previous) requested=\(requested) observed=\(observed)")
    }
    print("previous=\(previous) new=\(observed) device=\(device)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
