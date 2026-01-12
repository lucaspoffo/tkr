package main

import "core:log"
import "core:mem"
import "core:fmt"
import "core:net"
import "core:hash"
import "core:strconv"
import sa "core:container/small_array"
import "core:math"
import "core:os"
import "core:time"

import rl "vendor:raylib"
import tkr "../tkr"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600

FPS :: 60.0
DELTA :: 1.0 / FPS

TIME_SCALE := [tkr.Game_Speed]f32 {
	.Normal = 1.00,
	.Slow   = 0.99,
	.Fast   = 1.01,
}

Vec2 :: [2]f32

game: Game

p2p: tkr.P2P_Session(Game, Input)
transport: tkr.UDP_Transport

previous_tick: time.Tick
delta_accumulator: f32
skip_frames: int

game_speed: tkr.Game_Speed = .Normal
local_input: Input

show_debug_info := false

main :: proc() {
	context.logger = log.create_console_logger()

	default_allocator := context.allocator
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, default_allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)
	defer {
		for _, value in tracking_allocator.allocation_map {
			fmt.printf("%v: Leaked %v bytes\n", value.location, value.size)
		}
		mem.tracking_allocator_clear(&tracking_allocator)
	}

	// The number of player and clients information usually come from a Lobby System or Matchmaking,
	// In this example we pass these in the cmd arguments. 
	num_players: int = len(os.args) - 2
	assert(num_players > 0)

	client_index := strconv.atoi(os.args[1])
	assert(client_index >= 0 && client_index < num_players)
	
	player_addresses: [dynamic]net.Endpoint
	for i in 0..<num_players {
		player_endpoint, ok := net.parse_endpoint(os.args[i + 2])
		if !ok {
			fmt.panicf("Failed to parse client %v address: %v", i, os.args[i + 2])
		}

		append(&player_addresses, player_endpoint)
		if i == client_index {
			tkr.p2p_add_local_player(&p2p, i)
		} else {
			client_id := u64(i)
			tkr.p2p_add_remote_player(&p2p, i, client_id)
			tkr.udp_transport_add_client(&transport, client_id, player_endpoint)
		}
	}

	fmt.printfln("Initializing the game for player %v (%v) with %v players.", client_index, player_addresses, num_players)
	game_init(num_players)

	tkr.p2p_init(&p2p, num_players, FPS, serialize_input, deserialize_input)
	tkr.udp_transport_init(&transport, num_players, player_addresses[client_index])

	// This forces to rollback 5 frames every frame even if no miss predection occured.
	// Good for testing the determinism of the game_update.
	// tkr.rollback_set_forced_rollback_frames(&p2p.rollback, 5)

	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "TKR Example")

	for !rl.WindowShouldClose() {
		frame_duration := f32(time.duration_seconds(time.tick_since(previous_tick)))
		previous_tick = time.tick_now()
		delta_accumulator += frame_duration
		num_ticks := int(math.floor(delta_accumulator / DELTA))	
		delta_accumulator -= f32(num_ticks) * (DELTA / TIME_SCALE[game_speed])
		
		{ // Accumulate inputs
			input := get_input()
			local_input.pressed += input.pressed
			local_input.down    += input.down
		}

		messages_to_send := tkr.p2p_update(&p2p)
		tkr.udp_transport_send_messages(&transport, &p2p, messages_to_send)
		tkr.udp_transport_poll(&transport, &p2p)

		if rl.IsKeyPressed(.F1) {
			show_debug_info = !show_debug_info
		}

		if rl.IsKeyPressed(.F4) {
			p2p.dynamic_delay = !p2p.dynamic_delay
		}

		if rl.IsKeyPressed(.F5) {
			tkr.p2p_set_local_input_delay(&p2p, p2p.local_input_delay - 1)
			p2p.dynamic_delay = false
		}

		if rl.IsKeyPressed(.F6) {
			tkr.p2p_set_local_input_delay(&p2p, p2p.local_input_delay + 1)
			p2p.dynamic_delay = false
		}

		for _ in 0..<num_ticks {
			if skip_frames > 0 {
				skip_frames -= 1
				continue
			}

			tkr.p2p_add_local_input(&p2p, client_index, local_input)
			// Clear pressed inputs in case of multiple ticks in a single frame
			local_input.pressed = {}

			requests, messages_to_send := tkr.p2p_advance_frame(&p2p)
			tkr.udp_transport_send_messages(&transport, &p2p, messages_to_send)

			for request in requests {
				switch &r in request {
				case tkr.Save_Game(Game):
					// If your game state has dynamic allocations, make sure to delete them from the old (game_rollback_state.state) before overwritting it. 
					r.game_rollback_state.state = game

					// You don't need to calculate the checksum every frame, you can do it every tkr.CHECKSUM_FRAME_INTERVAL frames if this is expensive.
					r.game_rollback_state.checksum = hash.crc32(mem.ptr_to_bytes(&game))
					log.debugf("Save Game frame %v (%v)", r.game_rollback_state.frame, r.game_rollback_state.checksum)
				case tkr.Load_Game(Game):
					log.debug("Load Game frame ", r.game_rollback_state.frame)
					game = r.game_rollback_state.state
				case tkr.Advance_Frame(Input):
					log.debug("Advance frame: ", game.frame)
					game_update(r.inputs)
					game_speed = r.suggested_game_speed
				case tkr.Skip_Frames:
					log.debug("Skip frames ", r.num_frames)
					skip_frames = r.num_frames
				}	
			}
		}

		if num_ticks > 0 {
			local_input = {}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		if p2p.syncronizing {
			draw_center_rect_text("Syncronizing", { 0, 0, WINDOW_WIDTH, WINDOW_HEIGHT }, 32)
		} else {
			game_draw()
		}
		
		rl.EndDrawing()
	}

	tkr.udp_transport_shutdown(&transport)
}
