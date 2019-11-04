//
//  SynthAudioSessionDelegate.swift
//  QRchestra
//
//  Created by Wenzhong Zhang on 2019-11-04.
//  Copyright © 2019 Wenzhong Zhang. All rights reserved.
//

import os.log
import AudioToolbox
import AVFoundation
import UIKit

enum MIDIMessage: UInt32 {
    case noteOn = 0x9, noteOff = 0x8
}

let kLowNote = 48
let kHighNote = 72
let kMidNode = 60

final class SynthAudioSession {
    let sampleUnit, ioUnit: AudioUnit
    let processingGraph: AUGraph
    var graphSampleRate: Double
    init?(sampleUnit: AudioUnit?, ioUnit: AudioUnit?, graph: AUGraph) {
        guard let gu = sampleUnit else { return nil }
        self.sampleUnit = gu
        guard let iu = ioUnit else { return nil }
        self.ioUnit = iu
        processingGraph = graph
        graphSampleRate = 44100.0
        configureAudioUnit()
    }
    func loadSynthFromPresetURL(_ presetUrl: URL) -> OSStatus {
        guard let data = CFURLCreateData(kCFAllocatorDefault, presetUrl as CFURL, .zero, false) else { return kAudioUnitErr_FileNotSpecified}
        let format: CFPropertyListFormat = .binaryFormat_v1_0
        let flags: CFOptionFlags = .zero
        var error: Unmanaged<CFError>?
        let presetPropertyList = CFPropertyListCreateData(kCFAllocatorDefault, data, format, flags, &error)
        if let error = error?.takeRetainedValue() {
            debugPrint(error)
            return -1
        }
        guard var presetPropertyListRetained = presetPropertyList?.takeRetainedValue() else { return -1 }
        let result = AudioUnitSetProperty(sampleUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &presetPropertyListRetained, numericCast(MemoryLayout.size(ofValue: CFPropertyList.self)))
        return result
    }
    func restartAudioProcessingGraph() {
        let result = AUGraphStart(processingGraph)
        assert(result == noErr, describeOSStatus("Unable to restart the audio processing graph", status: result))
    }
    func startPlayNoteNumber(_ noteNumber: UInt32) {
        let onVelocity: UInt32 = 127
        let noteCommand: UInt32 = MIDIMessage.noteOn.rawValue << 4 | 0
        let result = MusicDeviceMIDIEvent(sampleUnit, noteCommand, noteNumber, onVelocity, 0)
        assert(noErr == result, describeOSStatus("Unable to start playing the mid note", status: result))
    }
    func stopPlayNoteNumber(_ noteNumber: UInt32) {
        let noteCommand: UInt32 = MIDIMessage.noteOff.rawValue << 4 | 0
        let result = MusicDeviceMIDIEvent(sampleUnit, noteCommand, noteNumber, 0, 0)
        assert(noErr == result, describeOSStatus("Unable to stop playing the mid note", status: result))
    }
    func stopAudioProcessingGraph() {
        let result = AUGraphStop(processingGraph)
        assert(result == noErr, describeOSStatus("Unable to stop the audio processing graph", status: result))
    }
    private func configureAudioUnit() {
        var result: OSStatus = noErr
        var framesPerSlice: UInt32 = 0
        var framesPerSlicePropertySize: UInt32 = numericCast(MemoryLayout.size(ofValue: framesPerSlice))
        let sampleRatePropertySize: UInt32 = numericCast(MemoryLayout.size(ofValue: graphSampleRate))
        result = AudioUnitInitialize(ioUnit)
        assert(noErr == result, describeOSStatus("Unable to initialize the I/O unit", status: result))
        // Set the I/O unit's output sample rate.
        result = AudioUnitSetProperty(ioUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &graphSampleRate, sampleRatePropertySize)
        assert(noErr == result, describeOSStatus("AudioUnitSetProperty (set Output unit output stream sample rate)", status: result))
        // Obtain the value of the maximum-frames-per-slice from the I/O unit.
        result = AudioUnitGetProperty(ioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &framesPerSlice, &framesPerSlicePropertySize)
        assert(noErr == result, describeOSStatus("Unable to retrieve the maximum frames per slice property from the I/O unit", status: result))
        // Set the Sampler unit's output sample rate.
        result = AudioUnitSetProperty(sampleUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &graphSampleRate, sampleRatePropertySize)
        assert(noErr == result, describeOSStatus("AudioUnitSetProperty (set Sampler unit output stream sample rate)", status: result))
        // Set the Sampler unit's maximum frames-per-slice.
        result = AudioUnitGetProperty(sampleUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &framesPerSlice, &framesPerSlicePropertySize)
        assert(noErr == result, describeOSStatus("AudioUnitSetProperty (set Sampler unit maximum frames per slice)", status: result))
        // Initialize the audio processing graph.
        result = AUGraphInitialize(processingGraph)
        assert(noErr == result, describeOSStatus("Unable to initialze AUGraph object", status: result))
        // Start the graph
        result = AUGraphStart(processingGraph)
        assert(noErr == result, describeOSStatus("Unable to start audio processing graph", status: result))
        CAShow(.init(processingGraph))
    }
    private func describeOSStatus(_ reason: String, status: OSStatus) -> String {
        .init(format: "%@. Error code: %d '%.4s'", reason, status, unsafeBitCast(status, to: String.self))
    }
}

final class SynthAudioSessionDelegate: NSObject {
    static private func describeOSStatus(_ reason: String, status: OSStatus) -> String {
        .init(format: "%@. Error code: %d '%.4s'", reason, status, unsafeBitCast(status, to: String.self))
    }
    var ioUnit: AudioUnit? = nil
    var sampleUnit: AudioUnit? = nil
    var ioNode: AUNode = .init()
    var samplerNode: AUNode = .init()
    var graphSampleRate: Double = 44100.0
    var processingGraph: AUGraph? = nil
    var synthAudioSession: SynthAudioSession? = nil
    override init() {
        /// Setup audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setPreferredSampleRate(graphSampleRate)
            try session.setActive(true, options: [])
        } catch {
            debugPrint(error)
        }
        graphSampleRate = session.sampleRate
        /// Create AUGraph
        var result: OSStatus = NewAUGraph(&processingGraph)
        assert(result == noErr, String(format: "Unable to create an AUGraph object. Error code: %d '%.4s'", result, unsafeBitCast(result, to: String.self)))
        guard let graph = processingGraph else {
            super.init()
            return
        }
        var description: AudioComponentDescription = .init(componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_Sampler, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        // 1. add sampler node
        result = AUGraphAddNode(graph, &description, &samplerNode)
        assert(noErr == result, Self.describeOSStatus("Unable to add the Sampler unit to the audio processing graph", status: result))
        // 2. add output node
        description.componentType = kAudioUnitType_Output
        description.componentSubType = kAudioUnitSubType_RemoteIO
        result = AUGraphAddNode(graph, &description, &ioNode)
        assert(noErr == result, Self.describeOSStatus("Unable to add the Output unit to the audio processing graph", status: result))
        // Open graph
        result = AUGraphOpen(graph)
        assert(noErr == result, Self.describeOSStatus("Unable to open the audio processing graph", status: result))
        // Connect the Sampler unit to the output unit
        result = AUGraphConnectNodeInput(graph, samplerNode, 0, ioNode, 0)
        assert(noErr == result, Self.describeOSStatus("Unable to interconnect the nodes in the audio processing graph", status: result))
        // Obtain a reference to the Sampler unit from its node
        result = AUGraphNodeInfo(graph, samplerNode, nil, &sampleUnit)
        assert(noErr == result, Self.describeOSStatus("Unable to obtain a reference to the Sampler unit", status: result))
        // Obtain a reference to the I/O unit from its node
        result = AUGraphNodeInfo(graph, ioNode, nil, &ioUnit)
        assert(noErr == result, Self.describeOSStatus("Unable to obtain a reference to the I/O unit", status: result))
        /// Configure and start audio processing graph
        synthAudioSession = SynthAudioSession(sampleUnit: sampleUnit, ioUnit: ioUnit, graph: graph)
        super.init()
    }
    @IBAction func loadPresent(_ sender: Any?) {
        let bundle: Bundle = .main
        guard let presetPath = bundle.path(forResource: "Vibraphone", ofType: "aupreset") else { return }
        let presetURL = URL(fileURLWithPath: presetPath)
        os_log("Attempting to load preset '%@'", presetURL.description)
        loadSynthFromPresetURL(presetURL)
    }
    @IBAction func startPlayNoteNumber(_ sender: Any?) {
        synthAudioSession?.startPlayNoteNumber(0)
    }
    @IBAction func stopPlayNoteNumber(_ sender: Any?) {
        synthAudioSession?.stopPlayNoteNumber(0)
    }
    /// Load a synthesizer preset file and apply it to the Sampler unit
    @discardableResult
    private func loadSynthFromPresetURL(_ presetUrl: URL) -> OSStatus {
        synthAudioSession?.loadSynthFromPresetURL(presetUrl) ?? -1
    }
    private func stopAudioProcessingGraph() {
        synthAudioSession?.stopAudioProcessingGraph()
    }
    private func restartAudioProcessingGraph() {
        synthAudioSession?.restartAudioProcessingGraph()
    }
    /// #MARK - Application state management
    /**
 The audio processing graph should not run when the screen is locked or when the app has transitioned to the background, because there can be no user interaction in those states. (Leaving the graph running with the screen locked wastes a significant amount of energy.) Responding to these UIApplication notifications allows this class to stop and restart the graph as appropriate.
     */
    private func registerForUIApplicationNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: handleAppActivationState)
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: handleAppActivationState)
    }
    private func handleAppActivationState(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willResignActiveNotification:
            stopAudioProcessingGraph()
        case UIApplication.didBecomeActiveNotification:
            restartAudioProcessingGraph()
        default:
            break
        }
    }
}
