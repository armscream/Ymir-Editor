package editor

import am "/../Engine/asset_manager"
import mo "/../Engine/Libs/meshoptimizer"
import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import "core:math"
 
Mesh_Cook_Settings :: struct {
	lod_count:                  u32,
	lod_trigger_distance:       f32,  // Distance threshold for LOD switches
	max_meshlet_vertices:       u32,
	max_meshlet_triangles:      u32,
	generate_collision_mesh:    bool,
	generate_meshlets:          bool,
	optimize_overdraw:          bool,
	use_strip_cache:            bool,  // Use FIFO/Strip cache instead of LRU for optimization
}

Mesh_Cook_Input :: struct {
	name:           string,
	positions:      [dynamic][3]f32,
	normals:        [dynamic][3]f32,
	uvs:            [dynamic][2]f32,
	indices:        [dynamic]u32,
	material_slots: [dynamic]am.Cooked_Mesh_Material_Slot,
}

Cooked_Vertex_F32 :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
}

mesh_cook_positions_flatten :: proc(positions: [] [3]f32) -> [dynamic]f32 {
	flat := make([dynamic]f32, len(positions) * 3)
	for i := 0; i < len(positions); i += 1 {
		p := positions[i]
		flat[i * 3 + 0] = p.x
		flat[i * 3 + 1] = p.y
		flat[i * 3 + 2] = p.z
	}
	return flat
}

mesh_cook_compute_bounds :: proc(positions: [] [3]f32) -> am.Cooked_Mesh_Bounds {
	if len(positions) == 0 {
		return {}
	}

	min_p := positions[0]
	max_p := positions[0]
	for p in positions[1:] {
		min_p.x = min(min_p.x, p.x)
		min_p.y = min(min_p.y, p.y)
		min_p.z = min(min_p.z, p.z)
		max_p.x = max(max_p.x, p.x)
		max_p.y = max(max_p.y, p.y)
		max_p.z = max(max_p.z, p.z)
	}

	center := (min_p + max_p) * 0.5
	radius_sq: f32 = 0
	for p in positions {
		dx := p.x - center.x
		dy := p.y - center.y
		dz := p.z - center.z
		d2 := dx * dx + dy * dy + dz * dz
		radius_sq = max(radius_sq, d2)
	}

	return am.Cooked_Mesh_Bounds{
		aabb_min       = min_p,
		aabb_max       = max_p,
		sphere_center  = center,
		sphere_radius  = math.sqrt(radius_sq),
	}
}

mesh_cook_add_chunk :: proc(
	cooked: ^am.Cooked_Mesh_File,
	kind: am.Cooked_Mesh_Chunk_Kind,
	size_bytes: u64,
) {
	append(&cooked.chunks, am.Cooked_Mesh_Chunk_Header{kind = kind, size = size_bytes, offset = 0})
}

// Pipeline entrypoint for converting external meshes into the cooked runtime format.
// Applies comprehensive meshoptimizer passes in fixed order:
// 1. REQUIRED: Vertex deduplication (removes duplicate verts)
// 2. REQUIRED: Cache optimization (LRU or Strip/FIFO based on settings.use_strip_cache)
// 3. OPTIONAL: Overdraw optimization (if settings.optimize_overdraw)
// 4. REQUIRED: LOD generation (always generates LODs based on lod_count)
// 5. OPTIONAL: Meshlet generation (if settings.generate_meshlets)
// 6. REQUIRED: Vertex fetch optimization (always reorders for memory access)
// 7. REQUIRED: Vertex quantization (always compresses to f16 + u8)
// 8. OPTIONAL: Collision mesh (if settings.generate_collision_mesh)
mesh_cook_to_runtime_format :: proc(
	input: Mesh_Cook_Input,
	settings: Mesh_Cook_Settings,
) -> (
	cooked: am.Cooked_Mesh_File,
	ok: bool,
) {
	if len(input.positions) == 0 || len(input.indices) == 0 {
		log.error("mesh_cook_to_runtime_format: empty mesh input")
		return {}, false
	}
	if (len(input.indices) % 3) != 0 {
		log.error("mesh_cook_to_runtime_format: indices must be triangle list")
		return {}, false
	}

	am.cooked_mesh_file_init_header(&cooked)

	// STEP 1: REQUIRED - Vertex Deduplication
	// Remove duplicate vertices and compact the buffer.
	// Use full vertex attributes so UV/normal seams are preserved.
	dedup_vertices := make([dynamic]Cooked_Vertex_F32, len(input.positions))
	defer delete(dedup_vertices)
	for i := 0; i < len(dedup_vertices); i += 1 {
		normal := [3]f32{0, 1, 0}
		if i < len(input.normals) {
			normal = input.normals[i]
		}
		uv := [2]f32{0, 0}
		if i < len(input.uvs) {
			uv = input.uvs[i]
		}
		dedup_vertices[i] = Cooked_Vertex_F32{
			position = input.positions[i],
			normal   = normal,
			uv       = uv,
		}
	}

	remap, unique_count, remap_ok := optimize_mesh_vertex_remap(
		input.indices,
		raw_data(dedup_vertices),
		u32(len(dedup_vertices)),
		u32(size_of(Cooked_Vertex_F32)),
	)
	defer delete(remap)
	
	if !remap_ok {
		log.error("mesh_cook_to_runtime_format: vertex deduplication failed")
		return {}, false
	}

	// Build remapped indices and compact vertex attributes
	working_indices := make([dynamic]u32, len(input.indices))
	defer delete(working_indices)
	for i := 0; i < len(input.indices); i += 1 {
		working_indices[i] = remap[input.indices[i]]
	}

	working_positions := make([dynamic][3]f32, unique_count)
	working_normals := make([dynamic][3]f32, unique_count)
	working_uvs := make([dynamic][2]f32, unique_count)
	defer {
		delete(working_positions)
		delete(working_normals)
		delete(working_uvs)
	}

	for old_idx := u32(0); old_idx < u32(len(dedup_vertices)); old_idx += 1 {
		new_idx := remap[old_idx]
		if new_idx < unique_count {
			v := dedup_vertices[old_idx]
			working_positions[new_idx] = v.position
			working_normals[new_idx] = v.normal
			working_uvs[new_idx] = v.uv
		}
	}

	log.infof("mesh_cook_to_runtime_format: deduplication %d -> %d vertices", 
		len(input.positions), unique_count)

	// STEP 2: REQUIRED - Vertex Cache Optimization
	// Choose between LRU (default) or Strip/FIFO based on settings
	cache_optimized := make([dynamic]u32, len(working_indices))
	defer delete(cache_optimized)
	
	if settings.use_strip_cache {
		mo.optimizeVertexCacheStrip(
			raw_data(cache_optimized[:]),
			raw_data(working_indices[:]),
			c.size_t(len(working_indices)),
			c.size_t(unique_count),
		)
		log.infof("mesh_cook_to_runtime_format: applied Strip cache optimization")
	} else {
		       mo.optimizeVertexCache(
			       raw_data(cache_optimized[:]),
			       raw_data(working_indices[:]),
			       c.size_t(len(working_indices)),
			       c.size_t(unique_count),
		)
		log.infof("mesh_cook_to_runtime_format: applied LRU cache optimization")
	}

	base_indices := cache_optimized

	// STEP 3: OPTIONAL - Overdraw Optimization
	// Reduce pixel overdraw by reordering triangles
	final_indices := base_indices
	final_indices_owned := false
	if settings.optimize_overdraw {
		overdraw_opt, overdraw_ok := optimize_mesh_overdraw(
			Mesh_Optimize_Input{
				name         = input.name,
				indices      = base_indices,
				vertices     = working_positions,
				target_ratio = 1.0,
				lock_borders = false,
			},
		)
		if overdraw_ok && len(overdraw_opt) == len(base_indices) {
			final_indices = overdraw_opt
			final_indices_owned = true
			log.infof("mesh_cook_to_runtime_format: applied overdraw optimization")
		} else if len(overdraw_opt) > 0 {
			delete(overdraw_opt)
		}
	}
	defer if final_indices_owned {
		delete(final_indices)
	}

	// Accumulate all LOD indices for binary storage
	all_lod_indices := make([dynamic]u32, 0)
	append(&all_lod_indices, ..final_indices[:])
	defer delete(all_lod_indices)

	// STEP 4: REQUIRED - LOD Generation
	// Generate LODs based on lod_count; always enabled
	// Add LOD0 metadata
	append(
		&cooked.lods,
		am.Cooked_Mesh_Lod{
			lod_index    = 0,
			screen_error = 0,
			start_index  = 0,
			index_count  = u32(len(final_indices)),
		},
	)

	// Generate remaining LODs by progressive simplification
	if settings.lod_count > 1 {
		// Compute target ratios dynamically based on LOD count
		// More LODs = smaller ratio steps
		ratio_step: f32 = 1.0 / f32(settings.lod_count)
		ratio_acc := 1.0 - ratio_step
		previous_index_count := len(final_indices)
		previous_screen_error: f32 = 0

		for lod_i := u32(1); lod_i < settings.lod_count; lod_i += 1 {
			target_ratio := ratio_acc
			ratio_acc -= ratio_step
			if target_ratio <= 0 {
				break
			}

			simplified, simplification_error, simplify_ok := optimize_mesh_simplify(
				Mesh_Optimize_Input{
					name         = input.name,
					indices      = base_indices,
					vertices     = working_positions,
					target_ratio = target_ratio,
					lock_borders = false,
				},
			)
			if !simplify_ok || len(simplified) < 3 {
				delete(simplified)
				break
			}

			if len(simplified) >= previous_index_count {
				delete(simplified)
				continue
			}

			screen_error := simplification_error
			if screen_error <= 0 {
				reduction := f32(len(final_indices)) / max(f32(len(simplified)), 1.0)
				screen_error = max(reduction - 1.0, 0.0001)
			}
			if screen_error <= previous_screen_error {
				screen_error = previous_screen_error + 0.0001
			}

			lod_start := u32(len(all_lod_indices))
			append(&all_lod_indices, ..simplified[:])
			append(
				&cooked.lods,
				am.Cooked_Mesh_Lod{
					lod_index    = lod_i,
					screen_error = screen_error,
					start_index  = lod_start,
					index_count  = u32(len(simplified)),
				},
			)

			previous_screen_error = screen_error
			previous_index_count = len(simplified)
			delete(simplified)
		}

		log.infof("mesh_cook_to_runtime_format: generated %d LODs with stored simplification errors", len(cooked.lods))
	}

	// Handle material slots
	if len(input.material_slots) > 0 {
		for slot in input.material_slots {
			append(&cooked.material_slots, slot)
		}
	} else {
		append(
			&cooked.material_slots,
			am.Cooked_Mesh_Material_Slot{
				slot_name    = "default",
				start_index  = 0,
				index_count  = u32(len(final_indices)),
			},
		)
	}

	// STEP 5: OPTIONAL - Meshlet Generation
	if settings.generate_meshlets {
		max_vertices := max(settings.max_meshlet_vertices, 64)
		max_triangles := max(settings.max_meshlet_triangles, 84)
        // 64V and 84T is best for NVIDIA but suboptimal for AMD

		// Flatten working positions for meshopt
		working_positions_flat := make([dynamic]f32, len(working_positions) * 3)
		for i := 0; i < len(working_positions); i += 1 {
			p := working_positions[i]
			working_positions_flat[i * 3 + 0] = p.x
			working_positions_flat[i * 3 + 1] = p.y
			working_positions_flat[i * 3 + 2] = p.z
		}
		defer delete(working_positions_flat)

		for lod_i := 0; lod_i < len(cooked.lods); lod_i += 1 {
			lod := &cooked.lods[lod_i]
			if lod.index_count < 3 {
				continue
			}

			start := int(lod.start_index)
			count := int(lod.index_count)
			lod_indices := all_lod_indices[start : start + count]

			meshlet_bound := int(mo.buildMeshletsBound(
				c.size_t(len(lod_indices)),
				c.size_t(max_vertices),
				c.size_t(max_triangles),
			))
			if meshlet_bound <= 0 {
				continue
			}

			tmp_meshlets := make([]mo.Meshlet, meshlet_bound)
			tmp_vertices := make([]u32, meshlet_bound * int(max_vertices))
			tmp_triangles := make([]u8, meshlet_bound * int(max_triangles) * 3)

			built := int(mo.buildMeshlets(
				raw_data(tmp_meshlets),
				raw_data(tmp_vertices),
				raw_data(tmp_triangles),
				raw_data(lod_indices),
				c.size_t(len(lod_indices)),
				raw_data(working_positions_flat),
				c.size_t(len(working_positions)),
				c.size_t(size_of([3]f32)),
				c.size_t(max_vertices),
				c.size_t(max_triangles),
				0.0,
			))
			if built <= 0 {
				delete(tmp_triangles)
				delete(tmp_vertices)
				delete(tmp_meshlets)
				continue
			}

			lod.meshlet_start = u32(len(cooked.meshlets))
			lod.meshlet_count = u32(built)

			for m_i := 0; m_i < built; m_i += 1 {
				m := tmp_meshlets[m_i]
				append(
					&cooked.meshlets,
					am.Cooked_Mesh_Meshlet{
						vertex_offset   = u32(m.vertex_offset),
						triangle_offset = u32(m.triangle_offset),
						vertex_count    = u32(m.vertex_count),
						triangle_count  = u32(m.triangle_count),
					},
				)

				b := mo.computeMeshletBounds(
					raw_data(tmp_vertices[m.vertex_offset:]),
					raw_data(tmp_triangles[m.triangle_offset:]),
					c.size_t(m.triangle_count),
					raw_data(working_positions_flat),
					c.size_t(len(working_positions)),
					c.size_t(size_of([3]f32)),
				)

				append(
					&cooked.meshlet_bounds,
					am.Cooked_Mesh_Meshlet_Bounds{
						center         = b.center,
						radius         = b.radius,
						cone_apex      = b.cone_apex,
						cone_axis      = b.cone_axis,
						cone_cutoff    = b.cone_cutoff,
						cone_axis_s8   = {
							i8(b.cone_axis_s8[0]),
							i8(b.cone_axis_s8[1]),
							i8(b.cone_axis_s8[2]),
						},
						cone_cutoff_s8 = i8(b.cone_cutoff_s8),
					},
				)
			}

			delete(tmp_triangles)
			delete(tmp_vertices)
			delete(tmp_meshlets)
		}
		log.infof("mesh_cook_to_runtime_format: generated %d meshlets", len(cooked.meshlets))
	}

	// STEP 6: REQUIRED - Vertex Fetch Optimization
	// Reorder vertices for optimal memory access patterns
	fetch_count, fetch_remap, fetch_ok := optimize_mesh_vertex_fetch(
		all_lod_indices,
		raw_data(working_positions),
		u32(len(working_positions)),
		u32(size_of([3]f32)),
	)
	if fetch_ok && fetch_count > 0 {
		defer delete(fetch_remap)

		// Remap all vertex streams using old->new remap produced by meshoptimizer.
		old_positions := make([dynamic][3]f32, len(working_positions))
		old_normals := make([dynamic][3]f32, len(working_normals))
		old_uvs := make([dynamic][2]f32, len(working_uvs))
		copy(old_positions[:], working_positions[:])
		copy(old_normals[:], working_normals[:])
		copy(old_uvs[:], working_uvs[:])

		for old_i := 0; old_i < len(old_positions); old_i += 1 {
			new_i := int(fetch_remap[old_i])
			if new_i >= 0 && new_i < int(fetch_count) {
				working_positions[new_i] = old_positions[old_i]
				working_normals[new_i] = old_normals[old_i]
				working_uvs[new_i] = old_uvs[old_i]
			}
		}

		delete(old_positions)
		delete(old_normals)
		delete(old_uvs)

		resize(&working_positions, int(fetch_count))
		resize(&working_normals, int(fetch_count))
		resize(&working_uvs, int(fetch_count))

		remapped_indices := 0
		for lod_i := 0; lod_i < len(cooked.lods); lod_i += 1 {
			lod := cooked.lods[lod_i]
			start := int(lod.start_index)
			count := int(lod.index_count)
			end := start + count

			if start < 0 || count < 0 || end > len(all_lod_indices) {
				log.errorf(
					"mesh_cook_to_runtime_format: invalid LOD range for remap (lod=%d, start=%d, count=%d, total=%d)",
					lod_i,
					start,
					count,
					len(all_lod_indices),
				)
				return {}, false
			}

			for i := start; i < end; i += 1 {
				old_idx := all_lod_indices[i]
				if int(old_idx) >= len(fetch_remap) {
					log.errorf(
						"mesh_cook_to_runtime_format: remap out of range (lod=%d, index_pos=%d, old_idx=%d, remap_len=%d)",
						lod_i,
						i,
						old_idx,
						len(fetch_remap),
					)
					return {}, false
				}
				all_lod_indices[i] = fetch_remap[old_idx]
				remapped_indices += 1
			}
		}

		log.infof("mesh_cook_to_runtime_format: applied vertex fetch remap (%d -> %d vertices)",
			len(old_positions), fetch_count)
		log.infof("mesh_cook_to_runtime_format: remapped %d indices across %d LODs", remapped_indices, len(cooked.lods))
	}

	if len(working_positions) > 4294967295 {
		log.errorf(
			"mesh_cook_to_runtime_format: U32 index mode exceeded vertex limit (%d > 4294967295)",
			len(working_positions),
		)
		return {}, false
	}

	// STEP 7: REQUIRED - Vertex Quantization
	quantized_vertices := make([]am.Cooked_Vertex_Quantized, len(working_positions))
	defer delete(quantized_vertices)
	for i := 0; i < len(quantized_vertices); i += 1 {
		normal := [3]f32{0, 1, 0}
		if i < len(working_normals) {
			normal = working_normals[i]
		}
		uv := [2]f32{0, 0}
		if i < len(working_uvs) {
			uv = working_uvs[i]
		}
		quantized_vertices[i].position = am.quantize_position(working_positions[i])
		quantized_vertices[i].uv_x = am.quantize_uv(uv.x)
		quantized_vertices[i].normal = am.oct_encode_normal(normal)
		quantized_vertices[i].uv_y = am.quantize_uv(uv.y)
		quantized_vertices[i].color = {255, 255, 255, 255}
	}
	cooked.vertex_blob = make([]u8, len(quantized_vertices) * size_of(am.Cooked_Vertex_Quantized))
	mem.copy(raw_data(cooked.vertex_blob), raw_data(quantized_vertices), len(cooked.vertex_blob))
	log.infof("mesh_cook_to_runtime_format: quantized %d vertices with oct-encoded normals", len(working_positions))

	indices_u32 := make([]u32, len(all_lod_indices))
	defer delete(indices_u32)
	for i := 0; i < len(all_lod_indices); i += 1 {
		idx := all_lod_indices[i]
		indices_u32[i] = idx
	}

	cooked.index_blob = make([]u8, len(indices_u32) * size_of(u32))
	mem.copy(raw_data(cooked.index_blob), raw_data(indices_u32), len(cooked.index_blob))

	cooked.bounds = mesh_cook_compute_bounds(working_positions[:])

	// STEP 8: OPTIONAL - Collision Mesh Generation
	if settings.generate_collision_mesh {
		cooked.collision.vertex_count = u32(len(working_positions))
		cooked.collision.index_count = u32(len(final_indices))
		cooked.collision.bounds = cooked.bounds
		for p in working_positions {
			append(&cooked.collision.vertices, p)
		}
		for idx in final_indices {
			append(&cooked.collision.indices, idx)
		}
		log.infof("mesh_cook_to_runtime_format: generated collision mesh")
	}

	cooked.header.vertex_count = u32(len(working_positions))
	cooked.header.index_count = u32(len(all_lod_indices))
	cooked.header.material_count = u32(len(cooked.material_slots))
	cooked.header.lod_count = u32(len(cooked.lods))
	cooked.header.meshlet_count = u32(len(cooked.meshlets))

	mesh_cook_add_chunk(&cooked, .Vertex_Buffer, u64(len(cooked.vertex_blob)))
	mesh_cook_add_chunk(&cooked, .Index_Buffer, u64(len(cooked.index_blob)))
	mesh_cook_add_chunk(
		&cooked,
		.Material_Slots,
		u64(len(cooked.material_slots) * size_of(am.Cooked_Mesh_Material_Slot)),
	)
	mesh_cook_add_chunk(&cooked, .Lods, u64(len(cooked.lods) * size_of(am.Cooked_Mesh_Lod)))
	mesh_cook_add_chunk(
		&cooked,
		.Meshlets,
		u64(len(cooked.meshlets) * size_of(am.Cooked_Mesh_Meshlet)),
	)
	mesh_cook_add_chunk(
		&cooked,
		.Meshlet_Bounds,
		u64(len(cooked.meshlet_bounds) * size_of(am.Cooked_Mesh_Meshlet_Bounds)),
	)
	mesh_cook_add_chunk(&cooked, .Bounds, u64(size_of(am.Cooked_Mesh_Bounds)))
	if settings.generate_collision_mesh {
		collision_size :=
			u64(len(cooked.collision.vertices) * size_of([3]f32)) +
			u64(len(cooked.collision.indices) * size_of(u32))
		mesh_cook_add_chunk(&cooked, .Collision, collision_size)
	}

	cooked.header.chunk_count = u32(len(cooked.chunks))
	return cooked, true
}

// Save cooked mesh to binary file (.ymesh format)
mesh_cook_save :: proc(
	output_path: string,
	cooked: ^am.Cooked_Mesh_File,
) -> bool {
	if cooked == nil {
		log.error("mesh_cook_save: cooked is nil")
		return false
	}
	if len(output_path) == 0 {
		log.error("mesh_cook_save: output_path is empty")
		return false
	}

	// Ensure directory exists
	dir := output_path
	for i := len(output_path) - 1; i >= 0; i -= 1 {
		if output_path[i] == '/' || output_path[i] == '\\' {
			dir = output_path[:i]
			break
		}
	}
	if len(dir) > 0 && !os.exists(dir) {
		if mkdir_err := os.make_directory(dir); mkdir_err != nil {
			log.errorf("mesh_cook_save: failed to create directory '%s': %v", dir, mkdir_err)
			return false
		}
	}

	return am.cooked_mesh_write_to_file(output_path, cooked)
}
