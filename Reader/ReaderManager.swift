//
//  ReaderManager.swift
//  Reader
//
//  Created by Jim on 4/29/26.
//

import Foundation
internal import Combine
import CoreAudio
import AudioToolbox
import Synchronization
import Cocoa

enum READER_SEL : Int{
    case dts = 1,ltc
}

@Observable nonisolated class ReaderManager: ObservableObject {
    
    var host = ReaderHost(input: 0)
    var running = false
    
    var deviceDictionary: [String: AudioDeviceID] = [:] // output devices only
    var selectedDevice = ""{
        didSet{
            print("selectedDevice: \(selectedDevice), oldValue \(oldValue)")
            if oldValue != selectedDevice{
                
                UserDefaults.standard.set(selectedDevice, forKey: "selectedDevice")
                
                if let deviceID = deviceDictionary[selectedDevice]{
                    
                    host.deviceID = deviceID
                }
                                
            }
        }
    }
    init(){
        
        deviceDictionary = CAUtilities.getAllDevices(.input) // printing info in debug window, populates deviceDictionary
        
        if let selectedDevice = UserDefaults.standard.string(forKey: "selectedDevice"){
            self.selectedDevice = selectedDevice
        }
        
        if let selectedReader = UserDefaults.standard.string(forKey: "selectedReader"){
            host.reader.ringBuffer.selectedReader = Int(selectedReader)!
        }
    }
    func startStop(){
        
        host.reader.stop()
        
        running.toggle()
        
        if running{
            host.reader.ringBuffer.reset()
            host.reader.start()
        }
        
    }

}
