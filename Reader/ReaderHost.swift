//
//  ReaderHost.swift
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

@Observable nonisolated class ReaderHost: ObservableObject {
    
    var reader = Input()
    
    var deviceID : AudioDeviceID?{
        didSet{
            print("ReaderHost deviceID \(deviceID ?? 0)")
            
            if let deviceID = deviceID{
                
                createInput(deviceID)
            }
        }
    }
    init(input: AudioDeviceID) {
      createInput(input)
    }
    func createInput(_ input : AudioDeviceID){
        
        reader.stop()
        reader = Input()
        reader.openDevice(input)

    }

}
