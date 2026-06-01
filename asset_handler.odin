package editor

// Asset handling, optimization, and baking helpers for editor workflows.
// Texture baking lives in the shared asset_manager package so runtime can use it too.

import mo "/../Engine/Libs/meshoptimizer"
import am "/../Engine/asset_manager"
import "core:c"
import "core:log"

Loaded_Texture :: am.Loaded_Texture
Atlas_Bake_Input :: am.Atlas_Bake_Input

unused_procs :: proc() {
	// ==================
}

unused_struct :: struct {
	// ==================
}

Unusedvar : int

unusedUnion :: union {
	// ==================
}

// TEST CASES FOR ANALYZER ADVANCED CHECKS
large_proc_test :: proc() {
	// 55 lines
	a := 0
	b := 1
	c := 2
	d := 3
	e := 4
	f := 5
	g := 6
	h := 7
	i := 8
	j := 9
	k := 10
	l := 11
	m := 12
	n := 13
	o := 14
	p := 15
	q := 16
	r := 17
	s := 18
	t := 19
	u := 20
	v := 21
	w := 22
	x := 23
	y := 24
	z := 25
	aa := 26
	ab := 27
	ac := 28
	ad := 29
	ae := 30
	af := 31
	ag := 32
	ah := 33
	ai := 34
	aj := 35
	ak := 36
	al := 37
	am := 38
	an := 39
	ao := 40
	ap := 41
	aq := 42
	ar := 43
	as := 44
	at := 45
	au := 46
	av := 47
	aw := 48
	ax := 49
	ay := 50
	az := 51
	ba := 52
	bb := 53
	bc := 54
}

nested_loop_test :: proc() {
	for i in 0..=10 {
		for j in 0..=10 {
			// nested
		}
	}
}

alloc_in_loop_test :: proc() {
	for i in 0..=10 {
		arr := make([]int, 10)
		arr[0] = i;
	}
}

load_texture_from_file :: proc(
	file_path: string,
	allocator := context.allocator,
) -> (
	tex: Loaded_Texture,
	ok: bool,
) {
	return am.load_texture_from_file(file_path, allocator)
}

free_texture :: proc(tex: Loaded_Texture, allocator := context.allocator) {
	am.free_texture(tex, allocator)
}

sample_texture :: proc(tex: Loaded_Texture, u, v: f32) -> [4]u8 {
	return am.sample_texture(tex, u, v)
}

bake_texture_into_atlas :: proc(
	src: Loaded_Texture,
	dst: [^]u8,
	dst_width, dst_height: i32,
	dest_x, dest_y: i32,
	dest_width, dest_height: i32,
) {
	am.bake_texture_into_atlas(
		src,
		dst,
		dst_width,
		dst_height,
		dest_x,
		dest_y,
		dest_width,
		dest_height,
	)
}

bake_atlas_page :: proc(
	inputs: []Atlas_Bake_Input,
	page_width, page_height: i32,
	allocator := context.allocator,
) -> (
	pixels: [^]u8,
	ok: bool,
) {
	return am.bake_atlas_page(inputs, page_width, page_height, allocator)
}

// ============================================================================
// Mesh Optimization with meshoptimizer
// ============================================================================

Mesh_Optimize_Input :: struct {
	name:         string,
	indices:      [dynamic]u32,
	vertices:     [dynamic][3]f32,
	target_ratio: f32,
	lock_borders: bool,
}

optimize_mesh_simplify :: proc(
	input: Mesh_Optimize_Input,
	allocator := context.allocator,
) -> (
	indices: [dynamic]u32,
	simplification_error: f32,
	ok: bool,
) {
	if len(input.indices) == 0 || len(input.vertices) == 0 {
		return {}, 0, false
	}
	target_count := c.size_t(f32(len(input.indices)) * input.target_ratio)
	target_count = max(target_count, 3)
	indices = make([dynamic]u32, len(input.indices), allocator)
	defer if !ok {
		delete(indices)
	}
	positions := make([dynamic]f32, len(input.vertices) * 3, allocator)
	defer delete(positions)
	for i := 0; i < len(input.vertices); i += 1 {
		v := input.vertices[i]
		positions[i * 3 + 0] = v.x
		positions[i * 3 + 1] = v.y
		positions[i * 3 + 2] = v.z
	}
	options := mo.Simplify_Flags{}
	if input.lock_borders {
		options |= mo.SIMPLIFY_LOCK_BORDER
	}
	simplification_error = 0
	lod_indices := mo.simplify(
		raw_data(indices[:]),
		raw_data(input.indices[:]),
		c.size_t(len(input.indices)),
		raw_data(positions[:]),
		c.size_t(len(input.vertices)),
		size_of(f32) * 3,
		target_count,
		0.01,
		options,
		&simplification_error,
	)
	if lod_indices == 0 {
		return {}, 0, false
	}
	resize(&indices, int(lod_indices))
	return indices, simplification_error, true
}

optimize_mesh_vertex_cache :: proc(
	indices: [dynamic]u32,
	vertex_count: u32,
	allocator := context.allocator,
) -> (
	optimized: [dynamic]u32,
) {
	if len(indices) == 0 {
		return {}
	}
	optimized = make([dynamic]u32, len(indices), allocator)
	mo.optimizeVertexCache(
		raw_data(optimized[:]),
		raw_data(indices[:]),
		c.size_t(len(indices)),
		c.size_t(vertex_count),
	)
	return optimized
}

optimize_mesh_vertex_fetch :: proc(
	indices: [dynamic]u32,
	vertices: rawptr,
	vertex_count: u32,
	vertex_size: u32,
	allocator := context.allocator,
) -> (
	vertex_count_new: u32,
	remap: [dynamic]u32,
	ok: bool,
) {
	if len(indices) == 0 || vertices == nil {
		return 0, {}, false
	}
	remap = make([dynamic]u32, vertex_count, allocator)
	defer if !ok {
		delete(remap)
	}
	new_vertex_count := mo.optimizeVertexFetchRemap(
		raw_data(remap[:]),
		raw_data(indices[:]),
		c.size_t(len(indices)),
		c.size_t(vertex_count),
	)
	if new_vertex_count == 0 || new_vertex_count > c.size_t(vertex_count) {
		return 0, {}, false
	}
	return u32(new_vertex_count), remap, true
}


optimize_mesh_overdraw :: proc(
	input: Mesh_Optimize_Input,
	threshold: f32 = 1.05,
	allocator := context.allocator,
) -> (
	indices: [dynamic]u32,
	ok: bool,
) {
	if len(input.indices) == 0 || len(input.vertices) == 0 {
		return {}, false
	}
	indices = make([dynamic]u32, len(input.indices), allocator)
	defer if !ok {
		delete(indices)
	}
	positions := make([dynamic]f32, len(input.vertices) * 3, allocator)
	defer delete(positions)
	for i := 0; i < len(input.vertices); i += 1 {
		v := input.vertices[i]
		positions[i * 3 + 0] = v.x
		positions[i * 3 + 1] = v.y
		positions[i * 3 + 2] = v.z
	}
	mo.optimizeOverdraw(
		raw_data(indices[:]),
		raw_data(input.indices[:]),
		c.size_t(len(input.indices)),
		raw_data(positions[:]),
		c.size_t(len(input.vertices)),
		size_of(f32) * 3,
		threshold,
	)
	return indices, true
}

optimize_mesh_vertex_remap :: proc(
	indices: [dynamic]u32,
	vertices: rawptr,
	vertex_count: u32,
	vertex_size: u32,
	allocator := context.allocator,
) -> (
	remap: [dynamic]u32,
	unique_vertex_count: u32,
	ok: bool,
) {
	if len(indices) == 0 || vertices == nil {
		return {}, 0, false
	}
	remap = make([dynamic]u32, vertex_count, allocator)
	defer if !ok {
		delete(remap)
	}
	new_count := mo.generateVertexRemap(
		raw_data(remap[:]),
		raw_data(indices[:]),
		c.size_t(len(indices)),
		vertices,
		c.size_t(vertex_count),
		c.size_t(vertex_size),
	)
	if new_count == 0 || new_count > c.size_t(vertex_count) {
		return {}, 0, false
	}
	return remap, u32(new_count), true
}

// ============================================================================
// GPU Integration (Opaque)
// ============================================================================
// These procedures handle GPU image creation from baked atlas pages.
// Uses void pointers to avoid cross-package type dependencies.

gpu_create_image_from_atlas_page :: proc(
	gpu_engine: rawptr,
	pixels: [^]u8,
	width, height: i32,
	allocator := context.allocator,
) -> (
	gpu_image: rawptr,
	ok: bool,
) {
	if pixels == nil || width <= 0 || height <= 0 {
		log.warnf(
			"gpu_create_image_from_atlas_page: invalid input (width=%d, height=%d)",
			width,
			height,
		)
		return nil, false
	}
	// This is a placeholder that will be called from the Vulkan backend.
	// The actual GPU image creation happens in scene.odin via create_image_from_data.
	// We return the pixels pointer which will be consumed by the backend.
	return cast(rawptr)pixels, true
}
