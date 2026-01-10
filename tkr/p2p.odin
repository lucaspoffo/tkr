package tkr

import "core:time"
import "core:slice"
import "core:math"
import "core:math/rand"
import "core:reflect"
import "core:log"
import sa "core:container/small_array"

NUM_SYNC_PACKETS :: 5
RESEND_INPUTS_INTERVAL :: 200 * time.Millisecond 
RESEND_SYNC_INTERVAL :: 200 * time.Millisecond 
KEEP_ALIVE_INTERVAL :: 200 * time.Millisecond
QUALITY_REPORT_INTERVAL :: 200 * time.Millisecond 
CHECKSUM_REPORT_INTERVAL :: 400 * time.Millisecond

DISCONNECT_TIMEOUT :: 8 * time.Second
NETWORK_INTERRUPT_START :: 1 * time.Second

MAX_LOCAL_DELAY :: 8
MAX_PENDING_INPUTS :: 60
FRAME_ADVANTAGE_WINDOW_SIZE :: 24

DYNAMIC_DELAY_UPDATE_INTERVAL :: 5 * time.Second

P2P_Session :: struct($Game, $Input: typeid) {
	num_players:       int,
	num_protocols:     int,
	local_input_delay: int,
	syncronizing:      bool,

	dynamic_delay:      bool,
	last_dynamic_delay: time.Time,

	protocols: [MAX_NUM_PLAYERS]P2P_Protocol(Input),
	local_player_index: int,
	
	last_local_input_frame_added: Frame,
	rollback: Rollback_System(Game, Input),

	serialize_input:   #type proc(bs: ^Buffer_Serializer, input: Input) -> bool,
	deserialize_input: #type proc(bs: ^Buffer_Serializer) -> (input: Input, ok: bool),
}

Protocol_State :: enum {
	Initializing,
	Syncronizing,
	Running,
	Disconnected,
}

P2P_Protocol :: struct($Input: typeid) {
	client_id: u64,
	num_players: int,
	remote_player_index: int,

	magic: u16,
	remote_magic: u16,
	remote_connection_statuses: [MAX_NUM_PLAYERS]Connection_Status,

	state: Protocol_State,
	sync_remaining_roundtrips: u32,
	sync_random_request:       u32,
	running_last_quality_report_send: time.Time,
	running_last_checksum_report_send: time.Time,
	running_last_input_send:     time.Time,
	pending_local_inputs: sa.Small_Array(MAX_PENDING_INPUTS, Local_Input(Input)),
	
	local_frame_advantage:  f32,
	remote_frame_advantage: f32,
	local_frame_advantage_window:  [FRAME_ADVANTAGE_WINDOW_SIZE]f32,
	remote_frame_advantage_window: [FRAME_ADVANTAGE_WINDOW_SIZE]f32,

	remote_checksum_report: Checksum_Report,

	last_send_time: time.Time,
	last_recv_time: time.Time,
	last_received_frame: Frame,
	rtt_secs: f64,
}

Sync_Request :: struct {
	random_request: u32, // reply with this random value
}

Sync_Reply :: struct {
	random_reply: u32,
}

Quality_Report :: struct {
	frame_advantage: f32,
	ping:            time.Time,
}

Quality_Reply :: struct {
	pong: time.Time,
}

Local_Input :: struct($Input: typeid) {
	frame: Frame,
	input: Input,
}

Input_Message :: struct($Input: typeid) {
	ack_frame: Frame,
	connection_statuses: [MAX_NUM_PLAYERS]Connection_Status,
	pending_inputs: sa.Small_Array(MAX_PENDING_INPUTS, Local_Input(Input)),
}

Checksum_Report :: struct {
	frame:    Frame,
	checksum: u32,
}

Keep_Alive :: struct {}

Disconnect_Request :: struct {}

Protocol_Message :: struct($Input: typeid) {
	magic: u16,
	client_id: u64,
	message: union {
		Sync_Request,
		Sync_Reply,
		Quality_Report,
		Quality_Reply,
		Input_Message(Input),
		Checksum_Report,
		Keep_Alive,
		Disconnect_Request,
	},
}

p2p_init :: proc(
	p2p: ^P2P_Session($Game, $Input),
	num_players: int,
	local_input_delay: int,
	serialize_input:   #type proc(bs: ^Buffer_Serializer, input: Input) -> bool,
	deserialize_input: #type proc(bs: ^Buffer_Serializer) -> (input: Input, ok: bool)
) {
	assert(num_players <= MAX_NUM_PLAYERS)
	assert(local_input_delay < MAX_LOCAL_DELAY)
	if num_players != p2p.num_players {
		log.panicf(
			"Failed to initial P2P Session, invalid number of players, got %v expected %v. You need to call p2p_add_local_player and p2p_add_remote_player before p2p_init.",
			p2p.num_players,
			num_players
		)
	}
	rollback_init(&p2p.rollback, num_players)
	p2p.num_players = num_players
	p2p.local_input_delay = local_input_delay
	p2p.last_local_input_frame_added = Null_Frame
	p2p.dynamic_delay = true
	p2p.serialize_input = serialize_input
	p2p.deserialize_input = deserialize_input

	for player_index in 0..<num_players {
		p2p.rollback.connection_statuses[player_index] = Connection_Status { disconnected = false, last_received_frame = Null_Frame }
	}

	if local_input_delay > 0 {
		rollback_set_input_delay(&p2p.rollback, p2p.local_player_index, local_input_delay)
	}
}

p2p_shutdown :: proc(p2p: ^P2P_Session) {
	global.p2p = {}
}

p2p_add_local_player :: proc(p2p: ^P2P_Session, player_index: int) {
	p2p.local_player_index = player_index
	p2p.num_players += 1
}

p2p_add_remote_player :: proc(p2p: ^P2P_Session, player_index: int, client_id: u64) {
	p2p.num_players += 1

	// Make sure we are syncronizing only when a remote player is added
	p2p.syncronizing = true
	new_protocol_index := p2p.num_protocols
	new_protocol := &p2p.protocols[new_protocol_index]
	p2p.num_protocols += 1
	protocol_init(new_protocol, p2p.num_players, client_id, player_index)
}

p2p_add_local_input :: proc(p2p: ^P2P_Session, player_index: int, input: $Input) -> bool {
	return rollback_add_input(&p2p.rollback, player_index, input, p2p.rollback.current_frame)
}

p2p_set_local_input_delay :: proc(p2p: ^P2P_Session, delay: int) {
	delay := clamp(delay, 0, MAX_LOCAL_DELAY)
	current_delay := p2p.local_input_delay
	if delay != current_delay {
		p2p.local_input_delay = delay
		rollback_set_input_delay(&p2p.rollback, p2p.local_player_index, delay)
		log.debugf("Changing local input delay from %v to %v frames.", current_delay, delay)
	}
}

p2p_get_protocol :: proc(p2p: ^P2P_Session($Game, $Input), client_id: u64) -> (^P2P_Protocol(Input), bool) {
	for i in 0..<p2p.num_protocols {
		if p2p.protocols[i].client_id == client_id {
			return &p2p.protocols[i], true
		}
	}

	return nil, false
}

p2p_process_message :: proc(p2p: ^P2P_Session($Game, $Input), message: Protocol_Message(Input)) -> (to_send: Protocol_Message(Input)) {
	protocol, ok := p2p_get_protocol(p2p, message.client_id)
	if !ok {
		log.errorf("Failed to process message, client with %v id not found", message.client_id)
		return
	}

	to_send = protocol_process_message(protocol, &p2p.rollback, message)

	return
}

p2p_update :: proc(p2p: ^P2P_Session($Game, $Input)) -> []Protocol_Message(Input) {
	messages := make([dynamic]Protocol_Message, allocator = context.temp_allocator)

	for i in 0..<p2p.num_protocols {
		protocol := &p2p.protocols[i]
		protocol_messages := protocol_update(protocol, &p2p.rollback)
		append(&messages, ..protocol_messages)
	}

	if p2p.syncronizing {
		syncronized := true
		for i in 0..<p2p.num_protocols {
			protocol := &p2p.protocols[i]
			if !(protocol.state == .Running || protocol.state == .Disconnected) {
				syncronized = false
				break
			}
		}

		if syncronized {
			p2p.syncronizing = false
			log.debug("Syncronized with all clients")
		}
	} else {
		now := time.now()
		if p2p.dynamic_delay && time.diff(p2p.last_dynamic_delay, now) > DYNAMIC_DELAY_UPDATE_INTERVAL {
			p2p.last_dynamic_delay = now

			max_rtt_secs := 0.0
			for i in 0..<p2p.num_protocols {
				protocol := &p2p.protocols[i]
				max_rtt_secs = max(max_rtt_secs, protocol.rtt_secs)
			}

			input_delay := 1
			max_rtt_ms := max_rtt_secs * 1000
			if max_rtt_ms > 0 {
				switch {
				case max_rtt_ms < 50:  input_delay = 1
				case max_rtt_ms < 100: input_delay = 2
				case max_rtt_ms < 200: input_delay = 3
				case max_rtt_ms < 300: input_delay = 4
				case:                  input_delay = 5
				}
				p2p_set_local_input_delay(p2p, input_delay)
			}
		}
	}

	return messages[:]
}

p2p_replicate_local_input :: proc(p2p: ^P2P_Session, frame: Frame) {
	input_index := frame % INPUT_QUEUE_LENGTH

	local_input := Local_Input {
		frame = frame,
		input = p2p.rollback.players_inputs[p2p.local_player_index][input_index].input
	}

	for i in 0..<p2p.num_protocols {
		protocol := &p2p.protocols[i]
		if protocol.state != .Disconnected {
			ok_append := sa.append(&protocol.pending_local_inputs, local_input)
			assert(ok_append)
		}
	}
}

p2p_advance_frame :: proc(p2p: ^P2P_Session($Game, $Input)) -> ([]Rollback_Request(Game, Input), []Protocol_Message(Input)) {
	if p2p.syncronizing {
		return nil, nil
	}

	messages := make([dynamic]Protocol_Message, allocator = context.temp_allocator)

	actual_frame := p2p.rollback.current_frame + Frame(p2p.local_input_delay)
	if p2p.last_local_input_frame_added != actual_frame {
		for frame in (p2p.last_local_input_frame_added + 1)..=actual_frame {
			p2p_replicate_local_input(p2p, frame)
		}

		p2p.last_local_input_frame_added = actual_frame
		for i in 0..<p2p.num_protocols {
			protocol := &p2p.protocols[i]
			if protocol.state != .Running {
				continue
			}

			message := Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = Input_Message {
					pending_inputs = protocol.pending_local_inputs,
					ack_frame = protocol.last_received_frame,
					connection_statuses = p2p.rollback.connection_statuses,
				},
			}
			protocol.running_last_input_send = time.now()
			append(&messages, message)
		}
	}

	requests := rollback_advance_frame(&p2p.rollback)
	return requests, messages[:]
}

protocol_init :: proc(protocol: ^P2P_Protocol, num_players: int, client_id: u64, player_index: int) {
	protocol.client_id = client_id
	protocol.remote_player_index = player_index
	for protocol.magic == 0 {
		protocol.magic = u16(rand.uint32())
	}
	protocol.sync_random_request = rand.uint32()
	protocol.remote_checksum_report.frame = Null_Frame
	protocol.last_received_frame = Null_Frame
	for i in 0..<num_players {
		protocol.remote_connection_statuses[i].last_received_frame = Null_Frame
	}

	protocol.num_players = num_players
	protocol.state = .Syncronizing
	protocol.sync_remaining_roundtrips = NUM_SYNC_PACKETS
}

protocol_process_message :: proc(rollback: ^Rollback_System($Game, $Input), protocol: ^P2P_Protocol(Input), message: Protocol_Message(Input)) -> (to_send: Protocol_Message(Input)) {
	if protocol.state == .Disconnected {
		return
	}

	if protocol.remote_magic != 0 && message.magic != protocol.remote_magic {
		log.errorf("Peer %v reiceved message with invalid magic (expected %v got %v)", protocol.client_id, protocol.remote_magic, message.magic)
		return
	}

	_, is_request := message.message.(Sync_Request)
	_, is_reply := message.message.(Sync_Reply)
	if protocol.remote_magic == 0 && !(is_reply || is_request) {
		log.errorf("Peer %v reiceved invalid message type before syncronization: %v", protocol.client_id, reflect.union_variant_typeid(message.message))
		return
	}

	now := time.now()
	protocol.last_recv_time = now
	to_send.client_id = protocol.client_id
	to_send.magic     = protocol.magic

	switch &m in message.message {
	case Sync_Request:
		to_send.message = Sync_Reply { m.random_request }
	case Sync_Reply:
		if protocol.state != .Syncronizing {
			return
		}

		if protocol.sync_random_request != m.random_reply {
			return
		}

		protocol.sync_remaining_roundtrips -= 1
		if protocol.sync_remaining_roundtrips > 0 {
			protocol.sync_random_request = rand.uint32() 
			to_send.message = Sync_Request { protocol.sync_random_request }
		} else {
			protocol.state = .Running
			protocol.remote_magic = message.magic
		}
	case Quality_Report:
		protocol.remote_frame_advantage = m.frame_advantage
		to_send.message = Quality_Reply { m.ping }
	case Quality_Reply:
		rtt := time.diff(m.pong, now)
		rtt_secs := time.duration_seconds(rtt)
		if rtt_secs < math.F32_EPSILON {
            protocol.rtt_secs = rtt_secs;
        } else {
            protocol.rtt_secs = protocol.rtt_secs * 0.875 + rtt_secs * 0.125;
        }
	case Checksum_Report:
		if int(m.frame) % CHECKSUM_FRAME_INTERVAL != 0 {
			// Invalid frame, should be multiple of the interval
			log.error("Received invalid check report, expected frame %v to be a multiple of %v", m.frame, CHECKSUM_FRAME_INTERVAL)
			return
		}

		protocol.remote_checksum_report = m
	case Input_Message:
		// Discard acked inputs
		#reverse for pending_input, i in sa.slice(&protocol.pending_local_inputs) {
			if pending_input.frame <= m.ack_frame {
				small_array_delete_to_index(&protocol.pending_local_inputs, i)
				break
			}
		}
		
		// Add inputs to rollback
		input_loop: for pending_input in sa.slice(&m.pending_inputs) {
			if pending_input.frame <= protocol.last_received_frame {
				continue
			}
			
			player_index := protocol.remote_player_index
			current_remote_frame := protocol.last_received_frame
			if current_remote_frame != Null_Frame && current_remote_frame + 1 != pending_input.frame {
				log.errorf("Input received for Player %v (%v) was not in sequence, expected frame %v got %v", player_index, protocol.client_id, current_remote_frame + 1, pending_input.frame)
				protocol_disconnect(rollback, protocol)
				return
			}

			if !rollback_add_input(rollback, player_index, pending_input.input, pending_input.frame) {
				log.errorf("Failed to add input for Player %v (%v) frame %v", player_index, protocol.client_id, pending_input.frame)
				break input_loop
			}

			protocol.last_received_frame = pending_input.frame
			rollback.connection_statuses[player_index].last_received_frame = pending_input.frame
		}

		// Update remote status
		for i in 0..<protocol.num_players {
			remote_status := &protocol.remote_connection_statuses[i]
			remote_status.disconnected = remote_status.disconnected || m.connection_statuses[i].disconnected
			remote_status.last_received_frame = max(remote_status.last_received_frame, m.connection_statuses[i].last_received_frame)
		}
	case Disconnect_Request:
		protocol_disconnect(protocol, rollback)
	case Keep_Alive:
	}

	if to_send.message != nil {
		protocol.last_send_time = now
	}

	return
}

protocol_update :: proc(rollback: ^Rollback_System($Game, $Input), protocol: P2P_Protocol(Input)) -> []Protocol_Message(Input) {
	now := time.now()

	messages := make([dynamic]Protocol_Message, len = 0, cap = 4, allocator = context.temp_allocator)

	switch protocol.state {
	case .Syncronizing:
		if time.diff(protocol.last_send_time, now) > RESEND_SYNC_INTERVAL {
			message := Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = Sync_Request { protocol.sync_random_request },
			}
			append(&messages, message)
		}
	case .Running:
		if time.diff(protocol.last_recv_time, now) > DISCONNECT_TIMEOUT {
			log.debugf("Protocol %v timed-out", protocol.client_id)
			protocol_disconnect(protocol, rollback)
			message := Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = Disconnect_Request {}
			}
			append(&messages, message)
			return messages[:]
		}

		// Validate checksum
		if protocol.remote_checksum_report.frame != Null_Frame && protocol.remote_checksum_report.frame == rollback.confirmed_checksum_report.frame {
			if protocol.remote_checksum_report.checksum != rollback.confirmed_checksum_report.checksum {
				log.infof(
					"Desync detected in protocol %v in frame %v (local %v - %v remote)",
					protocol.client_id,
					protocol.remote_checksum_report.frame,
					rollback.confirmed_checksum_report.checksum,
					protocol.remote_checksum_report.checksum
				)
				protocol_disconnect(protocol, rollback)
				message := Protocol_Message {
					magic = protocol.magic,
					client_id = protocol.client_id,
					message = Disconnect_Request {}
				}
				append(&messages, message)
				return messages[:]
			}
		}

		// Update frame advantage
		if protocol.last_received_frame != Null_Frame {
			ping := f32(protocol.rtt_secs / 2)
			remote_frame := f32(protocol.last_received_frame) + (ping * FPS)
			protocol.local_frame_advantage = clamp(remote_frame - f32(rollback.current_frame), -MAX_PREDICTION_FRAMES * 2, MAX_PREDICTION_FRAMES * 2)
			
			window_index := rollback.current_frame % FRAME_ADVANTAGE_WINDOW_SIZE
			protocol.local_frame_advantage_window[window_index]  = protocol.local_frame_advantage
			protocol.remote_frame_advantage_window[window_index] = protocol.remote_frame_advantage

			local_sum := math.sum(protocol.local_frame_advantage_window[:])
			local_avg := local_sum / FRAME_ADVANTAGE_WINDOW_SIZE

			remote_sum := math.sum(protocol.remote_frame_advantage_window[:])
			remote_avg := remote_sum / FRAME_ADVANTAGE_WINDOW_SIZE

			average_frames_ahead := (remote_avg - local_avg) / 2
			rollback.average_frames_ahead[protocol.remote_player_index] = average_frames_ahead 
		}

		// Update local connection status based on remote connection status
		rollback_update_status_from_remote(rollback, protocol.remote_connection_statuses)
		
		// Resend pending inputs if some time has passed without receiving inputs
		if sa.len(protocol.pending_local_inputs) > 0 && time.diff(protocol.running_last_input_send, now) > RESEND_INPUTS_INTERVAL {
			append(&messages, Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = Input_Message {
					pending_inputs = protocol.pending_local_inputs,
					ack_frame = protocol.last_received_frame,
					connection_statuses = rollback.connection_statuses,
				},
			})
			protocol.running_last_input_send = now
		}

		if time.diff(protocol.running_last_quality_report_send, now) > QUALITY_REPORT_INTERVAL {
			protocol.running_last_quality_report_send = now
			append(&messages, Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = Quality_Report {
					frame_advantage = protocol.local_frame_advantage,
					ping = now,
				},
			})
		}

		if time.diff(protocol.running_last_checksum_report_send, now) > CHECKSUM_REPORT_INTERVAL && rollback.confirmed_checksum_report.frame != Null_Frame {
			protocol.running_last_checksum_report_send = now
			append(&messages, Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = rollback.confirmed_checksum_report
			})
		}

		if len(messages) == 0 && time.diff(protocol.last_send_time, now) > KEEP_ALIVE_INTERVAL {
			append(&messages, Protocol_Message {
				magic = protocol.magic,
				client_id = protocol.client_id,
				message = Keep_Alive {},
			})
		}
	case .Disconnected:
	case .Initializing:
	}

	if len(messages) > 0 {
		protocol.last_send_time = now
	}

	return messages[:]
}

protocol_disconnect :: proc(rollback: ^Rollback_System($Game, $Input), protocol: ^P2P_Protocol(Input)) {
	protocol.state = .Disconnected
	rollback.connection_statuses[protocol.remote_player_index].disconnected = true
}

small_array_delete_to_index :: proc "contextless" (a: ^$A/sa.Small_Array($N, $T), index: int) -> (ok: bool) {
	if N > 0 && index < a.len {
		end_index := index + 1
		new_len := a.len - end_index
		if new_len > 0 {
			copy(a.data[:new_len], a.data[end_index:a.len])
		}
		a.len = new_len
		ok = true
	}
	return
}
