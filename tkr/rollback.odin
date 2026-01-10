package tkr

import "core:math"
import "core:log"
import "core:slice"
import "core:fmt"

MAX_NUM_PLAYERS :: 4
MAX_PREDICTION_FRAMES :: 8
INPUT_QUEUE_LENGTH :: MAX_PREDICTION_FRAMES * 4
CHECKSUM_FRAME_INTERVAL :: 60

Frame :: distinct i32
Null_Frame :: Frame(-1)
Predicted_Frame :: Frame(-2)

Game_Speed :: enum {
	Normal,
	Fast,
	Slow
}

Rollback_State :: struct($Game: typeid) {
	frame: Frame,
	state: Game,
	checksum: u32,
}

Player_Rollback_Input :: struct($Input: typeid) {
	frame: Frame,
	input: Input,
}

Input_Status :: enum {
	Confirmed,
	Predicted,
	Disconnected,
}

Connection_Status :: struct {
	disconnected: bool,
	last_received_frame: Frame
}

Rollback_System :: struct($Game, $Input: typeid) {
	num_players: int,
	game_states: [MAX_PREDICTION_FRAMES]Rollback_State(Game),
	
	players_inputs:       [MAX_NUM_PLAYERS][INPUT_QUEUE_LENGTH]Player_Rollback_Input(Input),
	connection_statuses:  [MAX_NUM_PLAYERS]Connection_Status,
	average_frames_ahead: [MAX_NUM_PLAYERS]f32,
	input_delay:          [MAX_NUM_PLAYERS]int,
	
	current_frame:               Frame,
	confirmed_frame:             Frame,
	first_incorrect_frame:       Frame,
	next_recommended_skip_frame: Frame,

	forced_rollback_frames: int,
	
	confirmed_checksum_report: Checksum_Report,
	pending_checksum_report:   Checksum_Report,
}

Save_Game :: struct($Game: typeid) {
	game_rollback_state: ^Rollback_State(Game),
}

Load_Game :: struct($Game: typeid) {
	game_rollback_state: ^Rollback_State(Game),
}

Skip_Frames :: struct {
	num_frames: int
}

Advance_Frame :: struct($Input: typeid) {
	inputs: [MAX_NUM_PLAYERS]Input,
	status: [MAX_NUM_PLAYERS]Input_Status,
	suggested_game_speed: Game_Speed,
}

Rollback_Request :: union($Game, $Input: typeid) {
	Save_Game(Game),
	Load_Game(Game),
	Advance_Frame(Input),
	Skip_Frames
}

min_frame :: proc(f1, f2: Frame) -> Frame {
	if f1 == Null_Frame {
		return f2
	} else if f2 == Null_Frame {
		return f1
	} else {
		return min(f1, f2)
	}
}

rollback_init :: proc(rollback: ^Rollback_System($Game, $Input), num_players: int) {
	for &player_state in rollback.players_inputs {
		player_state = Player_Rollback_Input(Input) { frame = Null_Frame }
	}

	for i in 0..<num_players {
		rollback.connection_statuses[i].last_received_frame = Null_Frame
	}

	rollback.num_players = num_players
	rollback.first_incorrect_frame = Null_Frame
	rollback.confirmed_frame       = Null_Frame
	rollback.confirmed_checksum_report.frame = Null_Frame
}

rollback_set_forced_rollback_frames :: proc(rollback: ^Rollback_System, num_frames: int) {
	rollback.forced_rollback_frames = clamp(num_frames, 0, MAX_PREDICTION_FRAMES - 1)
}

rollback_set_input_delay :: proc(rollback: ^Rollback_System($Game, $Input), player_index: int, delay: int) {
	delay := clamp(delay, 0, MAX_LOCAL_DELAY)
	current_delay := rollback.input_delay[player_index]
	if delay > current_delay {
		// Fill missing inputs with last input
		diff := delay - current_delay

		last_input_frame := rollback.connection_statuses[player_index].last_received_frame
		if last_input_frame == Null_Frame {
			last_input_frame = 0
		}
		last_input := rollback.players_inputs[player_index][last_input_frame % INPUT_QUEUE_LENGTH]

		for i in 1..=diff {
			index := (int(last_input_frame) + i) % INPUT_QUEUE_LENGTH
			rollback.players_inputs[player_index][index] = last_input
		}

		rollback.connection_statuses[player_index].last_received_frame = last_input_frame + Frame(diff)
	}

	rollback.input_delay[player_index] = delay
}

rollback_add_input :: proc(rollback: ^Rollback_System, player_index: int, input: $Input, frame: Frame) -> bool {
	frame := frame + Frame(rollback.input_delay[player_index])

	if rollback.current_frame + INPUT_QUEUE_LENGTH - MAX_PREDICTION_FRAMES < frame {
		return false
	}
	
	input_index := frame % INPUT_QUEUE_LENGTH
	player_state := &rollback.players_inputs[player_index][input_index]

	if player_state.frame == frame {
		// Already added input (input delay may have changed)
		return false
	}
	
	// Check for miss predictions
	if player_state.frame == Predicted_Frame && frame < rollback.current_frame {
		if player_state.input != input {
			rollback.first_incorrect_frame = min_frame(rollback.first_incorrect_frame, frame)
		}
	}

	player_state.input = input
	player_state.frame = frame

	connection_status := &rollback.connection_statuses[player_index]
	connection_status.last_received_frame = max(connection_status.last_received_frame, frame)

	return true
}

rollback_advance_frame :: proc(rollback: ^$T/Rollback_System($Game, $Input)) -> []Rollback_Request(Game, Input) {
	save_current_state :: proc(rollback: ^T) -> Save_Game {
		index := rollback.current_frame % MAX_PREDICTION_FRAMES
		rollback.game_states[index].frame = rollback.current_frame
		return Save_Game { &rollback.game_states[index] }
	}

	load_frame :: proc(rollback: ^T, frame: Frame) -> Load_Game {
		assert(frame != Null_Frame)
		assert(frame < rollback.current_frame)
		assert(frame > rollback.current_frame - MAX_PREDICTION_FRAMES)

		index := frame % MAX_PREDICTION_FRAMES
		assert(rollback.game_states[index].frame == frame)
		rollback.current_frame = frame
		
		return Load_Game { &rollback.game_states[index] }
	}

	requests := make([dynamic]Rollback_Request, allocator = context.temp_allocator)

	if rollback.current_frame == 0 {
		append(&requests, save_current_state(rollback))
	}

	// Update pending checksum
	for i in 0..<MAX_PREDICTION_FRAMES {
		if rollback.game_states[i].frame == rollback.pending_checksum_report.frame {
			rollback.pending_checksum_report.checksum = rollback.game_states[i].checksum
			break
		}
	}

	// If the pending report checksum frame is below the predicition window we are sure it was simulated without predicted input
	if rollback.pending_checksum_report.frame + MAX_PREDICTION_FRAMES < rollback.current_frame {
		rollback.confirmed_checksum_report = rollback.pending_checksum_report
		rollback.pending_checksum_report.frame = rollback.pending_checksum_report.frame + CHECKSUM_FRAME_INTERVAL
		rollback.pending_checksum_report.checksum = 0
	}

	confirmed_frame := max(Frame)
	for player_index in 0..<rollback.num_players {
		connection_status := rollback.connection_statuses[player_index]
		if !connection_status.disconnected {
			confirmed_frame = min(confirmed_frame, connection_status.last_received_frame)
		}
	}
	if confirmed_frame != max(Frame) {
		rollback.confirmed_frame = confirmed_frame
	}

	// Skip frames if our simulation is above the maximum prediction window
	{ 
		frames_ahead := rollback.current_frame - rollback.confirmed_frame
		if rollback.current_frame >= MAX_PREDICTION_FRAMES && frames_ahead >= MAX_PREDICTION_FRAMES {
			log.debugf("Skipping frames becaused reached maximum predition window (current %v - confirmed %v)", rollback.current_frame, rollback.confirmed_frame)
			skip_frames := Skip_Frames { num_frames = MAX_PREDICTION_FRAMES / 2 }
			append(&requests, skip_frames)
			return requests[:]
		}
	}

	// Skip frames if our simulation is getting too far ahead from other players
	suggested_game_speed := Game_Speed.Normal
	{
		max_avarage_frames_ahead := min(f32)
		min_avarage_frames_ahead := max(f32)
		for i in 0..<rollback.num_players {
			if rollback.connection_statuses[i].disconnected {
				continue
			}

			max_avarage_frames_ahead = max(max_avarage_frames_ahead, rollback.average_frames_ahead[i])
			min_avarage_frames_ahead = min(min_avarage_frames_ahead, rollback.average_frames_ahead[i])
		}

		MIN_RECOMMENDATION :: 1.5
		if max_avarage_frames_ahead >= MIN_RECOMMENDATION {
			suggested_game_speed = .Slow
		} else if min_avarage_frames_ahead <= -MIN_RECOMMENDATION {
			suggested_game_speed = .Fast
		}	
	}

	if rollback.forced_rollback_frames > 0 && rollback.current_frame > 0 {
		forced_rollback_frame := rollback.current_frame - Frame(rollback.forced_rollback_frames)

		if rollback.first_incorrect_frame != Null_Frame {
			rollback.first_incorrect_frame = min(rollback.current_frame, forced_rollback_frame)
		} else {
			rollback.first_incorrect_frame = forced_rollback_frame
		}

		rollback.first_incorrect_frame = max(rollback.first_incorrect_frame, 0)
	}

	// Execute rollback if necessary
	if rollback.first_incorrect_frame != Null_Frame {
		num_frames := rollback.current_frame - rollback.first_incorrect_frame
		append(&requests, load_frame(rollback, rollback.first_incorrect_frame))

		for i in 0..<num_frames {
			// Don't need to save the first frame since we just loaded it
			if i != 0 {
				append(&requests, save_current_state(rollback))
			}

			inputs, statuses := verified_inputs(rollback)
			append(&requests, Advance_Frame { inputs, statuses, suggested_game_speed })
			rollback.current_frame += 1
		}

		rollback.first_incorrect_frame = Null_Frame
	}

	append(&requests, save_current_state(rollback))

	// Advance the frame
	inputs, statuses := verified_inputs(rollback)
	rollback.current_frame += 1
	append(&requests, Advance_Frame { inputs, statuses, suggested_game_speed })

	return requests[:]
}

verified_inputs :: proc(rollback: ^Rollback_System($Game, $Input)) -> (inputs: [MAX_NUM_PLAYERS]Input, statuses: [MAX_NUM_PLAYERS]Input_Status) {
	for player_index in 0..<rollback.num_players {
		connection_status := &rollback.connection_statuses[player_index]
		if connection_status.disconnected && rollback.current_frame > connection_status.last_received_frame {
			statuses[player_index] = .Disconnected
		} else {
			input_index := rollback.current_frame % INPUT_QUEUE_LENGTH
			player_input := &rollback.players_inputs[player_index][input_index]
			
			if player_input.frame == rollback.current_frame {
				// We actually have the input
				statuses[player_index] = .Confirmed
				inputs[player_index]   = player_input.input
			} else {
				// We don't have the input, predict it based on the previous one
				previous_index := (input_index - 1 + INPUT_QUEUE_LENGTH) % INPUT_QUEUE_LENGTH
				player_input.input = rollback.players_inputs[player_index][previous_index].input
				player_input.frame = Predicted_Frame
				statuses[player_index] = .Predicted
				inputs[player_index]   = player_input.input
			}
		}
	}

	return
}

rollback_update_status_from_remote :: proc(rollback: ^Rollback_System, statuses: [MAX_NUM_PLAYERS]Connection_Status) {
	for player_index in 0..<rollback.num_players {
		local_status := &rollback.connection_statuses[player_index]
		remote_status := statuses[player_index]
		current_last_received_frame := local_status.last_received_frame

		if remote_status.disconnected {
			local_status.disconnected = true
			local_status.last_received_frame = min_frame(local_status.last_received_frame, remote_status.last_received_frame)
		}

		if local_status.disconnected && current_last_received_frame != local_status.last_received_frame {
			rollback.first_incorrect_frame = min_frame(rollback.first_incorrect_frame, local_status.last_received_frame)
		}
	}
}
