//
//  CAUtilities.swift
//  Reader
//
//  Created by Jim on 4/29/26.
//

import Foundation
import Foundation
internal import Combine
import CoreAudio
import AudioToolbox
import Synchronization
import Cocoa

// qualifier for getAllDevices
enum IN_OUT {
    case input,output,aggregate
}

@Observable nonisolated class CAUtilities: ObservableObject {
    
    // MARK: ---------- Core Audio utilities ------------
    
    static func getAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        // 1. Get data size
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        
        // 2. Get device IDs
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        
        return deviceIDs
    }
    static func numDeviceInputsOutputs(deviceID: AudioDeviceID) -> (inputs: Int, outputs: Int) {
        let input = numChannels(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
        let output = numChannels(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
        return (input, output)
    }
    static func numChannels(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        if dataStatus == noErr {
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let maxChannels = buffers.max { $0.mNumberChannels < $1.mNumberChannels}
            return Int(maxChannels?.mNumberChannels ?? 0)
        }

        return 0
    }
    // Function to check if a device has input and/or output capabilities
    static func isDeviceInputOrOutput(deviceID: AudioDeviceID) -> (isInput: Bool, isOutput: Bool) {
        let input = hasChannels(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
        let output = hasChannels(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
        return (input, output)
    }

    // Helper to query stream configuration for channel count
    static private func hasChannels(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        if dataStatus == noErr {
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            return buffers.contains { $0.mNumberChannels > 0 }
        }
        return false
    }
    static func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceUID: CFString?
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        
        // silence warning by passing in a ptr
        let status = withUnsafeMutablePointer(to: &deviceUID) { ptr in
            // Cast the typed pointer to the raw pointer expected by the C function
            return AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &propertySize, // Cannot convert value of type 'UnsafeMutablePointer<Int>' to expected argument type 'UnsafeMutablePointer<UInt32>'
                ptr
            )
        }
        
        if status == noErr, let uid = deviceUID {
            return uid as String
        } else {
            print("Error getting device UID: \(status)")
            return nil
        }
    }
    static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        
        var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                       mScope: kAudioObjectPropertyScopeInput,
                                                       mElement: kAudioObjectPropertyElementMain)
        
        var streamDataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamDataSize)
        
        if streamDataSize > 0 {
            // Fetch device name
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var name: CFString?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            
            // silence warning by passing in a ptr
            let status = withUnsafeMutablePointer(to: &name) { ptr in
                
                return AudioObjectGetPropertyData(deviceID,
                                           &nameAddress,
                                           0,
                                           nil,
                                           &nameSize,
                                           ptr)
            }
            
            if status == noErr{
                return name! as String
            }else{
                return ""
            }

            
        }
        return "\(deviceID) name missing"
    }
    static func getSampleRate(deviceID: AudioDeviceID) -> Double? {
        // 1. Define the property address for Nominal Sample Rate
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        // 2. Fetch the property data from the device
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &sampleRate
        )

        // 3. Return the value if the status is noErr (0)
        return status == noErr ? Double(sampleRate) : nil
    }
    static func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        // Set up the property address for the default output device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain // Historically kAudioObjectPropertyElementMaster
        )

        // Query the system object for the property data
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &deviceSize,
            &deviceID
        )

        if status == noErr {
            return deviceID
        } else {
            print("Error getting default output device: \(status)")
            return nil
        }
    }
    static func getDefaultInputDeviceID() -> AudioDeviceID?{
        // 1. Define the property address for the system's default input device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 2. Query the system object for the current default input device ID
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        
        if status != noErr {
            print("Error: Could not find default input device.")
            return nil
        }
        
        return deviceID
        
    }
    static func getAllDevices(_ inOut : IN_OUT) -> [String: AudioDeviceID]{
        
        var dict : [String: AudioDeviceID] = [:]
        
        if let id = getDefaultInputDeviceID() {
            print("Default Input Device ID: \(id)")
        }
        if let id = getDefaultOutputDeviceID() {
            print("Default Output Device ID: \(id)")
        }
        
        let audioDeviceIDs = getAudioDeviceIDs()
        
        for id in audioDeviceIDs{
            
            let io = numDeviceInputsOutputs(deviceID: id)
            let name = getDeviceName(deviceID: id) ?? "missing"
            let uniqueID = getDeviceUID(deviceID: id) ?? "missing"
            let sampleRate = getSampleRate(deviceID: id) ?? 0.0
            
            print("\(id): \(name)\n\tUID: \(uniqueID)\n\tInputs: \(io.inputs)\n\tOutputs: \(io.outputs)\n\tsampleRate: \(sampleRate)\n")
            
            switch inOut{
            case .input:    if io.inputs  > 0 && io.outputs == 0{dict[name] = id}; break
            case .output:   if io.inputs  == 0 && io.outputs > 0{dict[name] = id}; break
            default:        dict[name] = id; break
            }
        }
        
        return dict

    }

}
