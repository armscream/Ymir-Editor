package Asset_Converter

import mo "../../Engine/Libs/meshoptimizer"
import am "../../Engine/asset_manager"

import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

Raw_Surface_Range :: struct {
	material_name: string,
	start_index:   u32,
	index_count:   u32,
}

Material_Sidecar_File :: struct {
	mesh_path:      string,
	mesh_name:      string,
	materials_file: string,
	slot_names:     []string,
	material_files: []string,
}

Raw_Mesh :: struct {
	positions:           [dynamic][3]f32,
	normals:             [dynamic][3]f32,
	uvs:                 [dynamic][2]f32,
	indices:             [dynamic]u32,
	surface_ranges:      [dynamic]Raw_Surface_Range,
	mtllib:              string,
	used_material_names: [dynamic]string,
	name:                string,
}

Obj_Vertex_Key :: struct {
	v:  i32,
	vt: i32,
	vn: i32,
}

Convert_Options :: struct {
	lod_count:             u32,
	max_meshlet_vertices:  u32,
	max_meshlet_triangles: u32,
	generate_meshlets:     bool,
	generate_collision:    bool,
	optimize_overdraw:     bool,
	use_strip_cache:       bool,
}

default_convert_options :: proc() -> Convert_Options {
	return Convert_Options {
		lod_count = 1,
		generate_meshlets = false,
		generate_collision = false,
		optimize_overdraw = false,
		use_strip_cache = false,
		max_meshlet_vertices = 64,
		max_meshlet_triangles = 84,
	}
}


// Forward declarations for functions used before definition

// --- Helper function definitions moved above first use ---

get_file_extension :: proc(file_path: string) -> string {
	for i := len(file_path) - 1; i >= 0; i -= 1 {
		if file_path[i] == '.' {
			return file_path[i:]
		}
		if file_path[i] == '/' || file_path[i] == '\\' {
			break
		}
	}
	return ""
}

get_file_name_without_ext :: proc(file_path: string) -> string {
	last_slash := -1
	for i := len(file_path) - 1; i >= 0; i -= 1 {
		if file_path[i] == '/' || file_path[i] == '\\' {
			last_slash = i
			break
		}
	}
	start := last_slash + 1
	dot_pos := -1
	for i := len(file_path) - 1; i >= start; i -= 1 {
		if file_path[i] == '.' {
			dot_pos = i
			break
		}
	}
	if dot_pos == -1 {
		return file_path[start:]
	}
	return file_path[start:dot_pos]
}

strip_wrapping_quotes :: proc(value: string) -> string {
	v := strings.trim_space(value)
	if len(v) >= 2 {
		if (v[0] == '"' && v[len(v) - 1] == '"') || (v[0] == '\'' && v[len(v) - 1] == '\'') {
			return strings.trim_space(v[1:len(v) - 1])
		}
	}
	return v
}

// Public wrapper for editor use
public_convert_mesh :: proc(
	input_path: string,
	output_path: string,
	opts: Convert_Options,
) -> bool {
	return convert_mesh(input_path, output_path, opts)
}


parse_convert_options :: proc(args: []string) -> (opts: Convert_Options, ok: bool) {
	opts = default_convert_options()

	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--lods":
			if i + 1 >= len(args) {
				log.error("Missing value for --lods")
				return opts, false
			}
			v, parsed := parse_u32_option(args[i + 1])
			if !parsed || v == 0 {
				log.errorf("Invalid --lods value: %s", args[i + 1])
				return opts, false
			}
			opts.lod_count = v
			i += 1
		case "--meshlets":
			opts.generate_meshlets = true
		case "--collision":
			opts.generate_collision = true
		case "--overdraw":
			opts.optimize_overdraw = true
		case "--strip-cache":
			opts.use_strip_cache = true
		case "--max-meshlet-vertices":
			if i + 1 >= len(args) {
				log.error("Missing value for --max-meshlet-vertices")
				return opts, false
			}
			v, parsed := parse_u32_option(args[i + 1])
			if !parsed || v == 0 {
				log.errorf("Invalid --max-meshlet-vertices value: %s", args[i + 1])
				return opts, false
			}
			opts.max_meshlet_vertices = v
			i += 1
		case "--max-meshlet-triangles":
			if i + 1 >= len(args) {
				log.error("Missing value for --max-meshlet-triangles")
				return opts, false
			}
			v, parsed := parse_u32_option(args[i + 1])
			if !parsed || v == 0 {
				log.errorf("Invalid --max-meshlet-triangles value: %s", args[i + 1])
				return opts, false
			}
			opts.max_meshlet_triangles = v
			i += 1
		case:
			log.errorf("Unknown option: %s", a)
			return opts, false
		}
	}

	return opts, true
}

parse_u32_option :: proc(value: string) -> (u32, bool) {
	v64, ok := strconv.parse_u64(value)
	if !ok || v64 > u64(4294967295) {
		return 0, false
	}
	return u32(v64), true
}

convert_mesh :: proc(input_path: string, output_path: string, opts: Convert_Options) -> bool {
	log.infof("Converting mesh: %s", input_path)
	raw: Raw_Mesh
	ok: bool
	raw, ok = load_mesh_file(input_path)
	if !ok {
		log.errorf("Failed to load mesh file: %s", input_path)
		return false
	}
	mtl_dir := os.dir(input_path)
	material_assets: []MTL_Material_Raw
	mtl_full_path := ""
	if len(raw.mtllib) > 0 {
		candidate, join_err := os.join_path(
			[]string{os.dir(input_path), raw.mtllib},
			context.temp_allocator,
		)
		if join_err != nil {
			log.errorf("Failed to join path for mtllib: %s", raw.mtllib)
		} else if os.exists(candidate) {
			mtl_full_path = candidate
		} else if strings.last_index(raw.mtllib, ".") < 0 {
			candidate_with_ext := strings.concatenate(
				[]string{candidate, ".mtl"},
				context.temp_allocator,
			)
			if os.exists(candidate_with_ext) {
				mtl_full_path = candidate_with_ext
			}
		}
	}
	if len(mtl_full_path) == 0 {
		obj_stem := get_file_name_without_ext(input_path)
		fallback, join_err := os.join_path(
			[]string {
				os.dir(input_path),
				strings.concatenate([]string{obj_stem, ".mtl"}, context.temp_allocator),
			},
			context.temp_allocator,
		)
		if join_err != nil {
			log.errorf("Failed to join fallback path for mtllib: %s.mtl", obj_stem)
		} else if os.exists(fallback) {
			mtl_full_path = fallback
		}
	}

	if len(mtl_full_path) > 0 {
		material_assets = parse_mtl_file(mtl_full_path)
		mtl_dir = os.dir(mtl_full_path)
		log.infof("Parsed %d materials from %s", len(material_assets), mtl_full_path)
		// No cleanup needed for material_assets (no heap strings)
		if len(material_assets) == 0 {
			obj_stem := get_file_name_without_ext(input_path)
			fallback, join_err := os.join_path(
				[]string {
					os.dir(input_path),
					strings.concatenate([]string{obj_stem, ".mtl"}, context.temp_allocator),
				},
				context.temp_allocator,
			)
			if join_err != nil {
				log.errorf("Failed to join fallback path for mtllib: %s.mtl", obj_stem)
			} else if os.exists(fallback) && fallback != mtl_full_path {
				fallback_materials := parse_mtl_file(fallback)
				// No cleanup needed for fallback_materials (no heap strings)
				if len(fallback_materials) > 0 {
					material_assets = fallback_materials
					mtl_dir = os.dir(fallback)
					mtl_full_path = fallback
					log.infof(
						"Retried mtl fallback and parsed %d materials from %s",
						len(material_assets),
						fallback,
					)
				} else {
					log.warnf("Fallback mtl file '%s' exists but contains no materials", fallback)
				}
			}
		}
	} else if len(raw.mtllib) > 0 {
		log.warnf("Could not resolve mtllib '%s' for OBJ '%s'", raw.mtllib, input_path)
	}

	if len(material_assets) > 0 {
		// Matching logic
		for i := 0; i < len(raw.used_material_names); i += 1 {
			used_name := raw.used_material_names[i]
			used_name_norm := strings.to_lower(
				strip_wrapping_quotes(strings.trim_space(used_name)),
				context.temp_allocator,
			)
			found := false
			for j := 0; j < len(material_assets); j += 1 {
				mat := material_assets[j]
				mat_name_norm := strings.to_lower(
					strip_wrapping_quotes(strings.trim_space(mat.name)),
					context.temp_allocator,
				)
				if used_name_norm == mat_name_norm {
					found = true
					break
				}
			}
			if !found {
				log.warnf(
					"OBJ references material '%s' (normalized: '%s') not present in '%s' (checked normalized names)",
					used_name,
					used_name_norm,
					mtl_full_path,
				)
			}
		}
	}

	cooked: am.Cooked_Mesh_File = build_cooked_mesh(raw, opts)
	if cooked.material_slots == nil {
		log.errorf("Cooked mesh has nil material_slots for '%s'", input_path)
		return false
	}

	log.infof(
		"Writing cooked mesh: verts=%d indices=%d materials=%d lods=%d meshlets=%d chunks=%d -> %s",
		cooked.header.vertex_count,
		cooked.header.index_count,
		cooked.header.material_count,
		cooked.header.lod_count,
		cooked.header.meshlet_count,
		cooked.header.chunk_count,
		output_path,
	)
	write_ok := am.cooked_mesh_write_to_file(output_path, &cooked)

	if !write_ok {
		log.errorf("Failed to write cooked mesh to '%s'", output_path)
		return false
	}
	log.infof("Cooked mesh written: %s", output_path)

	material_files, slot_names := write_material_asset_sidecar(
		output_path,
		raw.name,
		cooked.material_slots[:],
		material_assets[:],
		mtl_dir,
	)
	cleanup_converter(&raw, &cooked, &material_assets, material_files, slot_names)
	return true
}

build_cooked_mesh :: proc(raw: Raw_Mesh, opts: Convert_Options) -> am.Cooked_Mesh_File {
	mesh: am.Cooked_Mesh_File
	am.cooked_mesh_file_init_header(&mesh)

	vertex_count := len(raw.positions)
	raw_bounds := compute_bounds(raw.positions[:])
	center := raw_bounds.sphere_center
	normalize_scale: f32 = 1.0
	if raw_bounds.sphere_radius > 0 {
		normalize_scale = 1.0 / raw_bounds.sphere_radius
	}

	centered_positions := make([dynamic][3]f32, vertex_count)
	defer delete(centered_positions)

	for i := 0; i < vertex_count; i += 1 {
		p := raw.positions[i]
		centered_p := [3]f32 {
			(p.x - center.x) * normalize_scale,
			(p.y - center.y) * normalize_scale,
			(p.z - center.z) * normalize_scale,
		}
		centered_positions[i] = centered_p
	}

	base_indices := make([dynamic]u32, len(raw.indices))
	copy(base_indices[:], raw.indices[:])
	defer delete(base_indices)

	if opts.use_strip_cache {
		optimized := make([dynamic]u32, len(base_indices))
		defer delete(optimized)
		mo.optimizeVertexCacheStrip(
			raw_data(optimized[:]),
			raw_data(base_indices[:]),
			c.size_t(len(base_indices)),
			c.size_t(len(centered_positions)),
		)
		copy(base_indices[:], optimized[:])
	}

	if opts.optimize_overdraw {
		overdraw_opt, overdraw_ok := optimize_overdraw_indices(base_indices, centered_positions)
		if overdraw_ok && len(overdraw_opt) == len(base_indices) {
			copy(base_indices[:], overdraw_opt[:])
		}
		if len(overdraw_opt) > 0 {
			delete(overdraw_opt)
		}
	}

	all_lod_indices := make([dynamic]u32, 0)
	defer delete(all_lod_indices)
	append(&all_lod_indices, ..base_indices[:])

	slot_names := make([dynamic]string, 0)
	defer delete(slot_names)
	material_ranges_lod0 := make([dynamic]am.Cooked_Mesh_Lod_Material, 0)
	defer delete(material_ranges_lod0)

	for surface_i := 0; surface_i < len(raw.surface_ranges); surface_i += 1 {
		surface := raw.surface_ranges[surface_i]
		if surface.index_count == 0 {
			log.warnf("Skipping surface %d (material='%s') due to zero indices", surface_i, surface.material_name)
			continue
		}
		slot_index := -1
		for i := 0; i < len(slot_names); i += 1 {
			if slot_names[i] == surface.material_name {
				slot_index = i
				break
			}
		}
		if slot_index < 0 {
			slot_index = len(slot_names)
			append(&slot_names, surface.material_name)
		}
		append(
			&material_ranges_lod0,
			am.Cooked_Mesh_Lod_Material {
				material_slot_index = u32(slot_index),
				start_index = surface.start_index,
				index_count = surface.index_count,
			},
		)
	}

	if len(slot_names) == 0 {
		log.warnf("No valid material slots found, creating fallback 'default' slot.")
		append(&slot_names, "default")
		append(
			&material_ranges_lod0,
			am.Cooked_Mesh_Lod_Material {
				material_slot_index = 0,
				start_index = 0,
				index_count = u32(len(base_indices)),
			},
		)
	}

	mesh.material_slots = make([dynamic]am.Cooked_Mesh_Material_Slot, len(slot_names))
	for i := 0; i < len(slot_names); i += 1 {
		mesh.material_slots[i] = am.Cooked_Mesh_Material_Slot {
			slot_name   = strings.clone(slot_names[i]),
			start_index = 0,
			index_count = 0,
		}
	}
	for range_i := 0; range_i < len(material_ranges_lod0); range_i += 1 {
		range_entry := material_ranges_lod0[range_i]
		slot_idx := int(range_entry.material_slot_index)
		if slot_idx < 0 || slot_idx >= len(mesh.material_slots) {
			log.errorf("Invalid slot_idx %d for range %d (material_slot_index=%d)", slot_idx, range_i, range_entry.material_slot_index)
			continue
		}
		slot := &mesh.material_slots[slot_idx]
		if slot.index_count == 0 || range_entry.start_index < slot.start_index {
			slot.start_index = range_entry.start_index
		}
		slot.index_count += range_entry.index_count
	}

	append(
		&mesh.lods,
		am.Cooked_Mesh_Lod {
			lod_index = 0,
			screen_error = 0,
			start_index = 0,
			index_count = u32(len(base_indices)),
			material_ranges = make(
				[dynamic]am.Cooked_Mesh_Lod_Material,
				len(material_ranges_lod0),
			),
			meshlet_start = 0,
			meshlet_count = 0,
		},
	)
	copy(mesh.lods[0].material_ranges[:], material_ranges_lod0[:])

	if opts.lod_count > 1 {
		ratio_step: f32 = 1.0 / f32(opts.lod_count)
		ratio_acc := 1.0 - ratio_step
		previous_index_count := len(base_indices)
		previous_screen_error: f32 = 0
		for lod_i := u32(1); lod_i < opts.lod_count; lod_i += 1 {
			target_ratio := ratio_acc
			ratio_acc -= ratio_step
			if target_ratio <= 0 {
				break
			}

			simplified, simplify_error, simplify_ok := simplify_indices(
				base_indices,
				centered_positions,
				target_ratio,
			)
			if !simplify_ok || len(simplified) < 3 {
				if len(simplified) > 0 {
					delete(simplified)
				}
				break
			}

			if len(simplified) >= previous_index_count {
				delete(simplified)
				continue
			}

			screen_error := simplify_error
			if screen_error <= 0 {
				reduction := f32(len(base_indices)) / math.max(f32(len(simplified)), 1.0)
				screen_error = math.max(reduction - 1.0, 0.0001)
			}
			if screen_error <= previous_screen_error {
				screen_error = previous_screen_error + 0.0001
			}

			lod_start := u32(len(all_lod_indices))
			append(&all_lod_indices, ..simplified[:])
			append(
				&mesh.lods,
				am.Cooked_Mesh_Lod {
					lod_index = lod_i,
					screen_error = screen_error,
					start_index = lod_start,
					index_count = u32(len(simplified)),
					material_ranges = make([dynamic]am.Cooked_Mesh_Lod_Material, 1),
					meshlet_start = 0,
					meshlet_count = 0,
				},
			)
			mesh.lods[len(mesh.lods) - 1].material_ranges[0] = am.Cooked_Mesh_Lod_Material {
				material_slot_index = material_ranges_lod0[0].material_slot_index,
				start_index         = 0,
				index_count         = u32(len(simplified)),
			}

			previous_screen_error = screen_error
			previous_index_count = len(simplified)
			delete(simplified)
		}
	}

	if opts.generate_meshlets {
		max_vertices := math.max(opts.max_meshlet_vertices, 16)
		max_triangles := math.max(opts.max_meshlet_triangles, 16)

		positions_flat := make([dynamic]f32, len(centered_positions) * 3)
		defer delete(positions_flat)
		for i := 0; i < len(centered_positions); i += 1 {
			p := centered_positions[i]
			positions_flat[i * 3 + 0] = p.x
			positions_flat[i * 3 + 1] = p.y
			positions_flat[i * 3 + 2] = p.z
		}

		for lod_i := 0; lod_i < len(mesh.lods); lod_i += 1 {
			lod := &mesh.lods[lod_i]
			start := int(lod.start_index)
			count := int(lod.index_count)
			if count < 3 || start < 0 || start + count > len(all_lod_indices) {
				continue
			}
			lod_indices := all_lod_indices[start:start + count]

			meshlet_bound := int(
				mo.buildMeshletsBound(
					c.size_t(len(lod_indices)),
					c.size_t(max_vertices),
					c.size_t(max_triangles),
				),
			)
			if meshlet_bound <= 0 {
				continue
			}

			tmp_meshlets := make([]mo.Meshlet, meshlet_bound)
			tmp_vertices := make([]u32, meshlet_bound * int(max_vertices))
			tmp_triangles := make([]u8, meshlet_bound * int(max_triangles) * 3)

			built := int(
				mo.buildMeshlets(
					raw_data(tmp_meshlets),
					raw_data(tmp_vertices),
					raw_data(tmp_triangles),
					raw_data(lod_indices),
					c.size_t(len(lod_indices)),
					raw_data(positions_flat),
					c.size_t(len(centered_positions)),
					c.size_t(size_of([3]f32)),
					c.size_t(max_vertices),
					c.size_t(max_triangles),
					0.0,
				),
			)
			if built <= 0 {
				delete(tmp_triangles)
				delete(tmp_vertices)
				delete(tmp_meshlets)
				continue
			}

			lod.meshlet_start = u32(len(mesh.meshlets))
			lod.meshlet_count = u32(built)

			for m_i := 0; m_i < built; m_i += 1 {
				m := tmp_meshlets[m_i]
				append(
					&mesh.meshlets,
					am.Cooked_Mesh_Meshlet {
						vertex_offset = u32(m.vertex_offset),
						triangle_offset = u32(m.triangle_offset),
						vertex_count = u32(m.vertex_count),
						triangle_count = u32(m.triangle_count),
					},
				)

				b := mo.computeMeshletBounds(
					raw_data(tmp_vertices[m.vertex_offset:]),
					raw_data(tmp_triangles[m.triangle_offset:]),
					c.size_t(m.triangle_count),
					raw_data(positions_flat),
					c.size_t(len(centered_positions)),
					c.size_t(size_of([3]f32)),
				)

				append(
					&mesh.meshlet_bounds,
					am.Cooked_Mesh_Meshlet_Bounds {
						center = b.center,
						radius = b.radius,
						cone_apex = b.cone_apex,
						cone_axis = b.cone_axis,
						cone_cutoff = b.cone_cutoff,
						cone_axis_s8 = {
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
	}

	quantized := make([dynamic]am.Cooked_Vertex_Quantized, vertex_count)
	defer delete(quantized)
	for i := 0; i < vertex_count; i += 1 {
		n := [3]f32{0, 1, 0}
		uv := [2]f32{0, 0}
		if i < len(raw.normals) {
			n = raw.normals[i]
		}
		if i < len(raw.uvs) {
			uv = raw.uvs[i]
		}

		quantized[i] = am.Cooked_Vertex_Quantized {
			position = am.quantize_position(centered_positions[i]),
			uv_x     = am.quantize_uv(uv[0]),
			uv_y     = am.quantize_uv(uv[1]),
			normal   = am.oct_encode_normal(n),
			color    = [4]u8{255, 255, 255, 255},
		}
	}

	mesh.vertex_blob = make([]u8, vertex_count * size_of(am.Cooked_Vertex_Quantized))
	mem.copy(raw_data(mesh.vertex_blob), raw_data(quantized), len(mesh.vertex_blob))

	indices_u32 := make([dynamic]u32, len(all_lod_indices))
	defer delete(indices_u32)
	for i := 0; i < len(all_lod_indices); i += 1 {
		indices_u32[i] = all_lod_indices[i]
	}
	mesh.index_blob = make([]u8, len(indices_u32) * size_of(u32))
	mem.copy(raw_data(mesh.index_blob), raw_data(indices_u32), len(mesh.index_blob))

	mesh.bounds = compute_bounds(centered_positions[:])
	if opts.generate_collision {
		mesh.collision.vertex_count = u32(len(centered_positions))
		mesh.collision.index_count = u32(len(base_indices))
		mesh.collision.bounds = mesh.bounds
		for p in centered_positions {
			append(&mesh.collision.vertices, p)
		}
		for idx in base_indices {
			append(&mesh.collision.indices, idx)
		}
	}

	mesh.header.vertex_count = u32(vertex_count)
	mesh.header.index_count = u32(len(indices_u32))
	mesh.header.material_count = u32(len(mesh.material_slots))
	mesh.header.lod_count = u32(len(mesh.lods))
	mesh.header.meshlet_count = u32(len(mesh.meshlets))

	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Vertex_Buffer,
			size = u64(len(mesh.vertex_blob)),
			offset = 0,
		},
	)
	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Index_Buffer,
			size = u64(len(mesh.index_blob)),
			offset = 0,
		},
	)
	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Material_Slots,
			size = u64(len(mesh.material_slots) * size_of(am.Cooked_Mesh_Material_Slot)),
			offset = 0,
		},
	)
	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Lods,
			size = u64(len(mesh.lods) * size_of(am.Cooked_Mesh_Lod)),
			offset = 0,
		},
	)
	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Meshlets,
			size = u64(len(mesh.meshlets) * size_of(am.Cooked_Mesh_Meshlet)),
			offset = 0,
		},
	)
	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Meshlet_Bounds,
			size = u64(len(mesh.meshlet_bounds) * size_of(am.Cooked_Mesh_Meshlet_Bounds)),
			offset = 0,
		},
	)
	append(
		&mesh.chunks,
		am.Cooked_Mesh_Chunk_Header {
			kind = .Bounds,
			size = u64(size_of(am.Cooked_Mesh_Bounds)),
			offset = 0,
		},
	)
	if opts.generate_collision {
		collision_size :=
			u64(len(mesh.collision.vertices) * size_of([3]f32)) +
			u64(len(mesh.collision.indices) * size_of(u32))
		append(
			&mesh.chunks,
			am.Cooked_Mesh_Chunk_Header{kind = .Collision, size = collision_size, offset = 0},
		)
	}
	mesh.header.chunk_count = u32(len(mesh.chunks))
	return mesh
}

load_mesh_file :: proc(file_path: string) -> (mesh: Raw_Mesh, ok: bool) {
	ext := strings.to_lower(get_file_extension(file_path), context.temp_allocator)
	switch ext {
	case ".obj":
		return load_obj_mesh(file_path)
	case ".gltf", ".glb":
		log.error("GLTF/GLB support not yet implemented")
		return {}, false
	case:
		log.errorf("Unknown file extension: %s", ext)
		return {}, false
	}
}

compute_bounds :: proc(positions: [][3]f32) -> am.Cooked_Mesh_Bounds {
	if len(positions) == 0 {
		return {}
	}

	min_p := positions[0]
	max_p := positions[0]
	for p in positions[1:] {
		min_p.x = min(min_p.x, p.x)
		min_p.y = min(min_p.y, p.y)
		min_p.z = min(min_p.z, p.z)
		max_p.x = math.max(max_p.x, p.x)
		max_p.y = math.max(max_p.y, p.y)
		max_p.z = math.max(max_p.z, p.z)
	}

	center := (min_p + max_p) * 0.5
	radius_sq: f32 = 0
	for p in positions {
		dx := p.x - center.x
		dy := p.y - center.y
		dz := p.z - center.z
		d2 := dx * dx + dy * dy + dz * dz
		radius_sq = math.max(radius_sq, d2)
	}

	return am.Cooked_Mesh_Bounds {
		aabb_min = min_p,
		aabb_max = max_p,
		sphere_center = center,
		sphere_radius = math.sqrt(radius_sq),
	}
}

optimize_overdraw_indices :: proc(
	indices: [dynamic]u32,
	positions: [dynamic][3]f32,
) -> (
	optimized: [dynamic]u32,
	ok: bool,
) {
	if len(indices) == 0 || len(positions) == 0 {
		return {}, false
	}
	optimized = make([dynamic]u32, len(indices))
	positions_flat := make([dynamic]f32, len(positions) * 3)
	defer delete(positions_flat)
	defer if !ok {
		delete(optimized)
	}
	for i := 0; i < len(positions); i += 1 {
		p := positions[i]
		positions_flat[i * 3 + 0] = p.x
		positions_flat[i * 3 + 1] = p.y
		positions_flat[i * 3 + 2] = p.z
	}
	mo.optimizeOverdraw(
		raw_data(optimized[:]),
		raw_data(indices[:]),
		c.size_t(len(indices)),
		raw_data(positions_flat[:]),
		c.size_t(len(positions)),
		size_of(f32) * 3,
		1.05,
	)
	return optimized, true
}

simplify_indices :: proc(
	indices: [dynamic]u32,
	positions: [dynamic][3]f32,
	target_ratio: f32,
) -> (
	simplified: [dynamic]u32,
	simplification_error: f32,
	ok: bool,
) {
	if len(indices) == 0 || len(positions) == 0 {
		return {}, 0, false
	}
	target_count := c.size_t(f32(len(indices)) * target_ratio)
	target_count = math.max(target_count, 3)
	simplified = make([dynamic]u32, len(indices))
	positions_flat := make([dynamic]f32, len(positions) * 3)
	defer delete(positions_flat)
	defer if !ok {
		delete(simplified)
	}
	for i := 0; i < len(positions); i += 1 {
		p := positions[i]
		positions_flat[i * 3 + 0] = p.x
		positions_flat[i * 3 + 1] = p.y
		positions_flat[i * 3 + 2] = p.z
	}
	simplification_error = 0
	out_count := mo.simplify(
		raw_data(simplified[:]),
		raw_data(indices[:]),
		c.size_t(len(indices)),
		raw_data(positions_flat[:]),
		c.size_t(len(positions)),
		size_of(f32) * 3,
		target_count,
		0.01,
		{},
		&simplification_error,
	)
	if out_count == 0 {
		return {}, 0, false
	}
	resize(&simplified, int(out_count))
	return simplified, simplification_error, true
}

load_obj_mesh :: proc(file_path: string) -> (mesh: Raw_Mesh, ok: bool) {
	data, read_err := os.read_entire_file(file_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("Failed to read file: %v", read_err)
		return {}, false
	}

	content := string(data)
	lines := strings.split(content, "\n", context.temp_allocator)

	src_positions := make([dynamic][3]f32)
	src_normals := make([dynamic][3]f32)
	src_uvs := make([dynamic][2]f32)
	positions := make([dynamic][3]f32)
	normals := make([dynamic][3]f32)
	uvs := make([dynamic][2]f32)
	indices := make([dynamic]u32)
	vertex_cache := make(map[Obj_Vertex_Key]u32)
	defer delete(vertex_cache)
	surface_ranges := make([dynamic]Raw_Surface_Range)
	used_material_names := make([dynamic]string)
	current_material := "default"
	mtllib_path := ""
	append(
		&surface_ranges,
		Raw_Surface_Range{material_name = current_material, start_index = 0, index_count = 0},
	)

	for line in lines {
		line_trim := strings.trim_space(line)
		if len(line_trim) == 0 || line_trim[0] == '#' {
			continue
		}

		parts := strings.fields(line_trim, context.temp_allocator)
		if len(parts) == 0 {
			continue
		}

		switch parts[0] {
		case "mtllib":
			if len(line_trim) > len("mtllib") {
				raw_mtl := strings.trim_space(line_trim[len("mtllib"):])
				mtllib_path = normalize_mtllib_reference(raw_mtl)
			}
		case "usemtl":
			if len(line_trim) > len("usemtl") {
				raw_material := strings.trim_space(line_trim[len("usemtl"):])
				current_material := strings.to_lower(
					strip_wrapping_quotes(strings.trim_space(raw_material)),
					context.temp_allocator,
				)
				if len(current_material) == 0 {
					current_material = "default"
				}
				already_used := false
				for m in used_material_names {
					if strings.equal_fold(strings.trim_space(m), current_material) {
						already_used = true
						break
					}
				}
				if !already_used {
					append(&used_material_names, current_material)
				}

				if len(surface_ranges) == 0 ||
				   surface_ranges[len(surface_ranges) - 1].material_name != current_material ||
				   surface_ranges[len(surface_ranges) - 1].index_count > 0 {
					append(
						&surface_ranges,
						Raw_Surface_Range {
							material_name = current_material,
							start_index = u32(len(indices)),
							index_count = 0,
						},
					)
				}
			}
		case "v":
			if len(parts) >= 4 {
				x, ok_x := strconv.parse_f32(parts[1])
				y, ok_y := strconv.parse_f32(parts[2])
				z, ok_z := strconv.parse_f32(parts[3])
				if ok_x && ok_y && ok_z {
					append(&src_positions, [3]f32{x, y, z})
				}
			}
		case "vn":
			if len(parts) >= 4 {
				nx, ok_x := strconv.parse_f32(parts[1])
				ny, ok_y := strconv.parse_f32(parts[2])
				nz, ok_z := strconv.parse_f32(parts[3])
				if ok_x && ok_y && ok_z {
					append(&src_normals, [3]f32{nx, ny, nz})
				}
			}
		case "vt":
			if len(parts) >= 3 {
				u, ok_u := strconv.parse_f32(parts[1])
				v, ok_v := strconv.parse_f32(parts[2])
				if ok_u && ok_v {
					append(&src_uvs, [2]f32{u, v})
				}
			}
		case "f":
			if len(parts) >= 4 {
				already_used := false
				for m in used_material_names {
					if m == current_material {
						already_used = true
						break
					}
				}
				if !already_used {
					append(&used_material_names, current_material)
				}

				if len(surface_ranges) == 0 {
					append(
						&surface_ranges,
						Raw_Surface_Range {
							material_name = current_material,
							start_index = u32(len(indices)),
							index_count = 0,
						},
					)
				}
				for i := 2; i < len(parts); i += 1 {
					tokens := [3]string{parts[1], parts[i - 1], parts[i]}
					tri_indices := [3]u32{}
					tri_ok := true
					for token, token_i in tokens {
						v_raw, vt_raw, vn_raw, parsed := parse_obj_face_token(token)
						if !parsed {
							log.errorf(
								"OBJ face vertex parse error at line: '%v' (token='%s')",
								line_trim,
								token,
							)
							tri_ok = false
							break
						}

						v_idx, v_ok := obj_to_index(v_raw, len(src_positions))
						if !v_ok {
							log.errorf(
								"OBJ face position index out of range at line: '%v' (token='%s')",
								line_trim,
								token,
							)
							tri_ok = false
							break
						}

						vt_idx: i32 = -1
						if vt_raw != 0 {
							if parsed_vt, vt_ok := obj_to_index(vt_raw, len(src_uvs)); vt_ok {
								vt_idx = parsed_vt
							}
						}

						vn_idx: i32 = -1
						if vn_raw != 0 {
							if parsed_vn, vn_ok := obj_to_index(vn_raw, len(src_normals)); vn_ok {
								vn_idx = parsed_vn
							}
						}

						key := Obj_Vertex_Key {
							v  = v_idx,
							vt = vt_idx,
							vn = vn_idx,
						}
						if existing_idx, found := vertex_cache[key]; found {
							tri_indices[token_i] = existing_idx
							continue
						}

						append(&positions, src_positions[v_idx])

						if vt_idx >= 0 && vt_idx < i32(len(src_uvs)) {
							append(&uvs, src_uvs[vt_idx])
						} else {
							append(&uvs, [2]f32{0, 0})
						}

						if vn_idx >= 0 && vn_idx < i32(len(src_normals)) {
							append(&normals, src_normals[vn_idx])
						} else {
							append(&normals, [3]f32{0, 1, 0})
						}

						new_idx := u32(len(positions) - 1)
						vertex_cache[key] = new_idx
						tri_indices[token_i] = new_idx
					}

					if !tri_ok {
						continue
					}

					append(&indices, tri_indices[0])
					append(&indices, tri_indices[1])
					append(&indices, tri_indices[2])
					surface_ranges[len(surface_ranges) - 1].index_count += 3
				}
			}
		}
	}

	if len(positions) == 0 || len(indices) == 0 {
		log.error("No valid mesh data found in OBJ file")
		delete(src_positions)
		delete(src_normals)
		delete(src_uvs)
		delete(positions)
		delete(normals)
		delete(uvs)
		delete(indices)
		delete(surface_ranges)
		delete(used_material_names)
		return {}, false
	}

	filtered_ranges := make([dynamic]Raw_Surface_Range)
	for r in surface_ranges {
		if r.index_count > 0 {
			append(&filtered_ranges, r)
		}
	}
	delete(surface_ranges)
	if len(filtered_ranges) == 0 {
		append(
			&filtered_ranges,
			Raw_Surface_Range {
				material_name = "default",
				start_index = 0,
				index_count = u32(len(indices)),
			},
		)
	}

	delete(src_positions)
	delete(src_normals)
	delete(src_uvs)

	return Raw_Mesh {
			positions = positions,
			normals = normals,
			uvs = uvs,
			indices = indices,
			surface_ranges = filtered_ranges,
			mtllib = mtllib_path,
			used_material_names = used_material_names,
			name = get_file_name_without_ext(file_path),
		},
		true
}

sanitize_file_component :: proc(value: string) -> string {
	if len(value) == 0 {
		return ""
	}
	b := make([dynamic]byte, 0, len(value))
	defer delete(b)
	for c in value {
		is_alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		is_digit := c >= '0' && c <= '9'
		if is_alpha || is_digit || c == '-' || c == '_' || c == '.' {
			append(&b, byte(c))
		} else {
			append(&b, '_')
		}
	}
	s := strings.clone(string(b[:]))
	defer delete(s)
	return s
}

normalize_mtllib_reference :: proc(value: string) -> string {
	mtl := strip_wrapping_quotes(value)
	if len(mtl) == 0 {
		return ""
	}

	last_slash := strings.last_index(mtl, "/")
	last_backslash := strings.last_index(mtl, "\\")
	if last_backslash > last_slash {
		last_slash = last_backslash
	}
	if last_slash >= 0 && last_slash + 1 < len(mtl) {
		mtl = mtl[last_slash + 1:]
	}

	mtl = strings.trim_space(mtl)
	if len(mtl) == 0 {
		return ""
	}

	lower_mtl := strings.to_lower(mtl, context.temp_allocator)
	if !strings.has_suffix(lower_mtl, ".mtl") {
		mtl = strings.concatenate([]string{mtl, ".mtl"}, context.temp_allocator)
	}

	return mtl
}

obj_to_index :: proc(raw_idx: i32, count: int) -> (idx: i32, ok: bool) {
	if raw_idx == 0 {
		return -1, false
	}
	if raw_idx > 0 {
		idx = raw_idx - 1
	} else {
		idx = i32(count) + raw_idx
	}
	if idx < 0 || idx >= i32(count) {
		return -1, false
	}
	return idx, true
}

parse_obj_face_token :: proc(token: string) -> (v, vt, vn: i32, ok: bool) {
	v, vt, vn = 0, 0, 0
	parts := strings.split(token, "/", context.temp_allocator)
	if len(parts) == 0 {
		return 0, 0, 0, false
	}

	v64, v_ok := strconv.parse_int(parts[0])
	if !v_ok {
		return 0, 0, 0, false
	}
	v = i32(v64)

	if len(parts) > 1 && len(parts[1]) > 0 {
		vt64, vt_ok := strconv.parse_int(parts[1])
		if vt_ok {
			vt = i32(vt64)
		}
	}

	if len(parts) > 2 && len(parts[2]) > 0 {
		vn64, vn_ok := strconv.parse_int(parts[2])
		if vn_ok {
			vn = i32(vn64)
		}
	}

	return v, vt, vn, true
}

// Frees all resources for Raw_Mesh, Cooked_Mesh_File, and material_assets array
cleanup_converter :: proc(
	raw: ^Raw_Mesh,
	cooked: ^am.Cooked_Mesh_File,
	material_assets: ^[]MTL_Material_Raw,
	material_files: []string = {},
	slot_names: []string = {},
) {
	if raw != nil {
		if raw.positions != nil { delete(raw.positions); raw.positions = nil; }
		if raw.normals != nil { delete(raw.normals); raw.normals = nil; }
		if raw.uvs != nil { delete(raw.uvs); raw.uvs = nil; }
		if raw.indices != nil { delete(raw.indices); raw.indices = nil; }
		if raw.surface_ranges != nil { delete(raw.surface_ranges); raw.surface_ranges = nil; }
		if raw.used_material_names != nil { delete(raw.used_material_names); raw.used_material_names = nil; }
	}
	if cooked != nil {
		if cooked.material_slots != nil {
			for i := 0; i < len(cooked.material_slots); i += 1 {
				if len(cooked.material_slots[i].slot_name) > 0 {
					delete(cooked.material_slots[i].slot_name)
					cooked.material_slots[i].slot_name = ""
				}
			}
			delete(cooked.material_slots)
			cooked.material_slots = nil
		}
		if cooked.vertex_blob != nil { delete(cooked.vertex_blob); cooked.vertex_blob = nil; }
		if cooked.index_blob != nil { delete(cooked.index_blob); cooked.index_blob = nil; }
		if cooked.lods != nil {
			for &lod in cooked.lods {
				if lod.material_ranges != nil {
					delete(lod.material_ranges)
					lod.material_ranges = nil
				}
			}
			delete(cooked.lods)
			cooked.lods = nil
		}
		if cooked.meshlets != nil { delete(cooked.meshlets); cooked.meshlets = nil; }
		if cooked.meshlet_bounds != nil { delete(cooked.meshlet_bounds); cooked.meshlet_bounds = nil; }
		if cooked.chunks != nil { delete(cooked.chunks); cooked.chunks = nil; }
		if cooked.collision.vertices != nil { delete(cooked.collision.vertices); cooked.collision.vertices = nil; }
		if cooked.collision.indices != nil { delete(cooked.collision.indices); cooked.collision.indices = nil; }
	}
	// Do not delete material_assets^ -- currently not owned here.

	// Free all cloned strings in material_files
	for i in 0 ..< len(material_files) {
		if material_files[i] != "" {
			delete(material_files[i])
			material_files[i] = ""
		}
	}
	if material_files != nil {
		delete(material_files)
	}

	// Free all cloned strings in slot_names
	for i in 0 ..< len(slot_names) {
		if slot_names[i] != "" {
			delete(slot_names[i])
			slot_names[i] = ""
		}
	}
	if slot_names != nil {
		delete(slot_names)
	}
}
