import CoreMIDI

/// A virtual MIDI source: other apps (a DAW, a synth) see it as an input called `name`.
final class MidiOut {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    init?(name: String) {
        guard MIDIClientCreateWithBlock(name as CFString, &client, nil) == noErr,
              MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) == noErr
        else { return nil }
        // A fixed ID lets DAWs recognize the port again after a relaunch and keep their mappings.
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x5249_4E47)  // "RING"
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    }

    /// Send a control change. `channel` is 1–16; `number` and `value` are 0–127.
    func cc(channel: Int, number: Int, value: Int) {
        let status = UInt32(0xB0 | ((channel - 1) & 0x0F))
        // Universal MIDI Packet, MIDI 1.0 channel voice message: type 2, group 0.
        var word: UInt32 = 0x2000_0000 | status << 16 | UInt32(number & 0x7F) << 8 | UInt32(value & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, &list)
    }
}
