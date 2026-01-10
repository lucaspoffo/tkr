package main

import "core:log"
import "core:mem"
import "core:fmt"
import sa "core:container/small_array"
import "core:math/linalg"

import rl "vendor:raylib"
import tkr "../tkr"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600

Vec2 :: [2]f32

Action :: enum {
	Left,
	Right,
	Up,
	Down,
	Shoot,
	Dash
}

Input :: struct {
	down:    bit_set[Action; u8],
	pressed: bit_set[Action; u8],
}

Game :: struct {

}

vector2_from_input :: proc(input: Input) -> (dir: Vec2) {
	if .Left  in input.down { dir.x -= 1 } 
	if .Right in input.down { dir.x += 1 } 
	if .Up    in input.down { dir.y -= 1 } 
	if .Down  in input.down { dir.y += 1 }

	return linalg.vector_normalize0(dir)
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
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "TKR Example")

	for !rl.WindowShouldClose() {


		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.DrawRectangleV({ 0, 0 }, { 100, 100 }, rl.RED)
		rl.EndDrawing()
	}
}
