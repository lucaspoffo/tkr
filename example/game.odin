package main

import "core:fmt"
import "core:strings"

import "core:math/linalg"

import rl "vendor:raylib"
import tkr "../tkr"

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

PLAYABLE_RECT :: rl.Rectangle { 32, 64, WINDOW_WIDTH - 64, WINDOW_HEIGHT - 96 }

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

clamp_circle_inside_rect :: proc(position: Vec2, radius: f32, rect: rl.Rectangle) -> Vec2 {
	result := position
	result.x = clamp(position.x, rect.x + radius, rect.x + rect.width - radius)
	result.y = clamp(position.y, rect.y + radius, rect.y + rect.height - radius)

	return result
}

player_size :: proc(player: ^Player) -> f32 {
	return player.state == .Dash ? PLAYER_DASH_SIZE : PLAYER_SIZE
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

		player.position = clamp_circle_inside_rect(player.position, player_size(player), PLAYABLE_RECT)
	}

	projectile_it := make_hm_iterator(&game.projectiles)
	loop_projectile: for projectile, projectile_handle in iterate_hm(&projectile_it) {
		projectile.position += projectile.direction * PROJECTILE_SPEED

		player_it := make_hm_iterator(&game.players)
		for player, player_handle in iterate_hm(&player_it) {
			if player_handle == projectile.owner || player.state == .Dead {
				continue
			}

			if rl.CheckCollisionCircles(player.position, player_size(player), projectile.position, PROJECTILE_SIZE) {				
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

		if !rl.CheckCollisionPointRec(projectile.position, PLAYABLE_RECT) {
			hm_remove(&game.projectiles, projectile_handle)
		}
	}
}

game_draw :: proc() {
	// Draw Gameplay
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

	rl.DrawRectangleLinesEx(PLAYABLE_RECT, 1, rl.WHITE)

	// Draw Interface
	if show_debug_info {
		draw_text({ 4,  4 }, 20, rl.LIME, "GAME SPEED: %v", game_speed)

		pings  := make([dynamic]string, context.temp_allocator)
		frames := make([dynamic]string, context.temp_allocator)
		for i in 0..<p2p.num_protocols {
			protocol := &p2p.protocols[i]
			ping := fmt.tprintf("(P%v: %.1f ms)", protocol.client_id, protocol.rtt_secs * 1000)
			append(&pings, ping)

			ahead := fmt.tprintf("(P%v: %+.2f)", protocol.client_id, protocol.average_frames_ahead)
			append(&frames, ahead)
		}
		draw_text({ 4, 24 }, 20, rl.LIME, "FRAMES AHEAD: %v", strings.join(frames[:], " | ", context.temp_allocator))
		draw_text({ 4, 44 }, 20, rl.LIME, "PINGS: %v", strings.join(pings[:], " | ", context.temp_allocator))
		
		draw_text({ 500, 4 }, 20, rl.LIME, "DELAY: %v (DYNAMIC %v)", p2p.local_input_delay, p2p.dynamic_delay ? "ON" : "OFF")
		draw_text({ 32, WINDOW_HEIGHT - 26 }, 20, rl.WHITE, "F4: Toggle dynamic delay | F5/F6: +/- Local input delay")
	} else {
		rects := split_rect_horizontal_center_dynamic(game.players.len, { 0, 16, WINDOW_WIDTH, 32 }, 64, 32)
		player_it = make_hm_iterator(&game.players)
		i := 0
		for player in iterate_hm(&player_it) {
			rect := rects[i]
			rl.DrawRectangleLinesEx(rect, 1, player.color)
			rl.DrawCircleV({ rect.x + 16, rect.y + 16 }, 8, player.color)
			score_text := fmt.ctprint(player.score)
			draw_end_rect_text(score_text, rect, 20, 4, rl.WHITE)
			i += 1
		}

		draw_text({ 32, WINDOW_HEIGHT - 26 }, 20, rl.WHITE, "Move: Arrow Keys | Shoot: Space | Dash: Left Shift | F1: Show debug info")
	}
}