package main

import "core:fmt"

import rl "vendor:raylib"

draw_text :: proc(position: Vec2, font_size: int, color: rl.Color, format: string, args: ..any) {
	text := fmt.ctprintfln(format, ..args)
	rl.DrawText(text, i32(position.x), i32(position.y), i32(font_size), color)
}

draw_center_rect_text :: proc(text: cstring, rect: rl.Rectangle, font_size: f32, color: rl.Color = rl.WHITE) {
	size := rl.MeasureTextEx(rl.GetFontDefault(), text, font_size, 3)
	x := rect.x + ((rect.width - size.x) / 2)
	y := rect.y + ((rect.height - size.y) / 2)
	rl.DrawTextEx(rl.GetFontDefault(), text, { x, y }, font_size, 3, color)
}

draw_end_rect_text :: proc(text: cstring, rect: rl.Rectangle, font_size: f32, end_gap: f32, color: rl.Color = rl.WHITE) {
	size := rl.MeasureTextEx(rl.GetFontDefault(), text, font_size, 3)
	x := rect.x + rect.width - size.x - end_gap
	y := rect.y + ((rect.height - size.y) / 2)
	rl.DrawTextEx(rl.GetFontDefault(), text, { x, y }, font_size, 3, color)
}

split_rect_horizontal_center_dynamic :: proc(#any_int num_split: int, rect: rl.Rectangle, width: f32, gap: f32 = 0) -> []rl.Rectangle {
	rects := make([dynamic]rl.Rectangle, 0, num_split, context.temp_allocator)
	total_width := width * f32(num_split) + gap * f32(num_split - 1)

	x := rect.x + (rect.width - total_width) / 2
	for i in 0..<num_split {
		append(&rects, rl.Rectangle {
			x      = x,
			y      = rect.y,
			width  = width,
			height = rect.height,
		})
		x += width + gap
	}

	return rects[:]
}
