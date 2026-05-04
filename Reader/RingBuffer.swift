//
//  RingBuffer.swift
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

nonisolated let bufferSize = 8192 //

// mutex must be global
// these are the values we need to synchronize to ltc
struct SyncItem{
    var outTick : Int64 = 0             // outproc mHostTime
    var outDepth: Int32 = 0             // depth of delay line at that tick
    var ltcTick : Int64 = 0             // ltc sync mHostTime
    var ticksPerLtcFrame : Int64 = 0    // gives ltc frames per second, which is soxr rate
    var ltcFrame : UInt32 = 0            // ltc frame number at ltcTick
    var tcType : TCTYPE = .TC_30        // to calculate nominal frames per second
    var ltcState : LOCK_STATE = .IDLE   // chase when .SEQUENTIAL
}
nonisolated let syncItem = Mutex<SyncItem>(SyncItem())  // the sync mutex

enum LOCK_STATE : Int{
case IDLE,
     SYNC_DETECT,   // found a sync mark
     LOCKED,        // followed by a 2nd sync mark, at 80 bits
     SEQUENTIAL     // followed by a 3rd sync mark, at 80 bits, with sequential timecodes
}
enum TCTYPE : Int{
    case TC_24,TC_25,TC_DF,TC_30//,UNKNOWN
}

@Observable nonisolated class RingBuffer: ObservableObject {
    
    var tcType : TCTYPE = .TC_30
    var serialNumber : UInt32 = 1234
    var frameNumber : UInt32 = 0{
        didSet{
            
            //print("frameNumber \(frameNumber)")
            
            // continue only for sequential timecodes
            guard frameNumber == oldValue + 1,
                  ticksPerLtcFrame != 0 else{
                
                print("non-sequential frames, \(oldValue) -> \(frameNumber)")
                ltcState = .IDLE;
                return
            }
            
            syncItem.withLock { item in
                
                item.ltcFrame = frameNumber
                
                switch ltcState{
                case .SEQUENTIAL:
                    // filter
                    item.ticksPerLtcFrame -= (item.ticksPerLtcFrame - ticksPerLtcFrame) / 16
                    //print("ticksPerLtcFrame \(item.ticksPerLtcFrame)")
                   break
                default:
                    // initialize
                    item.ticksPerLtcFrame = ticksPerLtcFrame
                //print("initialize ticksPerLtcFrame \(item.ticksPerLtcFrame) ltcState \(ltcState)")
                    break
                }
                
                item.ltcTick = lastTick
                item.tcType = self.tcType
                item.ltcState = self.ltcState   // use once if .SEQUENTIAL, then set this to .IDLE
                
            }
                        
//            // display takes 1% of the MIPs
//            ltc = String(format: "%x%x:%x%x:%x%x:%x%x",
//                             self.ltcBytes[9] & 0x03,
//                             self.ltcBytes[8] & 0x0f,
//                             self.ltcBytes[7] & 0x07,
//                             self.ltcBytes[6] & 0x0f,
//                             self.ltcBytes[5] & 0x07,
//                             self.ltcBytes[4] & 0x0f,
//                             self.ltcBytes[3] & 0x03,
//                             self.ltcBytes[2] & 0x0f)
            
//            ub = String(format: "%x%x%x%x%x%x.%x%x",
//                            (self.ltcBytes[9] >> 4) & 0x0f,
//                            (self.ltcBytes[8] >> 4) & 0x0f,
//                            (self.ltcBytes[7] >> 4) & 0x0f,
//                            (self.ltcBytes[6] >> 4) & 0x0f,
//                            (self.ltcBytes[5] >> 4) & 0x0f,
//                            (self.ltcBytes[4] >> 4) & 0x0f,
//                            (self.ltcBytes[3] >> 4) & 0x0f,
//                            (self.ltcBytes[2] >> 4) & 0x0f)
            

        }
    }
    var reelNumber : UInt32 = 1
    var selected : Int = 0

    private var buffers : [[Float]] = Array(repeating: Array(repeating: 0, count: bufferSize), count: 2)
    private var inIndex = 0
    private var outIndex = 0
    private var full = false
    private var busy = false

    var selectedReader = READER_SEL.dts.rawValue{
        didSet{
            UserDefaults.standard.set(selectedReader, forKey: "selectedReader")
        }
    }
    func framesAvailable() -> UInt32{
        
        //if inIndex != outIndex{full = false}
        if full{return 0}
        
        return  UInt32(outIndex == inIndex ? bufferSize : (outIndex - inIndex + bufferSize) % bufferSize)
    }
    func readFramesAvailable() -> UInt32{
        
        //print("readFramesAvailable inIndex, outIndex \(inIndex) \(outIndex)")
        
        //if inIndex != outIndex{full = false}
        if full{return UInt32(bufferSize)}

        return UInt32((inIndex - outIndex + bufferSize) % bufferSize)
    }

    @discardableResult func put(_ abl: UnsafeMutableAudioBufferListPointer, nFrames: UInt32)->OSStatus{
        
        var framesToWrite = Int(min(framesAvailable(),nFrames))
        var inIndexCopy = inIndex
        
        while framesToWrite > 0{
            let frs = min(framesToWrite,bufferSize - inIndexCopy)   // wrap
                        
            for i in 0..<abl.count{
                
                if i < buffers.count{
                    
                    buffers[i].withUnsafeMutableBufferPointer { ptr in
                        
                        let dst = ptr.baseAddress!.advanced(by: inIndexCopy)
                        let src = abl[i].mData
                        let size = frs * MemoryLayout<Float>.size
                        
                        memcpy(dst,src,size)
                        
//                        let foo = src?.assumingMemoryBound(to: Float32.self)
//                        print("\(foo![0])") // getting 0.0 always
                    }
                    
                }
                
            }

            framesToWrite -= frs
            inIndexCopy += frs
            inIndexCopy %= bufferSize
        }
        
        inIndex = inIndexCopy
        full = inIndex == outIndex
        
        return noErr
    }
    
    private var lastFloat : Float = 0.0
    private var lastIndex : Int = 0
    var peak : Float = 0.0
    var ti : TimeInterval = 0.0
    var periodArray : [Int] = []
    private var dtsSamplesPerBit : Int = 67 // for 48K sample rate
    private var ltcShifter : UInt32 = 0 // rx bits shift into this sync detect register
    private var ltcPhase = 0
    // local values, captured every frame at bit 0
    private var lastTick : Int64 = 0
    private var ticksPerLtcFrame : Int64 = 0    // unfiltered
    // most vars are private vars
    private var ltcState : LOCK_STATE = .IDLE{
        didSet{
            if oldValue != ltcState{
                print("\(ltcState)")
            }
        }
    }
    private var ticksPerSample : Double = AudioGetHostClockFrequency()/48000.0
    private var hostTime : UInt64 = 0   // from inputProc

    @discardableResult func decodeDts() -> OSStatus{
        
        switch(ltcShifter >> 16){
        case 0: serialNumber = UInt32(ltcShifter & 0xffff); frameNumber += 1; break
        default : frameNumber = UInt32(ltcShifter & 0xffff); reelNumber = UInt32((ltcShifter >> 16) & 0x0f); break
        }
        
        return noErr
    }

    @discardableResult func readerService(hostTime : UInt64) -> OSStatus{
        
        guard busy == false else {return noErr}
        busy = true
        
        let now = Date()
        
        var framesToRead = readFramesAvailable()
        var outIndexCopy = outIndex
        
        while framesToRead > 0{
            
            let frs = min(framesToRead,UInt32(bufferSize - outIndex))    // wrap
            
            //print("\(frs)")
            
            if selected < buffers.count{
                buffers[selected].withUnsafeMutableBufferPointer { ptr in
                    
                    let src = ptr.baseAddress!.advanced(by: outIndexCopy)
                    var array = Array(UnsafeBufferPointer(start: src, count: Int(frs)))
                    
//                    // what is our peak sample TODO: remove peak detector
//                    let pk = array.reduce(into: 0) { max, sample in max = max > abs(sample) ? max : abs(sample) }
//                    
//                    if peak < pk {peak = pk}
                    
                    let array2 = array
                    array.insert(lastFloat, at: 0)  // last sample of previous
                    lastFloat = array.last!         // for next
                    
                    // get indices of edges
                    var result = zip(array,array2).map{$0.sign != $1.sign}.indices(of: true).ranges.map{$0.lowerBound}
                    let result2 = result
                    result.insert(lastIndex, at: 0) // last index of previous
                    lastIndex = result.last! - Int(frs) - 1// small negative number, for next
                            
                    // get periods of cells
                    let periods = zip(result,result2).map{$1 - $0}
                    
//                    // get an idea of the periods FIXME: comment this out
//                    if periodArray.count < 1000{
//                        periodArray.append(contentsOf: periods) // look at periods
//                    }
                    
                    // read DTS or LTC timecode
                    switch selectedReader{
                    case READER_SEL.dts.rawValue:
                        
                        let syncDiscrim = dtsSamplesPerBit * 3 / 2
                        let discrim     = dtsSamplesPerBit * 3 / 4
                        let min         = dtsSamplesPerBit / 4
                        
                        var index = -1  // because we increment it immediately
                        
                        for period in periods{
                            
                            if period < min {continue}   // noise
                            
                            index += 1  // need the sample number, which is in result2
                            
                            if period > syncDiscrim {
                                
                                ltcPhase += 4   // count double cells
                                
                                switch ltcPhase{
                                case 4: break
                                case 48:
                                    
                                    //print("\(String(format: "%05x", ltcShifter))")
                                    ltcPhase = 0
                                    
                                    // calc ticksPerLtcFrame, this is a local value to be filtered
                                    let tick = Int64(Float64(hostTime) + Float64(result2[index]) * ticksPerSample)
                                    ticksPerLtcFrame = tick - lastTick
                                    lastTick = tick
                                    if ticksPerLtcFrame < 0{
                                        print("ticksPerLtcFrame < 0 \(ticksPerLtcFrame) hostTime \(hostTime) index \(result2[index]) ticksPerSample \(ticksPerSample)")
                                    }

                                    // decode contents of ltcShifter
                                    decodeDts()
                                    
                                    switch ltcState {
                                        case .IDLE:         ltcState = .SYNC_DETECT;    break
                                        case .SYNC_DETECT:  ltcState = .LOCKED;         break
                                        case .LOCKED:       ltcState = .SEQUENTIAL;     break
                                        case .SEQUENTIAL:   break
                                    }
                                    break;
                                    
                                default: ltcState = .IDLE; ltcPhase = 0; break
                                }
                                
                            } else if period > discrim {
                                
                                ltcPhase += 2           // count cells
                                if ltcPhase & 1 == 1{ltcState = .IDLE} // out of phase
                                ltcPhase &= 0x7e        // in phase
                                ltcShifter >>= 1        // rx 0
                                
                            }else{
                                
                                ltcPhase += 1       // count half cells
                                
                                if ltcPhase & 1 != 1{
                                    
                                    ltcShifter >>= 1
                                    ltcShifter |= 0x80000   // rx 1
                                    
                                }
                            }
                            
                            // detect missing sync mark
                            switch ltcPhase{
                            case 49: fallthrough
                            case 50: print("error, ltcPhase: \(ltcPhase)"); ltcState = .IDLE; break
                            default: break
                            }
                        }

                        break
                    default:    // ltc reader soon come
                        break
                    }

                }
            
            }
            
            framesToRead -= frs
            outIndexCopy += Int(frs)
            outIndexCopy %= bufferSize
        }
        
        outIndex = outIndexCopy
        full = false
        
        ti += Date().timeIntervalSince(now)
        
        busy = false
        return noErr
    }
    
    func reset(){
        
    }
    
}
