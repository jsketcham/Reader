//
//  ContentView.swift
//  Reader
//
//  Created by Jim on 4/29/26.
//

import SwiftUI

struct ContentView: View {
    
    @State private var readerManager = ReaderManager()
    
    var body: some View {
        VStack {
            Text("ltc \(readerManager.host.reader.ringBuffer.ltc)")
                .frame(width:100, alignment: .leading)
                .padding(.bottom, 5)
            Text("DTS")
                .frame(width:100, alignment: .center)
            HStack {
                //Spacer()
                Text(" serial \(readerManager.host.reader.ringBuffer.serialNumber)")
                    .frame(width:100, alignment: .leading)
                Text("reel \(readerManager.host.reader.ringBuffer.reelNumber)")
                    .padding(.leading, 20)
                    .frame(width:100, alignment: .leading)
                Text("frame \(readerManager.host.reader.ringBuffer.frameNumber)")
                    .frame(width:100, alignment: .leading)
                //Spacer()
            }
            .padding(5)
            .border(Color.blue, width: 2)
            
            Picker("input", selection: $readerManager.selectedDevice) {
                ForEach(readerManager.deviceDictionary.keys.sorted(), id: \.self) { device in
                    Text(device)
                }
            }
            .frame(maxWidth: 250)
            .disabled(readerManager.running)
            .padding(10)
            
            HStack {
                Picker("reader", selection: $readerManager.host.reader.ringBuffer.selectedReader) {
                    Text("dts").tag(READER_SEL.dts.rawValue)
                    Text("ltc").tag(READER_SEL.ltc.rawValue)
                }
                .pickerStyle(.radioGroup)
                //.horizontalRadioGroupLayout() // Optional: arrange horizontally
                .frame(width:100)
                
                Picker("source", selection: $readerManager.host.reader.ringBuffer.selected) {
                    Text("left").tag(0)
                    Text("right").tag(1)
                }
                .pickerStyle(.radioGroup) // macOS only
                //.horizontalRadioGroupLayout() // Optional: arrange horizontally
                .frame(width:100)
            }
            .padding(.bottom, 10)

            Button("\(readerManager.running ? "Stop" : "Run")") {
                readerManager.startStop()
            }

        }
        .padding()
    }
}

#Preview {
    ContentView()
}
