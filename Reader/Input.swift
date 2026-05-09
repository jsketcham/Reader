//
//  Input.swift
//  Reader
//
//  Created by Jim on 4/29/26.
//  see https://developer.apple.com/library/archive/technotes/tn2091/_index.html

import Foundation

import Foundation
internal import Combine
import CoreAudio
import AudioToolbox
import Synchronization
import Cocoa

@Observable nonisolated class Input: ObservableObject {
    
    var ringBuffer = RingBuffer()

    // AudioUnit
    var inputUnit: AudioUnit?
    var inputBuffer = UnsafeMutableAudioBufferListPointer(nil)
    
    var startDate = Date()
    
    var then = Date()
     
    var inputProc: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
                                         ioData) -> OSStatus in
        
        
        let this = Unmanaged<Input>.fromOpaque(inRefCon).takeUnretainedValue()
        
//        let now = Date()
//        let ti = now.timeIntervalSince(this.then)
//        this.then = now
//        print(String(format:"%3.2f",ti * 1000.0)) // sample rate is 48K

        // Get the new audio data
        if let inputUnit = this.inputUnit,
           let inputBuffer = this.inputBuffer{
            
            let err = AudioUnitRender(inputUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
                                      (inputBuffer.unsafeMutablePointer))
            if err != noErr {
                return err
            }
            
            this.ringBuffer.put(inputBuffer, nFrames: inNumberFrames) // fill ring buffer
        }

        Task{
            this.ringBuffer.readerService(hostTime: inTimeStamp.pointee.mHostTime) // empty ring buffer
        }

        return noErr
        
    }
    
    init(){
        
    }
    
    @discardableResult func openDevice(_ input : AudioDeviceID) -> OSStatus{
        
        return setupAUHAL(input)
    }
    
    @discardableResult func stop() -> OSStatus{
        
        guard isRunning() else{return noErr}
        
        if let err = checkErr(AudioOutputUnitStop(inputUnit!)) {
          return err
        }
//        print(String(format: "peak: %3.2f", ringBuffer.peak))
        let ti = Date().timeIntervalSince(startDate)
        let percent = Float(ringBuffer.ti)/Float(ti) * 100.0
        let percent2 = Float(ringBuffer.tiPut)/Float(ti) * 100.0
       print(String(format: "readerService: %3.2f%% put: %3.2f%%", percent,percent2))
        
//        let counts = ringBuffer.periodArray.reduce(into: [:]) { counts, word in
//            counts[word, default: 0] += 1
//
//        }.sorted{$0.key > $1.key}   // check periods of dts frames
//
//        print(counts)        // xor array with another array

        return noErr
        
    }
    @discardableResult func start() -> OSStatus{
        
        if !isRunning(){
            
            ringBuffer.peak = 0.0
            ringBuffer.ti = 0.0
            ringBuffer.tiPut = 0.0
            ringBuffer.periodArray = []
            startDate = Date()  // for time interval calcs
            // Start pulling for audio data
            if let err = checkErr(AudioOutputUnitStart(inputUnit!)) {
              return err
            }

        }
        
        return noErr
        
    }
    func reset(_ input : AudioDeviceID){
        
    }
    func isRunning() -> Bool {
        
        var auhalRunning: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)

        if inputUnit != nil {
          if checkErr(AudioUnitGetProperty(inputUnit!, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0,
                                           &auhalRunning, &size)) != nil {
            return false
          }
        }

        return auhalRunning != 0
    }

}

// MARK: ------------- ReaderInput setup extension ---------------
nonisolated extension Input{
    
    // https://developer.apple.com/library/archive/technotes/tn2091/_index.html
    // example code is for input, changed for output
    
    func setupAUHAL(_ input: AudioDeviceID) -> OSStatus {
        
        var comp: AudioComponent?
        var desc = AudioComponentDescription()
        var status = noErr

        // There are several different types of Audio Units.
        // Some audio units serve as Outputs, Mixers, or DSP
        // units. See AUComponent.h for listing
        desc.componentType = kAudioUnitType_Output

        // Every Component has a subType, which will give a clearer picture
        // of what this components function will be.
        desc.componentSubType = kAudioUnitSubType_HALOutput

        // all Audio Units in AUComponent.h must use
        // "kAudioUnitManufacturer_Apple" as the Manufacturer
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        desc.componentFlags = 0
        desc.componentFlagsMask = 0

        // Finds a component that meets the desc spec's
        comp = AudioComponentFindNext(nil, &desc)
        if comp == nil {
          exit(-1)
        }
        // gains access to the services provided by the component
        if let err = checkErr(AudioComponentInstanceNew(comp!, &inputUnit)) {
          return err
        }

        // AUHAL needs to be initialized before anything is done to it
        if let err = checkErr(AudioUnitInitialize(inputUnit!)) {
          return err
        }

        status = enableIO(); if status != noErr{return status}
        status = setInputDeviceAsCurrent(input); if status != noErr{return status}
        status = setupBuffers(input); if status != noErr{return status}
        status = callbackSetup()
        
        // is in CAPlayThrough+Setup.setupAUHAL twice, error? Redundant?
        //status = AudioUnitInitialize(inputUnit!); if status != noErr{return status}

        return status
    }
    
    func setInputDeviceAsCurrent(_ input: AudioDeviceID) -> OSStatus {
        
      var input = input
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      var theAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      if input == kAudioDeviceUnknown {
        if let err = checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &theAddress, 0, nil,
                                                         &size, &input)) {
          return err
        }
      }
      //inputDevice = AudioDevice(devid: input, isInput: true)

      // Set the Current Device to the AUHAL.
      // this should be done only after IO has been enabled on the AUHAL.
      if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                                 kAudioUnitScope_Global, 0, &input,
                                                 UInt32(MemoryLayout<AudioDeviceID>.size))) {
        return err
      }
      return noErr
    }
    
    func enableIO() -> OSStatus {
      var enableIO: UInt32 = 1

      ///////////////
      // ENABLE IO (INPUT)
      // You must enable the Audio Unit (AUHAL) for input and disable output
      // BEFORE setting the AUHAL's current device.

      // Enable input on the AUHAL
      if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                                 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))) {
        return err
      }

      // disable Output on the AUHAL
      enableIO = 0
      if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                                 0, &enableIO, UInt32(MemoryLayout<UInt32>.size))) {
        return err
      }
      return noErr
    }

    func callbackSetup() -> OSStatus {
        
        var input = AURenderCallbackStruct(
        inputProc: inputProc,
        inputProcRefCon: UnsafeMutableRawPointer(Unmanaged<Input>.passUnretained(self).toOpaque()))

        // Setup the input callback.
        if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_SetInputCallback,
                                                 kAudioUnitScope_Global, 0, &input,
                                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size))) {
            return err
        }
        
        return noErr
    }
    
    func setupBufferSizeFrames(bufferSizeFrames: inout UInt32, bufferSizeBytes: inout UInt32) -> OSStatus {
      var propertySize = UInt32(MemoryLayout<UInt32>.size)
      let err = AudioUnitGetProperty(inputUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                     &bufferSizeFrames, &propertySize)
      if err != noErr {
        return err
      }
      bufferSizeBytes = bufferSizeFrames * UInt32(MemoryLayout<Float32>.size)
      return noErr
    }
    func setupAsbd(asbd: inout AudioStreamBasicDescription, asbdDev1In: inout AudioStreamBasicDescription) -> OSStatus {
      // Get the Stream Format (Output client side)
      var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      var err = AudioUnitGetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                     &asbdDev1In, &propertySize)
      if err != noErr {
        return err
      }
      // printf("=====Input DEVICE stream format\n" );
      // asbd_dev1_in.Print();

      // Get the Stream Format (client side)
      propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      err = AudioUnitGetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd,
                                 &propertySize)
      if err != noErr {
        return err
      }
        
      return noErr
    }
    func getRate(_ input: AudioDeviceID, rate: inout Float64) -> OSStatus {
      // We must get the sample rate of the input device and set it to the stream format of AUHAL
      var propertySize = UInt32(MemoryLayout<Float64>.size)
      var theAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      let err = AudioObjectGetPropertyData(input, &theAddress, 0, nil, &propertySize, &rate)
      if err != noErr {
        return err
      }
      return noErr
    }

    func setupAudioFormats(asbd: inout AudioStreamBasicDescription) -> OSStatus {
        let propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        // Set the new formats to the AUs...
        if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                                   &asbd, propertySize)) {
            return err
        }
        return noErr
    }
    func setupBuffers(_ input: AudioDeviceID) -> OSStatus {
      var bufferSizeFrames: UInt32 = 0
      var bufferSizeBytes: UInt32 = 0

      var asbd = AudioStreamBasicDescription()
      var asbdDev1In = AudioStreamBasicDescription()

      if let err = checkErr(setupBufferSizeFrames(bufferSizeFrames: &bufferSizeFrames,
                                                  bufferSizeBytes: &bufferSizeBytes)) {
        return err
      }

      if let err = checkErr(setupAsbd(asbd: &asbd, asbdDev1In: &asbdDev1In)) {
        return err
      }

      asbd.mChannelsPerFrame = asbdDev1In.mChannelsPerFrame

      var rate: Float64 = 0
      if let err = checkErr(getRate(input, rate: &rate)) {
        return err
      }

        asbd.mSampleRate = rate; print("rate \(rate)")
      let err = setupAudioFormats(asbd: &asbd)
      if err != noErr {
        return err
      }

      inputBuffer = AudioBufferList.allocate(maximumBuffers: Int(asbd.mChannelsPerFrame))

      for var buf in inputBuffer! {
        buf.mNumberChannels = 1
        buf.mDataByteSize = bufferSizeBytes
      }

      return noErr
    }
}
@discardableResult
nonisolated func checkErr(_ err : @autoclosure () -> OSStatus, file: String = #file, line: Int = #line) -> OSStatus! {
    let error = err()
    if error != noErr {
        print("Reader Error: \(error) ->  \(file):\(line)\n")
        return error
    }
    return nil
}

