package main

import "core:fmt"
import sa "core:container/small_array"

Handle :: struct($T: typeid) {
	index:      u32,
	generation: u32,
}

Handle_Map :: struct($N: int, $T: typeid) where N >= 0 {
	values:      [N]Maybe(T),
	generations: [N]u32,
	len:         u32,
	free_index:  sa.Small_Array(N, u32),
}

hm_clear :: proc(m: ^$M/Handle_Map($N, $T)) {
	m.len = 0
	sa.clear(&m.free_index)
	m.generations = 0
	m.values = {}
}

@(require_results)
has_handle :: proc(m: ^$M/Handle_Map($N, $T), h: Handle(T)) -> bool {
	if int(h.index) >= N {
		return false
	}

	return m.generations[h.index] == h.generation
}

@(require_results)
hm_get :: proc(m: ^$M/Handle_Map($N, $T), h: Handle(T)) -> (^T, bool) {
	if has_handle(m, h) {
		return &m.values[h.index].?
	}

	return nil, false
}

hm_insert :: proc(m: ^$M/Handle_Map($N, $T), value: T) -> (Handle(T), bool) {
	if int(m.len) >= N {
		fmt.printfln("Failed to insert value in Handle_Map(%T), max len: %v", value, N)
		return Handle(T) {}, false
	}

	index: u32 = m.len
	m.len += 1
	if sa.len(m.free_index) > 0 {
		index = sa.pop_back(&m.free_index)
	}

	// Make generation 0 always invalid
	if m.generations[index] == 0 {
		m.generations[index] += 1
	}

	m.values[index] = value
	handle := Handle(T) {
		index = index,
		generation = m.generations[index],
	}

	return handle, true
}

hm_remove :: proc(m: ^$M/Handle_Map($N, $T), handle: Handle(T)) -> (value: Maybe(T)) {
	if has_handle(m, handle) {
		index := handle.index
		m.generations[index] += 1
		m.len -= 1
		sa.push(&m.free_index, index)
		value = m.values[index]
		m.values[index] = nil
	}

	return
}

Handle_Map_Iterator :: struct($N: int , $T: typeid)  {
    handle_map: ^Handle_Map(N, T),
    index: int,
}

make_hm_iterator :: proc(handle_map: ^Handle_Map($N, $T)) -> Handle_Map_Iterator(N, T) {
    return Handle_Map_Iterator(N, T) { handle_map = handle_map, index = 0 }
}

iterate_hm :: proc (it: ^Handle_Map_Iterator($N, $T)) -> (^T, Handle(T), bool) {
    for it.index < N {
        if value, ok := &it.handle_map.values[it.index].?; ok {
        	handle := Handle(T) { index = u32(it.index), generation = it.handle_map.generations[it.index] }
            it.index += 1
            return value, handle, true
        }

        it.index += 1
    }

    return nil, Handle(T) {}, false
}
