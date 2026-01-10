package main

import "core:log"
import "core:mem"
import "core:fmt"
import "core:net"
import "core:hash"
import "core:strconv"
import sa "core:container/small_array"
import "core:math"
import "core:math/linalg"
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



Action :: enum {
	Left,
	Right,
	Up,
	Down,
	Shoot,
	Dash
}

Player :: struct {
	color:    rl.Color,
	position: Vec2
}

Player_Colors: [tkr.MAX_NUM_PLAYERS]rl.Color = {
	rl.RED, rl.BLUE, rl.GREEN, rl.YELLOW
}

Game :: struct {
	frame: int,
	players: sa.Small_Array(tkr.MAX_NUM_PLAYERS, Player),
}

Input :: struct {
	down:    bit_set[Action; u8],
	pressed: bit_set[Action; u8],
}

serialize_input :: proc(bs: ^tkr.Buffer_Serializer, input: Input) -> bool {
	tkr.bs_put_u8(bs, transmute(u8)input.down)    or_return
	tkr.bs_put_u8(bs, transmute(u8)input.pressed) or_return

	return true
}

deserialize_input :: proc(bs: ^tkr.Buffer_Serializer) -> (input: Input, ok: bool) {
	down_u8   := tkr.bs_get_u8(bs) or_return
	input.down = transmute(bit_set[Action; u8])down_u8

	pressed_u8   := tkr.bs_get_u8(bs) or_return
	input.pressed = transmute(bit_set[Action; u8])down_u8

	ok = true
	return
}

get_input :: proc() -> (input: Input) {
	if rl.IsKeyDown(.LEFT)       { input.down += { .Left  } }
	if rl.IsKeyDown(.RIGHT)      { input.down += { .Right } }
	if rl.IsKeyDown(.UP)         { input.down += { .Up    } }
	if rl.IsKeyDown(.DOWN)       { input.down += { .Down  } }
	if rl.IsKeyDown(.SPACE)      { input.down += { .Shoot } }
	if rl.IsKeyDown(.LEFT_SHIFT) { input.down += { .Dash  } }

	if rl.IsKeyPressed(.LEFT)       { input.pressed += { .Left  } }
	if rl.IsKeyPressed(.RIGHT)      { input.pressed += { .Right } }
	if rl.IsKeyPressed(.UP)         { input.pressed += { .Up    } }
	if rl.IsKeyPressed(.DOWN)       { input.pressed += { .Down  } }
	if rl.IsKeyPressed(.SPACE)      { input.pressed += { .Shoot } }
	if rl.IsKeyPressed(.LEFT_SHIFT) { input.pressed += { .Dash  } }

	return input
}

vector2_from_input :: proc(input: Input) -> (dir: Vec2) {
	if .Left  in input.down { dir.x -= 1 } 
	if .Right in input.down { dir.x += 1 } 
	if .Up    in input.down { dir.y -= 1 } 
	if .Down  in input.down { dir.y += 1 }

	return linalg.vector_normalize0(dir)
}

PLAYER_SPEED :: 100.0 * DELTA

game: Game

p2p: tkr.P2P_Session(Game, Input)
transport: tkr.UDP_Transport

previous_tick: time.Tick
delta_accumulator: f32
skip_frames: int
game_speed: tkr.Game_Speed = .Normal
local_input: Input

game_init :: proc(num_players: int) {
	for i in 0..<num_players {
		sa.append(&game.players, Player {
			color    = Player_Colors[i],
			position = { f32(i) * 100, f32(i) * 100 }
		})
	}
}

game_update :: proc(inputs: [tkr.MAX_NUM_PLAYERS]Input) {
	game.frame += 1
	for &player, i in sa.slice(&game.players) {
		dir := vector2_from_input(inputs[i])
		player.position += dir * PLAYER_SPEED
	}
}

game_draw :: proc() {
	for &player, i in sa.slice(&game.players) {
		rl.DrawCircleV(player.position, 16, player.color)
	}
}

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

	num_players: int = len(os.args) - 2
	assert(num_players > 0)
	client_index := strconv.atoi(os.args[1])
	assert(client_index < num_players)
	player_addresses: [dynamic]net.Endpoint

	for i in 0..<num_players {
		player_endpoint, ok := net.parse_endpoint(os.args[i + 2])
		if ! ok {
			fmt.panicf("Failed to parse player(%V) address: %v", i, os.args[i + 2])
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

	game_init(num_players)

	tkr.p2p_init(&p2p, num_players, 0, FPS, serialize_input, deserialize_input)
	tkr.udp_transport_init(&transport, num_players, player_addresses[client_index])

	fmt.println(num_players, client_index, player_addresses)

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

		for _ in 0..<num_ticks {
			if skip_frames > 0 {
				skip_frames -= 1
				continue
			}

			tkr.p2p_add_local_input(&p2p, client_index, local_input)
			// Clear pressed input in case of multiple ticks in a single frame 
			local_input.pressed = {}

			requests, messages_to_send := tkr.p2p_advance_frame(&p2p)
			tkr.udp_transport_send_messages(&transport, &p2p, messages_to_send)

			rollback_happened := false

			for request in requests {
				switch &r in request {
				case tkr.Save_Game(Game):
					r.game_rollback_state.state = game
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
		game_draw()
		rl.EndDrawing()
	}
}
