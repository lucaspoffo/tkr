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

PROJECTILE_SPEED :: 600 * DELTA
PLAYER_SPEED :: 300.0 * DELTA
ATTACK_COOLDOWN :: 1.0
DASH_SPEED :: 550 * DELTA
DASH_DURATION :: 0.300
DASH_COOLDOWN :: 2.0

DEATH_DURATION :: 0.5
RESPAWN_DURATION :: 1.5
INVUNERABLE_DURATION :: 2.5

PLAYER_SIZE :: 16
PLAYER_DASH_SIZE :: 8
PROJECTILE_SIZE :: 4

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

Player_State :: enum {
	Dead,
	Respawn,
	Dash,
	Normal
}

Player :: struct {
	score: int,
	input_index: int,
	
	state: Player_State,
	color: rl.Color,
	invunerable: bool,
	position: Vec2,
	look_direction: Vec2,
	
	attack_timer: f32,
	dash_timer:   f32,

	dash_duration:    f32,
	death_duration:   f32,
	respawn_duration: f32,
	invunerable_duration: f32,
}

Respawn_Position := [tkr.MAX_NUM_PLAYERS]Vec2 {
	{ WINDOW_WIDTH / 2 ,  100 },
	{ WINDOW_WIDTH / 2,   WINDOW_HEIGHT - 100 },
	{ 100,                WINDOW_HEIGHT / 2 },
	{ WINDOW_WIDTH - 100, WINDOW_HEIGHT / 2 },
}

Projectile :: struct {
	color:     rl.Color,
	position:  Vec2,
	direction: Vec2,
	owner:     Handle(Player),
}

Player_Colors: [tkr.MAX_NUM_PLAYERS]rl.Color = {
	rl.RED, rl.BLUE, rl.GREEN, rl.YELLOW
}

Game :: struct {
	frame: int,
	players:     Handle_Map(tkr.MAX_NUM_PLAYERS, Player),
	projectiles: Handle_Map(32, Projectile),
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
	input.pressed = transmute(bit_set[Action; u8])pressed_u8

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
		hm_insert(&game.players, Player {
			state = .Normal,
			input_index = i,
			color    = Player_Colors[i],
			look_direction = { 1, 0 },
			position = Respawn_Position[i]
		})
	}
}

game_update :: proc(inputs: [tkr.MAX_NUM_PLAYERS]Input) {
	game.frame += 1
	player_it := make_hm_iterator(&game.players)
	for player, player_handle in iterate_hm(&player_it) {
		input := inputs[player.input_index]
		direction := vector2_from_input(input)
		player.attack_timer = max(0, player.attack_timer - DELTA)
		player.dash_timer = max(0, player.dash_timer - DELTA)
		player.invunerable_duration -= DELTA
		if player.invunerable_duration <= 0 {
			player.invunerable = false
		}

		switch player.state {
		case .Dead:
			player.death_duration -= DELTA
			if player.death_duration < 0 {
				player.respawn_duration = RESPAWN_DURATION
				player.position = Respawn_Position[game.frame % tkr.MAX_NUM_PLAYERS]
				player.state = .Respawn
				player.invunerable = true
				player.invunerable_duration = INVUNERABLE_DURATION
			} 
		case .Respawn:
			player.respawn_duration -= DELTA
			if player.respawn_duration < 0 {
				player.state = .Normal
			}
		case .Dash:
			player.position += player.look_direction * DASH_SPEED
			player.dash_duration -= DELTA
			if player.dash_duration <= 0 {
				player.state = .Normal
				player.dash_duration = 0
			}
		case .Normal:
			if direction != { 0, 0 } {
				player.look_direction = direction
			}

			player.position += direction * PLAYER_SPEED
			if player.dash_timer <= 0 && .Dash in input.pressed {
				player.dash_timer = DASH_COOLDOWN
				player.state = .Dash
				player.dash_duration = DASH_DURATION
			}

			if player.attack_timer <= 0 && .Shoot in input.pressed {
				player.attack_timer = ATTACK_COOLDOWN
				projectile := Projectile {
					position  = player.position,
					direction = player.look_direction,
					color     = player.color,
					owner     = player_handle
				}
				hm_insert(&game.projectiles, projectile)
			}
		}		
	}

	projectile_it := make_hm_iterator(&game.projectiles)
	loop_projectile: for projectile, projectile_handle in iterate_hm(&projectile_it) {
		projectile.position += projectile.direction * PROJECTILE_SPEED

		player_it := make_hm_iterator(&game.players)
		for player, player_handle in iterate_hm(&player_it) {
			if player_handle == projectile.owner || player.state == .Dead {
				continue
			}

			player_size: f32 = player.state == .Dash ? PLAYER_DASH_SIZE : PLAYER_SIZE
			if rl.CheckCollisionCircles(player.position, player_size, projectile.position, PROJECTILE_SIZE) {				
				if !player.invunerable {
					player.state = .Dead
					player.death_duration = DEATH_DURATION
					killer, ok := hm_get(&game.players, projectile.owner)
					assert(ok)
					killer.score += 1
				}

				hm_remove(&game.projectiles, projectile_handle)
				continue loop_projectile
			}
		}

		if projectile.position.x < 0 || projectile.position.x > WINDOW_WIDTH || projectile.position.y < 0 || projectile.position.y > WINDOW_HEIGHT {
			hm_remove(&game.projectiles, projectile_handle)
		}
	}
}

game_draw :: proc() {
	player_it := make_hm_iterator(&game.players)
	for player in iterate_hm(&player_it) {
		if player.state == .Dead {
			continue
		}

		if player.invunerable {
			INVULNERABLE_BLINK_FRAMES :: 9
			if (game.frame % (INVULNERABLE_BLINK_FRAMES * 2) < INVULNERABLE_BLINK_FRAMES) {
				continue
			}
		}

		size: f32 = 1 - (player.attack_timer / ATTACK_COOLDOWN)
		if player.state == .Respawn {
			size = 1 - (player.respawn_duration / RESPAWN_DURATION)
		}

		player_size: f32 = player.state == .Dash ? PLAYER_DASH_SIZE : PLAYER_SIZE

		rl.DrawCircleV(player.position, player_size * size, player.color)
		rl.DrawCircleLinesV(player.position, player_size, player.color)
	}

	projectile_it := make_hm_iterator(&game.projectiles)
	for projectile in iterate_hm(&projectile_it) {
		rl.DrawCircleV(projectile.position, PROJECTILE_SIZE, projectile.color)
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

	// The number of player and clients information should come from a Lobby System or Matchmaking,
	// In the example we pass those in the cmd arguments. 
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
