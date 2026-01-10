package tkr

import "core:time"
import "core:testing"
import "core:math/rand"
import "core:net"
import "core:fmt"
import "core:log"
import en "core:encoding/endian"
import sa "core:container/small_array"

Buffer_Serializer :: struct {
	buffer: []byte,
	offset: int,
}

bs_get_bool :: proc(bs: ^Buffer_Serializer) -> (bool, bool) {
	if bs.offset + 1 > len(bs.buffer)  {
		return false, false
	}

	off := bs.offset
	bs.offset += 1
	return bool(bs.buffer[off]), true 
}

bs_put_bool :: proc(bs: ^Buffer_Serializer, v: bool) -> bool {
	if len(bs.buffer[bs.offset:]) < 1 {
		return false
	}

	bs.buffer[bs.offset] = u8(v)
	bs.offset += 1
	return true
}

bs_get_u8 :: proc(bs: ^Buffer_Serializer) -> (u8, bool) {
	if len(bs.buffer[bs.offset:]) < 1 {
		return 0, false
	}

	off := bs.offset
	bs.offset += 1
	return bs.buffer[off], true 
}

bs_put_u8 :: proc(bs: ^Buffer_Serializer, v: u8) -> bool {
	if len(bs.buffer[bs.offset:]) < 1 {
		return false
	}

	bs.buffer[bs.offset] = v
	bs.offset += 1
	return true
}

bs_get_u16 :: proc(bs: ^Buffer_Serializer) -> (v: u16, ok: bool) {
	v = en.get_u16(bs.buffer[bs.offset:], .Little) or_return 
	bs.offset += 2
	ok = true
	return
}

bs_put_u16 :: proc(bs: ^Buffer_Serializer, v: u16) -> bool {
	en.put_u16(bs.buffer[bs.offset:], .Little, v) or_return
	bs.offset += 2
	return true
}

bs_get_u32 :: proc(bs: ^Buffer_Serializer) -> (v: u32, ok: bool) {
	v = en.get_u32(bs.buffer[bs.offset:], .Little) or_return 
	bs.offset += 4
	ok = true
	return
}

bs_put_u32 :: proc(bs: ^Buffer_Serializer, v: u32) -> bool {
	en.put_u32(bs.buffer[bs.offset:], .Little, v) or_return
	bs.offset += 4
	return true
}

bs_get_u64 :: proc(bs: ^Buffer_Serializer) -> (v: u64, ok: bool) {
	v = en.get_u64(bs.buffer[bs.offset:], .Little) or_return 
	bs.offset += 8
	ok = true
	return
}

bs_put_u64 :: proc(bs: ^Buffer_Serializer, v: u64) -> bool {
	en.put_u64(bs.buffer[bs.offset:], .Little, v) or_return
	bs.offset += 8
	return true
}

bs_get_i8 :: proc(bs: ^Buffer_Serializer) -> (i8, bool) {
	if len(bs.buffer[bs.offset:]) < 1 {
		return 0, false
	}

	off := bs.offset
	bs.offset += 1
	return i8(bs.buffer[off]), true 
}

bs_put_i8 :: proc(bs: ^Buffer_Serializer, v: i8) -> bool {
	if len(bs.buffer[bs.offset:]) < 1 {
		return false
	}

	bs.buffer[bs.offset] = u8(v)
	bs.offset += 1
	return true
}

bs_get_i32 :: proc(bs: ^Buffer_Serializer) -> (v: i32, ok: bool) {
	v = en.get_i32(bs.buffer[bs.offset:], .Little) or_return 
	bs.offset += 4
	ok = true
	return
}

bs_put_i32 :: proc(bs: ^Buffer_Serializer, v: i32) -> bool {
	en.put_i32(bs.buffer[bs.offset:], .Little, v) or_return
	bs.offset += 4
	return true
}


bs_get_i64 :: proc(bs: ^Buffer_Serializer) -> (v: i64, ok: bool) {
	v = en.get_i64(bs.buffer[bs.offset:], .Little) or_return 
	bs.offset += 8
	ok = true
	return
}

bs_put_i64 :: proc(bs: ^Buffer_Serializer, v: i64) -> bool {
	en.put_i64(bs.buffer[bs.offset:], .Little, v) or_return
	bs.offset += 8
	return true
}

bs_get_f32 :: proc(bs: ^Buffer_Serializer) -> (v: f32, ok: bool) {
	v = en.get_f32(bs.buffer[bs.offset:], .Little) or_return 
	bs.offset += 4
	ok = true
	return
}

bs_put_f32 :: proc(bs: ^Buffer_Serializer, v: f32) -> bool {
	en.put_f32(bs.buffer[bs.offset:], .Little, v) or_return
	bs.offset += 4
	return true
}

bs_put :: proc{bs_put_bool, bs_put_u8, bs_put_u16, bs_put_u32, bs_put_u64, bs_put_i8, bs_put_i32, bs_put_i64}

bs_get :: proc(bs: ^Buffer_Serializer, $N: typeid) -> (N, bool) {
	switch N {
	case bool: return bs_get_bool(bs)
	case u8:   return bs_get_u8(bs)
	case u16:  return bs_get_u16(bs)
	case u32:  return bs_get_u32(bs)
	case u64:  return bs_get_u64(bs)
	case i8:   return bs_get_i8(bs)
	case i16:  return bs_get_i16(bs)
	case i32:  return bs_get_i32(bs)
	case i64:  return bs_get_i64(bs)
	case: return {}, false
	}
}

bs_put_array :: proc(bs: ^Buffer_Serializer, data: ^[]$T) -> bool {
    if len(bs.buffer[bs.offset:]) < len(data) * size_of(T) {
    	return false
    }

    for v in data {
    	bs_put(v) or_return
    }

    return true
}

bs_get_array :: proc(bs: ^Buffer_Serializer, data: ^[]$T) -> bool {
    if len(bs[bs.offset:]) < len(data) * size_of(T) {
		return false
	}

    for &v in data {
    	v = bs_get(v) or_return
    }

    return true
}

bs_put_address :: proc(bs: ^Buffer_Serializer, address: net.Address) -> bool {
	switch v in address {
	case net.IP4_Address:
		if len(bs.buffer[bs.offset:]) < len(v) + 1 {
			return false
		}
		bs_put_u8(bs, 0) or_return
		for i in v {
			bs_put_u8(bs, i) or_return
		}
	case net.IP6_Address:
		if len(bs.buffer[bs.offset:]) < len(v) + 1 {
			return false
		}

		bs_put_u8(bs, 1) or_return
		for i in v {
			bs_put_u16(bs, u16(i)) or_return
		}
	case nil:
		bs_put_u8(bs, 2) or_return	
	}

	return true
}

bs_get_address :: proc(bs: ^Buffer_Serializer) -> (address: net.Address, ok: bool) {
	type := bs_get_u8(bs) or_return
	switch type {
	case 0:
		ip4_address: net.IP4_Address
		for i in 0..<len(net.IP4_Address) {
			ip4_address[i] = bs_get_u8(bs) or_return
		}
		address = ip4_address
	case 1:
		ip6_address: net.IP6_Address
		for i in 0..<len(net.IP6_Address) {
			ip6_address[i] = u16be(bs_get_u16(bs) or_return) 
		}
		address = ip6_address
	case 2:
		address = net.IP4_Address {}
	case:
		ok = false
		return
	}

	return address, true
}

bs_get_frame :: proc(bs: ^Buffer_Serializer) -> (frame: Frame, ok: bool) {
	v := bs_get_i32(bs) or_return
	return Frame(v), true
}

bs_put_frame :: proc(bs: ^Buffer_Serializer, v: Frame) -> bool {
	return bs_put_i32(bs, i32(v))
}

bs_get_time :: proc(bs: ^Buffer_Serializer) -> (t: time.Time, ok: bool) {
	v := bs_get_i64(bs) or_return
	return time.Time { v }, true
}

bs_put_time :: proc(bs: ^Buffer_Serializer, v: time.Time) -> bool {
	return bs_put_i64(bs, v._nsec)
}

Protocol_Message_Type :: enum u8 {
	Sync_Request       = 0,
	Sync_Reply         = 1,
	Input_Message      = 2,
	Quality_Report     = 3,
	Quality_Reply      = 4,
	Keep_Alive         = 5,
	Checksum_Report    = 6,
	Disconnect_Request = 7,
}

serialize_protocol_message :: proc(buffer: []byte, p2p: ^P2P_Session($Game, $Input), message: Protocol_Message(Input)) -> (offset: int, ok: bool) {
	bs := Buffer_Serializer { buffer = buffer }
	b := &bs
	bs_put_u16(b, message.magic) or_return
	switch &m in message.message {
	case Sync_Request:
		bs_put_u8 (b, u8(Protocol_Message_Type.Sync_Request)) or_return
		bs_put_u32(b, m.random_request) or_return
	case Sync_Reply:
		bs_put_u8 (b, u8(Protocol_Message_Type.Sync_Reply)) or_return
		bs_put_u32(b, m.random_reply) or_return
	case Input_Message(Input):
		bs_put_u8(b, u8(Protocol_Message_Type.Input_Message)) or_return
		for i in 0..<p2p.num_players {
			bs_put_bool(b, m.connection_statuses[i].disconnected) or_return
			bs_put_frame(b, m.connection_statuses[i].last_received_frame) or_return
		}
		
		bs_put_frame(b, m.ack_frame) or_return
		start_frame := sa.get(m.pending_inputs, 0).frame
		bs_put_frame(b, start_frame) or_return

		bs_put_u8(b, u8(sa.len(m.pending_inputs))) or_return
		for &pending_input in sa.slice(&m.pending_inputs) {
			p2p.serialize_input(b, pending_input.input) or_return
		}
	case Quality_Report:
		bs_put_u8(b, u8(Protocol_Message_Type.Quality_Report)) or_return
		bs_put_f32(b, m.frame_advantage) or_return
		bs_put_time(b, m.ping) or_return
	case Quality_Reply:
		bs_put_u8(b, u8(Protocol_Message_Type.Quality_Reply)) or_return 
		bs_put_time(b, m.pong) or_return
	case Keep_Alive:
		bs_put_u8(b, u8(Protocol_Message_Type.Keep_Alive)) or_return
	case Checksum_Report:
		bs_put_u8(b, u8(Protocol_Message_Type.Checksum_Report)) or_return
		bs_put_frame(b, m.frame) or_return
		bs_put_u32(b, m.checksum) or_return
	case Disconnect_Request:
		bs_put_u8(b, u8(Protocol_Message_Type.Disconnect_Request)) or_return
	}

	return bs.offset, true
}

deserialize_protocol_message :: proc(buffer: []byte, p2p: ^P2P_Session($Game, $Input)) -> (m: Protocol_Message(Input), ok: bool) {
	bs := Buffer_Serializer { buffer = buffer }
	b := &bs

	m.magic = bs_get_u16(b) or_return
	m_type := bs_get_u8(b) or_return

	message_type := transmute(Protocol_Message_Type)m_type
	switch message_type {
	case .Sync_Request:
		random_request := bs_get_u32(b) or_return
		m.message = Sync_Request { random_request }
	case .Sync_Reply:
		random_reply := bs_get_u32(b) or_return
		m.message = Sync_Reply { random_reply }
	case .Input_Message:
		message: Input_Message(Input)
		for i in 0..<p2p.num_players {
			message.connection_statuses[i].disconnected = bs_get_bool(b) or_return
			message.connection_statuses[i].last_received_frame = bs_get_frame(b) or_return
		}

		message.ack_frame = bs_get_frame(b) or_return
		start_frame := bs_get_frame(b) or_return

		pending_inputs_len := bs_get_u8(b) or_return
		if pending_inputs_len > MAX_PENDING_INPUTS  {
			return
		}

		for i in 0..<pending_inputs_len {
			local_input: Local_Input(Input)
			local_input.frame = start_frame + Frame(i)
			local_input.input = p2p.deserialize_input(b) or_return
			sa.append(&message.pending_inputs, local_input)
		}

		m.message = message
	case .Quality_Report:
		frame_advantage := bs_get_f32(b) or_return
		ping := bs_get_time(b) or_return
		m.message = Quality_Report { frame_advantage, ping }
	case .Quality_Reply:
		pong := bs_get_time(b) or_return
		m.message = Quality_Reply { pong }
	case .Keep_Alive:
		m.message = Keep_Alive {}
	case .Checksum_Report:
		frame := bs_get_frame(b) or_return
		checksum := bs_get_u32(b) or_return
		m.message = Checksum_Report { frame, checksum }
	case .Disconnect_Request:
		m.message = Disconnect_Request {}
	case:
		// Invalid message type
		return
	}

	ok = true
	return
}

@(test)
test_serialize_message :: proc(t: ^testing.T) {
	buffer: [MAX_PACKET_SIZE]byte

	Game :: struct {}

	Test_Input :: struct {
		test: bool
	}

	serialize_input :: proc(bs: ^Buffer_Serializer, input: Test_Input) -> bool {
		return bs_put_bool(bs, input.test)
	}

	deserialize_input :: proc(bs: ^Buffer_Serializer) -> (input: Test_Input, ok: bool) {
		test := bs_get_bool(bs) or_return
		return Test_Input { test }, true
	}

	p2p: P2P_Session(Game, Test_Input)
	for i in 0..<4 {
		p2p_add_local_player(&p2p, i)
	}
	p2p_init(&p2p, 4, 0, 60.0 / 1000 , serialize_input, deserialize_input)


	{ // Protocol Sync Request
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Sync_Request {
				random_request = 123,
			},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}

	{ // Protocol Sync Reply
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Sync_Reply {
				random_reply = 12312,
			},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}

	{ // Input_Message
		message := Input_Message(Test_Input) {
			ack_frame = 99,
		}

		for i in 0..<9 {
			local_input := Local_Input(Test_Input) {
				frame = 100 + Frame(i),
				input = Test_Input { bool(i % 2) }
			}
			sa.append(&message.pending_inputs, local_input)
		}

		net_message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = message,
		}


		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, net_message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(net_message == de_message)
	}

	{ // Quality Report
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Quality_Report {
				frame_advantage = 5,
				ping = time.now(),
			},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}

	{ // Quality Reply
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Quality_Reply {
				pong = time.now(),
			},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}

	{ // Keep Alive
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Keep_Alive {},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}

	{ // Checksum Report
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Checksum_Report {
				frame = 123,
				checksum = rand.uint32(),
			},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}

	{ // Disconnect Request
		message := Protocol_Message(Test_Input) {
			magic = u16(rand.uint32()),
			message = Disconnect_Request {},
		}

		offset, ok_ser := serialize_protocol_message(buffer[:], &p2p, message)
		assert(ok_ser)

		de_message, ok_de := deserialize_protocol_message(buffer[:offset], &p2p)
		assert(ok_de)
		assert(message == de_message)
	}
}
